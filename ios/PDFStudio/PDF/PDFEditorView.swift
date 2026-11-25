import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PDFEditorView: View {
  @ObservedObject var document: StudioDocument
  let fileURL: URL?
  @StateObject private var editor: PDFEditor
  @Environment(\.undoManager) private var undoManager

  @State private var showPages = false
  @State private var showContents = false
  @StateObject private var chapters = ChapterModel()
  @State private var showThumbnails = false
  @State private var showSignature = false
  @State private var photoItem: PhotosPickerItem?
  @State private var showPhotoPicker = false
  @State private var showImageImporter = false
  @State private var share: ShareItem?
  @State private var password = ""
  @State private var passwordFailed = false
  @State private var displayMode: PDFDisplayMode = .singlePageContinuous
  @State private var showListen = false
  @State private var showNarratorSetup = false
  @AppStorage("narratorSetupOffered") private var narratorSetupOffered = false

  init(document: StudioDocument, fileURL: URL?) {
    self.document = document
    self.fileURL = fileURL
    let editor = PDFEditor(document: document)
    editor.positionKey = DocumentKey.make(fileURL: fileURL, doc: document.pdf)
    _editor = StateObject(wrappedValue: editor)
  }

  private var baseName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Document" }

  var body: some View {
    Group {
      if document.isLocked {
        lockedView
      } else {
        editorBody
      }
    }
    .onAppear {
      editor.undoManager = undoManager
      if !document.isLocked { chapters.load(doc: document.pdf, fileURL: fileURL, key: editor.positionKey) }
      // First PDF opened: offer the one-time voice download.
      if !narratorSetupOffered, !ModelDownloader.shared.isInstalled {
        narratorSetupOffered = true
        showNarratorSetup = true
      }
    }
    .onDisappear { editor.savePosition() }
    .onChange(of: undoManager) { _, new in editor.undoManager = new }
  }

  private var lockedView: some View {
    VStack(spacing: 16) {
      Image(systemName: "lock.doc").font(.system(size: 48)).foregroundStyle(.secondary)
      Text("This PDF is password-protected").font(.headline)
      SecureField("Password", text: $password)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 320)
        .submitLabel(.go)
        .onSubmit(unlock)
      if passwordFailed { Text("That password didn't work.").foregroundStyle(.red).font(.footnote) }
      Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
    }
    .padding()
  }

  private func unlock() {
    passwordFailed = !document.unlock(password)
    if !passwordFailed {
      editor.pdfView.document = nil
      editor.pdfView.document = document.pdf
      editor.positionKey = DocumentKey.make(fileURL: fileURL, doc: document.pdf)
      editor.updatePageLabel()
      chapters.load(doc: document.pdf, fileURL: fileURL, key: editor.positionKey)
    }
  }

  private var editorBody: some View {
    PDFCanvas(editor: editor)
      .ignoresSafeArea(edges: .bottom)
      .overlay(alignment: .top) { pageBadge }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          if showThumbnails { ThumbnailStrip(pdfView: editor.pdfView).frame(height: 84) }
          ToolPanel(editor: editor, showSignature: $showSignature, showPhotoPicker: $showPhotoPicker,
                    showImageImporter: $showImageImporter)
        }
        .background(.bar)
      }
      .toolbar { toolbarContent }
      .onChange(of: displayMode) { _, mode in
        editor.pdfView.displayMode = mode
        editor.pdfView.autoScales = true
      }
      .sheet(item: $editor.textRequest) { req in
        TextEntrySheet(request: req) { editor.commitText($0) }
      }
      .sheet(isPresented: $showSignature) {
        SignatureSheet { image in editor.insertImage(image, widthFraction: 0.3, name: "Signature") }
      }
      .sheet(isPresented: $showContents) { ContentsSheet(editor: editor, model: chapters) }
      .sheet(isPresented: $showListen) {
        ListenSheet(doc: document.pdf, fileURL: fileURL, bookKey: editor.positionKey ?? baseName, title: baseName,
                    chapters: chapters, currentPage: editor.pdfView.currentPage.map { editor.doc.index(for: $0) } ?? 0)
      }
      .sheet(isPresented: $showNarratorSetup) {
        NarratorSetupView { showNarratorSetup = false }.presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showPages) {
        PageOrganizer(editor: editor, baseName: baseName)
      }
      .sheet(item: $share) { item in ActivitySheet(items: [item.url]).ignoresSafeArea() }
      .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
      .onChange(of: photoItem) { _, item in
        guard let item else { return }
        Task {
          if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
            editor.insertImage(img)
          }
          photoItem = nil
        }
      }
      .fileImporter(isPresented: $showImageImporter, allowedContentTypes: [.image]) { result in
        guard case let .success(url) = result else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { editor.insertImage(img) }
      }
      .alert("PDF Studio", isPresented: Binding(get: { editor.message != nil }, set: { if !$0 { editor.message = nil } })) {
        Button("OK", role: .cancel) {}
      } message: { Text(editor.message ?? "") }
  }

  @ViewBuilder private var pageBadge: some View {
    if !editor.pageLabel.isEmpty {
      Text(badgeText)
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .frame(maxWidth: 300)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .padding(.top, 6)
        .allowsHitTesting(false)
        .accessibilityLabel("Page \(editor.pageLabel)")
    }
  }

  private var badgeText: String {
    let index = editor.pdfView.currentPage.map { editor.doc.index(for: $0) } ?? 0
    if let ch = chapters.current(at: index) { return "\(ch.title) · \(editor.pageLabel)" }
    return editor.pageLabel
  }

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button { showContents = true } label: { Label("Contents", systemImage: "list.bullet") }
      Button { showListen = true } label: { Label("Listen", systemImage: "headphones") }
      Button { undoManager?.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
        .disabled(!(undoManager?.canUndo ?? false))
      Button { undoManager?.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
        .disabled(!(undoManager?.canRedo ?? false))
      Menu {
        Button { editor.pdfView.findInteraction.presentFindNavigator(showingReplace: false) } label: {
          Label("Find", systemImage: "magnifyingglass")
        }
        Button { showPages = true } label: { Label("Pages…", systemImage: "square.grid.2x2") }
        Toggle(isOn: $showThumbnails) { Label("Page Strip", systemImage: "rectangle.split.3x1") }
        Picker(selection: $displayMode) {
          Text("Continuous").tag(PDFDisplayMode.singlePageContinuous)
          Text("Single Page").tag(PDFDisplayMode.singlePage)
          Text("Two Pages").tag(PDFDisplayMode.twoUpContinuous)
        } label: { Label("Layout", systemImage: "doc.on.doc") }
          .pickerStyle(.menu)
        Divider()
        Button { shareCopy() } label: { Label("Share / Save a Copy…", systemImage: "square.and.arrow.up") }
        Button { printDocument() } label: { Label("Print…", systemImage: "printer") }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
    }
  }

  private func shareCopy() {
    do {
      let data = try editor.exportData()
      share = ShareItem(url: try TempFiles.write(data, name: "\(baseName).pdf"))
    } catch { editor.message = error.localizedDescription }
  }

  private func printDocument() {
    do {
      let data = try editor.exportData()
      let info = UIPrintInfo.printInfo()
      info.jobName = baseName
      info.outputType = .general
      let pc = UIPrintInteractionController.shared
      pc.printInfo = info
      pc.printingItem = data
      pc.present(animated: true)
    } catch { editor.message = error.localizedDescription }
  }
}

