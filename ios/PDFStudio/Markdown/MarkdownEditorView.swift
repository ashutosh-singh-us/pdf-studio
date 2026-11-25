import SwiftUI

struct MarkdownEditorView: View {
  enum Mode: String, CaseIterable { case preview = "Preview", edit = "Edit", split = "Split" }

  @ObservedObject var document: StudioDocument
  let fileURL: URL?
  @StateObject private var preview = MarkdownPreview()
  @Environment(\.undoManager) private var undoManager
  @Environment(\.horizontalSizeClass) private var sizeClass
  @AppStorage("mdZoom") private var zoom = 1.0
  @State private var mode: Mode
  @State private var showOutline = false
  @State private var share: ShareItem?
  @State private var error: String?
  @State private var renderTask: Task<Void, Never>?

  init(document: StudioDocument, fileURL: URL?) {
    self.document = document
    self.fileURL = fileURL
    // A brand-new (empty) document opens ready to type; existing files open formatted.
    _mode = State(initialValue: document.markdown.isEmpty ? .edit : .preview)
  }

  private var baseName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Document" }
  private var modes: [Mode] { sizeClass == .regular ? Mode.allCases : [.preview, .edit] }

  private var text: Binding<String> {
    Binding(get: { document.markdown }, set: { setText($0) })
  }

  var body: some View {
    content
      .toolbar { toolbarContent }
      .onAppear {
        preview.setZoom(zoom)
        preview.render(document.markdown)
      }
      .onChange(of: mode) { _, m in if m != .edit { preview.render(document.markdown) } }
      .onChange(of: zoom) { _, z in preview.setZoom(z) }
      .onChange(of: sizeClass) { _, c in if c != .regular && mode == .split { mode = .edit } }
      .sheet(isPresented: $showOutline) { outlineSheet }
      .sheet(item: $share) { item in ActivitySheet(items: [item.url]).ignoresSafeArea() }
      .alert("PDF Studio", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK", role: .cancel) {}
      } message: { Text(error ?? "") }
  }

  @ViewBuilder private var content: some View {
    switch mode {
    case .preview:
      MarkdownWebView(preview: preview)
    case .edit:
      ZStack {
        // The preview stays in the window (behind the editor) so printing always works.
        MarkdownWebView(preview: preview).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        editor
      }
    case .split:
      HStack(spacing: 0) {
        editor
        Divider()
        MarkdownWebView(preview: preview)
      }
    }
  }

  private var editor: some View {
    TextEditor(text: text)
      .font(.system(size: 15 * zoom, design: .monospaced))
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
      .scrollContentBackground(.hidden)
      .background(Color(uiColor: .systemBackground))
      .padding(.horizontal, 6)
  }

  private func setText(_ new: String) {
    let old = document.markdown
    guard new != old else { return }
    apply(new, previous: old)
    if mode == .split { scheduleRender() }
  }

  /// Every change is an undo step; registering it is also what tells the system to save.
  private func apply(_ new: String, previous: String) {
    document.markdown = new
    let doc = document
    let um = undoManager
    um?.registerUndo(withTarget: doc) { d in
      let cur = d.markdown
      d.markdown = previous
      um?.registerUndo(withTarget: d) { $0.markdown = cur }
    }
    um?.setActionName("Typing")
  }

  private func scheduleRender() {
    renderTask?.cancel()
    renderTask = Task {
      try? await Task.sleep(for: .milliseconds(250))
      if !Task.isCancelled { preview.render(document.markdown) }
    }
  }

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .principal) {
      Picker("View", selection: $mode) {
        ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .frame(width: sizeClass == .regular ? 240 : 160)
    }
    ToolbarItemGroup(placement: .topBarTrailing) {
      if mode != .preview {
        Button { undoManager?.undo(); preview.render(document.markdown) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
          .disabled(!(undoManager?.canUndo ?? false))
      }
      Menu {
        Button { showOutline = true } label: { Label("Outline", systemImage: "list.bullet.indent") }
          .disabled(preview.outline.isEmpty)
        Button { find() } label: { Label("Find", systemImage: "magnifyingglass") }
        ControlGroup {
          Button { zoom = max(0.7, zoom - 0.1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
          Button { zoom = 1 } label: { Text("\(Int((zoom * 100).rounded()))%") }
          Button { zoom = min(2.0, zoom + 0.1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
        }
        Divider()
        Button { Task { await exportPDF() } } label: { Label("Export as PDF…", systemImage: "doc.richtext") }
        Button { Task { await printDocument() } } label: { Label("Print…", systemImage: "printer") }
        Button { shareSource() } label: { Label("Share Markdown…", systemImage: "square.and.arrow.up") }
        if preview.words > 0 {
          Divider()
          Text("\(preview.words.formatted()) words · \(max(1, preview.words / 230)) min read")
        }
      } label: { Label("More", systemImage: "ellipsis.circle") }
    }
  }

  private var outlineSheet: some View {
    NavigationStack {
      List(preview.outline) { item in
        Button {
          if mode == .edit { mode = .preview }
          showOutline = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { preview.scroll(to: item.id) }
        } label: {
          Text(item.title)
            .font(item.level == 1 ? .headline : item.level == 2 ? .body : .subheadline)
            .foregroundStyle(item.level > 2 ? .secondary : .primary)
            .padding(.leading, CGFloat(item.level - 1) * 14)
        }
      }
      .navigationTitle("Outline")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOutline = false } } }
    }
    .presentationDetents([.medium, .large])
  }

  private func find() {
    if mode == .edit { mode = .preview }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      preview.webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }
  }

  private func exportPDF() async {
    await preview.renderAndWait(document.markdown)
    do { share = ShareItem(url: try TempFiles.write(preview.pdfData(), name: "\(baseName).pdf")) }
    catch { self.error = "The PDF could not be created." }
  }

  private func printDocument() async {
    await preview.renderAndWait(document.markdown)
    let info = UIPrintInfo.printInfo()
    info.jobName = baseName
    let pc = UIPrintInteractionController.shared
    pc.printInfo = info
    pc.printFormatter = preview.webView.viewPrintFormatter()
    pc.present(animated: true)
  }

  private func shareSource() {
    let ext = fileURL?.pathExtension.isEmpty == false ? fileURL!.pathExtension : "md"
    do { share = ShareItem(url: try TempFiles.write(Data(document.markdown.utf8), name: "\(baseName).\(ext)")) }
    catch { self.error = "The file could not be shared." }
  }
}
