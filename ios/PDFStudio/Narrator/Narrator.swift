import BackgroundTasks
import Foundation
import os
import PDFKit
import UIKit

/// Queues chapters, generates their audio with Kokoro, and keeps going in the background where iOS allows it.
///
/// Background rules on iPhone: apps can't use the GPU from the background, except inside a
/// continued-processing task (iOS 26+) on devices that support background GPU. Kokoro is small enough
/// to run on the CPU, so in the background it switches to the CPU whenever the GPU isn't allowed:
/// inside a continued-processing task (started when you tap Generate, shown as a Live Activity), or
/// while narration is playing. Otherwise it pauses in the background and resumes when you return.
@MainActor
final class Narrator: ObservableObject {
  static let shared = Narrator()
  private static let speedKey = "kokoroSpeed"

  enum Status: Equatable {
    case idle
    case loadingModel
    case generating(book: String, chapter: Int)
    case paused(String)
    case failed(String)
  }

  @Published private(set) var books: [String: NarrationBook] = [:]
  @Published private(set) var status: Status = .idle
  /// Measured on this device: seconds of audio made per second of work.
  @Published private(set) var speed: Double?
  @Published private(set) var backgroundMode: String = ""

  let engine = KokoroEngine()
  private var worker: Task<Void, Never>?
  private var bgTask: AnyObject?
  private var inBackground = false
  /// iOS granted GPU use in the background for the current task.
  private var backgroundGPU = false
  private var stats = (audio: 0.0, compute: 0.0)
  private let log = Logger(subsystem: "pdfstudio", category: "narrator")
  /// Save audio about once a minute, so an interruption loses at most that much.
  private let flushSeconds = 45.0

