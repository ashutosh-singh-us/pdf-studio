import PDFKit
import SwiftUI

struct Chapter: Identifiable, Hashable, Codable {
  var id: Int { pageIndex * 1000 + order }
  let title: String
  let level: Int
  let pageIndex: Int
  /// Order within the list (keeps ids unique when several chapters start on one page).
  let order: Int
  /// Page-space point of the heading, when known.
  var x: CGFloat?
  var y: CGFloat?
}

/// Chapters come from the PDF's own table of contents (bookmarks) when it has one; otherwise
/// pages are scanned for headings like "Chapter 12", "Prologue" or "Part Two". Scan results are
/// cached per book so it only happens once.
enum ChapterIndex {
  static func fromOutline(_ doc: PDFDocument) -> [Chapter] {
    guard let root = doc.outlineRoot else { return [] }
    var out: [Chapter] = []
    func walk(_ node: PDFOutline, level: Int) {
      for i in 0..<node.numberOfChildren {
        guard let child = node.child(at: i) else { continue }
        if let dest = child.destination, let page = dest.page {
          let idx = doc.index(for: page)
          if idx != NSNotFound {
            let p = dest.point
            let valid = p.x != kPDFDestinationUnspecifiedValue && p.y != kPDFDestinationUnspecifiedValue
            out.append(Chapter(title: (child.label ?? "Untitled").trimmingCharacters(in: .whitespacesAndNewlines),
                               level: level, pageIndex: idx, order: out.count,
                               x: valid ? p.x : nil, y: valid ? p.y : nil))
          }
        }
        walk(child, level: level + 1)
      }
    }
    walk(root, level: 0)
    return out
  }

  private static let heading = try! NSRegularExpression(
    pattern: #"^\s*(chapter|chap\.|ch\.|part|book|volume|vol\.|prologue|epilogue|interlude|afterword|side story)\b[\s\S]{0,90}$"#,
    options: [.caseInsensitive])

  /// Is this line a chapter heading? (Short lines starting with a chapter word.)
  static func isHeading(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.count >= 4, t.count <= 100 else { return false }
    return heading.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
  }

  /// Headings from the first few lines of each page. Skips repeats (running headers).
  /// `progress` is called on the scanning thread with partial results.
  static func scan(_ doc: PDFDocument, isCancelled: () -> Bool, progress: ([Chapter], Double) -> Void) -> [Chapter] {
    var out: [Chapter] = []
    var lastTitle = ""
    let count = doc.pageCount
    for i in 0..<count {
      if isCancelled() { break }
      autoreleasepool {
        guard let text = doc.page(at: i)?.string else { return }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
          .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(6)
        for line in lines where isHeading(line) {
          let title = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
          if title.caseInsensitiveCompare(lastTitle) == .orderedSame { break }
          lastTitle = title
          out.append(Chapter(title: title, level: 0, pageIndex: i, order: out.count))
          break
        }
      }
      if i % 50 == 49 { progress(out, Double(i + 1) / Double(count)) }
    }
    return out
  }

  // MARK: Cache (Caches/Chapters/<key>.json)

  private static var cacheDir: URL {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Chapters", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func cacheURL(_ key: String) -> URL {
    let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
    return cacheDir.appendingPathComponent(String(safe.prefix(150)) + ".json")
  }

  static func cached(_ key: String) -> [Chapter]? {
    guard let data = try? Data(contentsOf: cacheURL(key)) else { return nil }
    return try? JSONDecoder().decode([Chapter].self, from: data)
  }

  static func store(_ chapters: [Chapter], key: String) {
    if let data = try? JSONEncoder().encode(chapters) { try? data.write(to: cacheURL(key), options: .atomic) }
  }
}

/// Remembers where you were in each document (page and position), on this device.
enum ReadingPosition {
  struct Mark: Codable {
    let page: Int
    let x: CGFloat
    let y: CGFloat
    var date: Date
  }
  private static let defaultsKey = "readingPositions"
  private static let limit = 300

  static func load(_ key: String) -> Mark? {
    all()[key]
  }

  static func save(_ mark: Mark, key: String) {
    var marks = all()
    marks[key] = mark
    if marks.count > limit {
      for old in marks.sorted(by: { $0.value.date < $1.value.date }).prefix(marks.count - limit) { marks[old.key] = nil }
    }
    if let data = try? JSONEncoder().encode(marks) { UserDefaults.standard.set(data, forKey: defaultsKey) }
  }

  private static func all() -> [String: Mark] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
    return (try? JSONDecoder().decode([String: Mark].self, from: data)) ?? [:]
  }
}