struct ShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

enum TempFiles {
  /// Writes data to a fresh temporary folder under a readable file name (for sharing).
  static func write(_ data: Data, name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safe = name.replacingOccurrences(of: "/", with: "-")
    let url = dir.appendingPathComponent(safe)
    try data.write(to: url, options: .atomic)
    return url
  }
}

struct ActivitySheet: UIViewControllerRepresentable {
  let items: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Hosts the editor's UIKit view.
struct PDFCanvas: UIViewRepresentable {
  let editor: PDFEditor
  func makeUIView(context: Context) -> UIView {
    let host = CanvasHost()
    host.onWindow = { [weak editor] in editor?.viewDidAppear() }
    editor.container.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(editor.container)
    NSLayoutConstraint.activate([
      editor.container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      editor.container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      editor.container.topAnchor.constraint(equalTo: host.topAnchor),
      editor.container.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    return host
  }
  func updateUIView(_ uiView: UIView, context: Context) {}

  final class CanvasHost: UIView {
    var onWindow: (() -> Void)?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { DispatchQueue.main.async { self.onWindow?() } }
    }
  }
}

struct ThumbnailStrip: UIViewRepresentable {
  let pdfView: PDFView
  func makeUIView(context: Context) -> PDFThumbnailView {
    let v = PDFThumbnailView()
    v.pdfView = pdfView
    v.layoutMode = .horizontal
    v.thumbnailSize = CGSize(width: 44, height: 60)
    v.backgroundColor = .clear
    v.contentInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    return v
  }
  func updateUIView(_ uiView: PDFThumbnailView, context: Context) {}
}