  private init() {
    books = NarrationStore.loadAll()
    // Books queued with the earlier Orpheus build use voice names Kokoro doesn't have.
    for (key, var book) in books where !KokoroEngine.voices.contains(book.narratorVoice) || !KokoroEngine.voices.contains(book.dialogueVoice) {
      book.narratorVoice = KokoroEngine.voices.contains(book.narratorVoice) ? book.narratorVoice : KokoroEngine.defaultNarrator
      book.dialogueVoice = KokoroEngine.voices.contains(book.dialogueVoice) ? book.dialogueVoice : KokoroEngine.defaultDialogue
      books[key] = book
      NarrationStore.save(book)
    }
    UserDefaults.standard.removeObject(forKey: "narratorSpeed")
    speed = UserDefaults.standard.object(forKey: Self.speedKey) as? Double
    let nc = NotificationCenter.default
    nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { self.enteredBackground() }
    }
    nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { self.enteredForeground() }
    }
  }

  var isRunning: Bool { worker != nil }
  var hasPendingWork: Bool { books.values.contains { !$0.pending.isEmpty } }

  static var supportsBackgroundGPU: Bool {
    if #available(iOS 26.0, *) { return BGTaskScheduler.supportedResources.contains(.gpu) }
    return false
  }

  // MARK: Queueing

  /// Adds chapters `range` (indices into `chapters`) of a book. Text is read from the PDF here.
  func enqueue(fileURL: URL?, doc: PDFDocument, key: String, title: String, chapters: [Chapter],
               range: ClosedRange<Int>, narratorVoice: String, dialogueVoice: String, ahead: Int) async {
    let toc = chapters.map { NarrationBook.TOCEntry(title: $0.title, pageIndex: $0.pageIndex) }
    var book = books[key] ?? NarrationBook(key: key, title: title, narratorVoice: narratorVoice, dialogueVoice: dialogueVoice,
                                           toc: toc, chapters: [], bookmark: nil, ahead: ahead, listen: nil, updated: Date())
    let voicesChanged = book.narratorVoice != narratorVoice || book.dialogueVoice != dialogueVoice
    book.toc = toc
    book.narratorVoice = narratorVoice
    book.dialogueVoice = dialogueVoice
    book.ahead = ahead
    book.updated = Date()
    if let fileURL, let mark = try? fileURL.bookmarkData() { book.bookmark = mark }
    if voicesChanged {
      // Chapters not started yet use the new voices; finished audio stays.
      for i in book.chapters.indices where book.chapters[i].nextLine == 0 { book.chapters[i].parts = [] }
    }
    let have = Set(book.chapters.map(\.order))
    let wanted = range.filter { !have.contains($0) && $0 < toc.count }
    let pageCount = doc.pageCount
    // PDFDocument isn't thread-safe: read text from a separate copy when we have the file.
    let source = fileURL.flatMap { PDFDocument(url: $0) }.flatMap { $0.isLocked ? nil : $0 }
    let added: [NarrationChapter] = await Task.detached(priority: .userInitiated) {
      let d = source ?? doc
      return wanted.map { i in
        let pages = ChapterText.pageRange(of: i, in: chapters, pageCount: pageCount)
        let lines = ChapterText.lines(from: ChapterText.text(doc: d, pages: pages))
        return NarrationChapter(order: i, title: chapters[i].title, pageIndex: chapters[i].pageIndex, lines: lines)
      }
    }.value
    book.chapters = (book.chapters + added).sorted { $0.order < $1.order }
    books[key] = book
    NarrationStore.save(book)
    start()
  }

  /// Called by the player when you reach a chapter: keeps `ahead` chapters queued past it.
  func reached(chapter order: Int, in key: String) {
    guard let book = books[key], book.ahead > 0 else { return }
    let last = min(order + book.ahead, book.toc.count - 1)
    let have = Set(book.chapters.map(\.order))
    let missing = (order...max(order, last)).filter { !have.contains($0) }
    guard !missing.isEmpty, let bookmark = book.bookmark else { return }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return }
    let toc = book.toc
    Task {
      let added: [NarrationChapter] = await Task.detached(priority: .utility) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else { return [] }
        let chapters = toc.enumerated().map { Chapter(title: $1.title, level: 0, pageIndex: $1.pageIndex, order: $0) }
        return missing.map { i in
          let pages = ChapterText.pageRange(of: i, in: chapters, pageCount: doc.pageCount)
          return NarrationChapter(order: i, title: toc[i].title, pageIndex: toc[i].pageIndex,
                                  lines: ChapterText.lines(from: ChapterText.text(doc: doc, pages: pages)))
        }
      }.value
      guard var b = self.books[key], !added.isEmpty else { return }
      let have = Set(b.chapters.map(\.order))
      b.chapters = (b.chapters + added.filter { !have.contains($0.order) }).sorted { $0.order < $1.order }
      self.books[key] = b
      NarrationStore.save(b)
      self.start()
    }
  }

  func updateListen(_ listen: NarrationBook.Listen, in key: String) {
    guard var book = books[key] else { return }
    book.listen = listen
    books[key] = book
    NarrationStore.save(book)
  }

  func deleteAudio(_ key: String) {
    if case .generating(let k, _) = status, k == key { stop() }
    if let book = books[key] { NarrationStore.delete(book) }
    books[key] = nil
  }

  func remove(chapter order: Int, from key: String) {
    guard var book = books[key], let i = book.chapters.firstIndex(where: { $0.order == order }) else { return }
    for part in book.chapters[i].parts { try? FileManager.default.removeItem(at: book.url(of: part)) }
    book.chapters.remove(at: i)
    books[key] = book
    NarrationStore.save(book)
  }

  // MARK: Running

  func start() {
    guard worker == nil, hasPendingWork, ModelDownloader.shared.isInstalled else { return }
    if inBackground, !NarrationPlayer.shared.isPlaying {
      status = .paused("Open PDF Studio to continue narrating."); return
    }
    if #available(iOS 26.0, *), !inBackground, submitContinuedTask() { return }
    backgroundMode = "Generates while PDF Studio is open or narration is playing."
    run(task: nil)
  }

  func stop() {
    worker?.cancel()
    worker = nil
    status = .idle
  }

  @available(iOS 26.0, *)
  private func submitContinuedTask() -> Bool {
    let id = (Bundle.main.bundleIdentifier ?? "pdfstudio") + ".narrate." + UUID().uuidString.prefix(8)
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
      guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
      Task { @MainActor in self.run(task: task) }
    }
    guard registered else { return false }
    let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Narrating chapters", subtitle: "Starting…")
    request.strategy = .fail
    let gpu = Self.supportsBackgroundGPU
    if gpu { request.requiredResources = .gpu }
    do {
      try BGTaskScheduler.shared.submit(request)
      backgroundGPU = gpu
      backgroundMode = gpu ? "Keeps generating in the background (GPU)."
                           : "Keeps generating in the background (CPU; this iPhone doesn't allow background GPU work)."
      status = .loadingModel
      return true
    } catch {
      log.error("continued task rejected: \(error.localizedDescription)")
      return false
    }
  }

  private func run(task: AnyObject?) {
    guard worker == nil else {
      if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask { t.setTaskCompleted(success: true) }
      return
    }
    bgTask = task
    if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask {
      t.progress.totalUnitCount = 1000
      t.expirationHandler = { [weak self] in
        Task { @MainActor in
          self?.worker?.cancel()
          self?.status = .paused("iOS paused background narration. Open PDF Studio to continue.")
        }
      }
    }
    worker = Task { [weak self] in
      await self?.loop()
      guard let self else { return }
      self.worker = nil
      if #available(iOS 26.0, *), let t = self.bgTask as? BGContinuedProcessingTask {
        t.setTaskCompleted(success: !self.hasPendingWork)
      }
      self.bgTask = nil
      if !self.hasPendingWork {
        self.status = .idle
        self.engine.unload()
      }
    }
  }

  private func loop() async {
    do {
      if !engine.isLoaded {
        status = .loadingModel
        let available = os_proc_available_memory()
        if available > 0, available < 500_000_000 {
          throw NarratorError.memory(available)
        }
        // A nonisolated async call runs off the main thread and is cancelled with this task.
        try await engine.load()
      }
      while !Task.isCancelled, let (key, idx) = nextWork() {
        try await generate(key: key, index: idx)
      }
    } catch is CancellationError {
      // Paused or stopped.
    } catch {
      log.error("narration failed: \(error.localizedDescription)")
      status = .failed(error.localizedDescription)
    }
  }

  private func nextWork() -> (String, Int)? {
    // Books you listened to most recently first; within a book, chapters in order.
    for book in books.values.sorted(by: { $0.updated > $1.updated }) {
      if let i = book.chapters.firstIndex(where: { !$0.isDone }) { return (book.key, i) }
    }
    return nil
  }

  private func generate(key: String, index: Int) async throws {
    guard let book = books[key] else { return }
    let chapter = book.chapters[index]
    status = .generating(book: key, chapter: chapter.order)
    var samples: [Float] = []
    var linesInBuffer = 0
    let gap = [Float](repeating: 0, count: KokoroEngine.sampleRate * 3 / 10)
    var line = chapter.nextLine
    while line < chapter.lines.count {
      try Task.checkCancellation()
      let item = chapter.lines[line]
      let voice = book.voice(for: item)
      let t0 = Date()
      // The GPU is off-limits in the background unless iOS granted it; Kokoro runs on the CPU then.
      let audio = try await engine.speak(item.t, voice: voice, cpu: inBackground && !(bgTask != nil && backgroundGPU))
      let compute = Date().timeIntervalSince(t0)
      samples += audio
      samples += gap
      linesInBuffer += 1
      line += 1
      recordSpeed(audio: Double(audio.count) / Double(KokoroEngine.sampleRate), compute: compute)
      reportProgress(key: key, index: index, line: line)
      if Double(samples.count) / Double(KokoroEngine.sampleRate) >= flushSeconds || line == chapter.lines.count {
        try await flush(samples, key: key, index: index, lines: linesInBuffer)
        samples = []
        linesInBuffer = 0
      }
    }
    if chapter.lines.isEmpty, var b = books[key] {
      b.chapters[index].nextLine = 0
      books[key] = b
    }
  }

  private func flush(_ samples: [Float], key: String, index: Int, lines: Int) async throws {
    guard var book = books[key], index < book.chapters.count else { return }
    let chapter = book.chapters[index]
    let name = "c\(chapter.order)-p\(chapter.parts.count).m4a"
    let url = book.dir.appendingPathComponent(name)
    try await Task.detached(priority: .utility) { try AudioPartWriter.write(samples, to: url) }.value
    book.chapters[index].parts.append(.init(file: name, duration: Double(samples.count) / Double(KokoroEngine.sampleRate)))
    book.chapters[index].nextLine += lines
    books[key] = book
    NarrationStore.save(book)
  }

  private func recordSpeed(audio: Double, compute: Double) {
    stats.audio += audio
    stats.compute += compute
    if stats.compute > 5 {
      speed = stats.audio / stats.compute
      UserDefaults.standard.set(speed, forKey: Self.speedKey)
    }
  }

  private func reportProgress(key: String, index: Int, line: Int) {
    guard #available(iOS 26.0, *), let t = bgTask as? BGContinuedProcessingTask, let book = books[key] else { return }
    let total = book.chapters.reduce(0) { $0 + $1.lines.count }
    let done = book.chapters.enumerated().reduce(0) { sum, e in sum + (e.offset == index ? line : e.element.nextLine) }
    t.progress.completedUnitCount = Int64(Double(done) / Double(max(total, 1)) * 1000)
    let ch = book.chapters[index]
    t.updateTitle("Narrating \(book.title)", subtitle: "\(ch.title) · \(Int(Double(line) / Double(max(ch.lines.count, 1)) * 100))%")
  }

  // MARK: App lifecycle

  private func enteredBackground() {
    inBackground = true
    // With no background task and nothing playing, iOS suspends the app: pause cleanly.
    if bgTask == nil, worker != nil, !NarrationPlayer.shared.isPlaying {
      worker?.cancel()
      worker = nil
      status = .paused("Paused while PDF Studio is in the background.")
    }
  }

  private func enteredForeground() {
    inBackground = false
    guard worker == nil else { return }
    if case .failed = status { return }
    start()
  }
}

enum NarratorError: LocalizedError {
  case memory(Int)

  var errorDescription: String? {
    switch self {
    case .memory(let bytes):
      return "Not enough free memory to load the voice (\(bytes / 1_000_000) MB free, about 500 MB needed). Close other apps and try again."
    }
  }
}