/// Identifies a book across launches: file name plus page count (stable when the file is moved or synced).
enum DocumentKey {
  static func make(fileURL: URL?, doc: PDFDocument) -> String? {
    guard let name = fileURL?.lastPathComponent else { return nil }
    return "\(name)#\(doc.pageCount)"
  }
}

// MARK: - Contents sheet

@MainActor
final class ChapterModel: ObservableObject {
  @Published private(set) var chapters: [Chapter] = []
  @Published private(set) var scanning = false
  @Published private(set) var progress = 0.0
  @Published private(set) var fromOutline = false
  private var task: Task<Void, Never>?
  private var loadedKey: String?

  func load(doc: PDFDocument, fileURL: URL?, key: String?) {
    if loadedKey == key, key != nil, !chapters.isEmpty || scanning { return }
    loadedKey = key
    let outline = ChapterIndex.fromOutline(doc)
    if outline.count >= 2 {
      chapters = outline
      fromOutline = true
      return
    }
    if let key, let cached = ChapterIndex.cached(key) { chapters = cached; return }
    guard let fileURL else { return }
    // Scan a separate copy on a background thread (PDFDocument isn't thread-safe).
    scanning = true
    progress = 0
    task?.cancel()
    task = Task.detached(priority: .utility) { [weak self] in
      guard let copy = PDFDocument(url: fileURL) else {
        await MainActor.run { self?.scanning = false }
        return
      }
      let result = ChapterIndex.scan(copy, isCancelled: { Task.isCancelled }) { partial, p in
        Task { @MainActor in self?.chapters = partial; self?.progress = p }
      }
      if Task.isCancelled { return }
      if let key { ChapterIndex.store(result, key: key) }
      await MainActor.run {
        self?.chapters = result
        self?.scanning = false
        self?.progress = 1
      }
    }
  }

  /// The chapter containing `pageIndex`.
  func current(at pageIndex: Int) -> Chapter? {
    chapters.last { $0.pageIndex <= pageIndex }
  }

  deinit { task?.cancel() }
}

struct ContentsSheet: View {
  @ObservedObject var editor: PDFEditor
  @ObservedObject var model: ChapterModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var askPage = false
  @State private var pageText = ""

  private var currentPage: Int {
    editor.pdfView.currentPage.map { editor.doc.index(for: $0) } ?? 0
  }

  private var filtered: [Chapter] {
    query.isEmpty ? model.chapters : model.chapters.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    NavigationStack {
      let current = model.current(at: currentPage)
      ScrollViewReader { proxy in
        List {
          if model.scanning {
            Section {
              ProgressView(value: model.progress) {
                Text("Finding chapters… (first time only)").font(.footnote)
              }
            }
          }
          if model.chapters.isEmpty && !model.scanning {
            ContentUnavailableView("No chapters found", systemImage: "list.bullet",
                                   description: Text("This PDF has no table of contents. Use Go to Page instead."))
          }
          ForEach(filtered) { ch in
            Button { go(ch) } label: {
              HStack {
                Text(ch.title)
                  .font(ch.level == 0 ? .body : .subheadline)
                  .fontWeight(ch == current ? .semibold : .regular)
                  .foregroundStyle(ch == current ? Color.accentColor : (ch.level > 0 ? .secondary : .primary))
                  .padding(.leading, CGFloat(min(ch.level, 4)) * 14)
                  .lineLimit(2)
                Spacer()
                Text("\(ch.pageIndex + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
            }
            .id(ch.id)
            .accessibilityValue(ch == current ? "Current chapter" : "")
          }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Search chapters")
        .onAppear {
          if let current { DispatchQueue.main.async { proxy.scrollTo(current.id, anchor: .center) } }
        }
      }
      .navigationTitle("Contents")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) { Button("Go to Page") { pageText = ""; askPage = true } }
      }
      .alert("Go to Page", isPresented: $askPage) {
        TextField("1–\(editor.doc.pageCount)", text: $pageText).keyboardType(.numberPad)
        Button("Go") {
          if let n = Int(pageText), (1...editor.doc.pageCount).contains(n) { editor.go(toPage: n - 1); dismiss() }
        }
        Button("Cancel", role: .cancel) {}
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func go(_ ch: Chapter) {
    if let page = editor.doc.page(at: ch.pageIndex) {
      if let x = ch.x, let y = ch.y {
        editor.pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: x, y: y)))
      } else {
        editor.pdfView.go(to: page)
      }
    }
    dismiss()
  }
}
