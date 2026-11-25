import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Grid of pages: tap to go to a page; in Select mode rotate, delete, extract; drag to reorder.
struct PageOrganizer: View {
  @ObservedObject var editor: PDFEditor
  let baseName: String
  @Environment(\.dismiss) private var dismiss
  @State private var selecting = false
  @State private var selection: Set<Int> = []
  @State private var showMerge = false
  @State private var share: ShareItem?
  @State private var confirmDelete = false

  private let columns = [GridItem(.adaptive(minimum: 104), spacing: 14)]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 18) {
          ForEach(0..<editor.doc.pageCount, id: \.self) { i in
            if let page = editor.doc.page(at: i) {
              PageCell(page: page, number: i + 1, selected: selection.contains(i), selecting: selecting,
                       revision: editor.revision)
                .onTapGesture { tapped(i) }
                .draggable(String(i)) {
                  PageThumb(page: page, revision: editor.revision).frame(width: 80, height: 104)
                }
                .dropDestination(for: String.self) { items, _ in
                  guard let s = items.first, let from = Int(s) else { return false }
                  editor.movePage(from: from, to: i)
                  selection = []
                  return true
                }
                .contextMenu {
                  Button { editor.rotate([i], by: -90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                  Button { editor.rotate([i], by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                  Button { editor.insertBlankPage(after: i) } label: { Label("Insert Blank Page After", systemImage: "doc.badge.plus") }
                  Button { extract([i]) } label: { Label("Extract Page…", systemImage: "square.and.arrow.up") }
                  Button(role: .destructive) { editor.deletePages([i]) } label: { Label("Delete Page", systemImage: "trash") }
                }
            }
          }
        }
        .padding()
        Text("Drag a page onto another to move it. Long-press for more.")
          .font(.footnote).foregroundStyle(.secondary).padding(.bottom)
      }
      .navigationTitle("\(editor.doc.pageCount) Pages")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button(selecting ? "Cancel" : "Select") { selecting.toggle(); selection = [] }
        }
        ToolbarItemGroup(placement: .bottomBar) {
          if selecting {
            Button { editor.rotate(Array(selection), by: -90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
              .disabled(selection.isEmpty)
            Button { editor.rotate(Array(selection), by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
              .disabled(selection.isEmpty)
            Spacer()
            Button { extract(Array(selection)) } label: { Label("Extract", systemImage: "square.and.arrow.up") }
              .disabled(selection.isEmpty)
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
              .disabled(selection.isEmpty)
          } else {
            Button { editor.insertBlankPage(after: editor.doc.pageCount - 1) } label: {
              Label("Add Blank Page", systemImage: "doc.badge.plus")
            }
            Spacer()
            Button { showMerge = true } label: { Label("Add Pages from PDF…", systemImage: "doc.on.doc") }
          }
        }
      }
      .confirmationDialog("Delete \(selection.count) page\(selection.count == 1 ? "" : "s")?", isPresented: $confirmDelete,
                          titleVisibility: .visible) {
        Button("Delete", role: .destructive) { editor.deletePages(Array(selection)); selection = [] }
      }
      .fileImporter(isPresented: $showMerge, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
        guard case let .success(urls) = result else { return }
        let docs = urls.compactMap { url -> PDFDocument? in
          let ok = url.startAccessingSecurityScopedResource()
          defer { if ok { url.stopAccessingSecurityScopedResource() } }
          return (try? Data(contentsOf: url)).flatMap { PDFDocument(data: $0) }
        }
        editor.merge(docs)
      }
      .sheet(item: $share) { item in ActivitySheet(items: [item.url]).ignoresSafeArea() }
    }
  }

  private func tapped(_ i: Int) {
    if selecting {
      if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
    } else {
      editor.go(toPage: i)
      dismiss()
    }
  }

  private func extract(_ indexes: [Int]) {
    do {
      let data = try editor.extract(indexes)
      let sorted = indexes.sorted()
      let suffix = sorted.count == 1 ? "page \(sorted[0] + 1)" : "pages \(sorted.first! + 1)-\(sorted.last! + 1)"
      share = ShareItem(url: try TempFiles.write(data, name: "\(baseName) (\(suffix)).pdf"))
    } catch { editor.message = error.localizedDescription }
  }
}

private struct PageCell: View {
  let page: PDFPage
  let number: Int
  let selected: Bool
  let selecting: Bool
  let revision: Int

  var body: some View {
    VStack(spacing: 6) {
      PageThumb(page: page, revision: revision)
        .frame(height: 136)
        .overlay(alignment: .topTrailing) {
          if selecting {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .font(.title3)
              .foregroundStyle(selected ? Color.accentColor : Color.secondary)
              .background(Circle().fill(.background))
              .padding(4)
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0))
      Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Page \(number)\(selected ? ", selected" : "")")
  }
}

private struct PageThumb: View {
  let page: PDFPage
  let revision: Int
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFit()
          .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
      } else {
        Rectangle().fill(.quaternary)
      }
    }
    .task(id: "\(ObjectIdentifier(page).hashValue)-\(revision)") {
      image = page.thumbnail(of: CGSize(width: 220, height: 280), for: .cropBox)
    }
  }
}
