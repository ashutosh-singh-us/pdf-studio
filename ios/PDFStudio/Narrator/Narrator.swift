import BackgroundTasks
import Foundation
import os
import PDFKit
import UIKit

/// Queues chapters, generates their audio with Kokoro, and keeps going in the background where iOS allows it.
///
/// Background rules on iPhone: apps can't use the GPU from the background, except inside a
/// continued-processing task (iOS 26+) on devices that support background GPU. That task is started
/// when you tap Generate and shows its progress in a Live Activity. Without it, generation pauses when
/// you leave the app and resumes when you return. (MLX on the CPU was far too slow to be a fallback.)
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
  private var isActive = true
  /// The last line the voice engine failed on, shown in Listen so it can be reported.
  @Published private(set) var lastEngineError: String? = UserDefaults.standard.string(forKey: "narratorLastError")
  /// GPU work is allowed while the app is on screen, or inside a background GPU task.
  private var gpuAllowed: Bool { (isActive && !inBackground) || backgroundGPUActive }
  /// A background GPU task is running and hasn't been expired by iOS.
  private var backgroundGPUActive = false
  /// You tapped Pause: don't resume automatically.
  private var userPaused = false
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
    // Stop GPU work as soon as the app starts leaving the screen (lock, app switcher, call), before
    // iOS starts rejecting it; resume when it's active again.
    nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { self.isActive = false }
    }
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        self.isActive = true
        self.enteredForeground()
      }
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
    userPaused = false
    resume()
  }

  private func resume() {
    guard worker == nil, !userPaused, hasPendingWork, ModelDownloader.shared.isInstalled else { return }
    if inBackground { status = .paused("Open PDF Studio to continue narrating."); return }
    if #available(iOS 26.0, *), Self.supportsBackgroundGPU, submitContinuedTask() { return }
    backgroundMode = "Generates while PDF Studio is open. This iPhone doesn't allow background GPU work."
    run(task: nil)
  }

  /// Pause. The running line finishes (or is cancelled) before the worker exits.
  func stop() {
    userPaused = true
    worker?.cancel()
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
    request.requiredResources = .gpu
    do {
      try BGTaskScheduler.shared.submit(request)
      backgroundMode = "Keeps generating in the background."
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
    backgroundGPUActive = task != nil
    if #available(iOS 26.0, *), let t = task as? BGContinuedProcessingTask {
      t.progress.totalUnitCount = 1000
      t.expirationHandler = { [weak self] in
        Task { @MainActor in
          self?.backgroundGPUActive = false
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
      self.backgroundGPUActive = false
      if !self.hasPendingWork {
        self.status = .idle
        self.engine.unload()
      } else if self.gpuAllowed {
        // Stopped for a reason that no longer applies (e.g. the app came back on screen).
        if case .failed = self.status {} else { self.resume() }
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
      if !gpuAllowed { status = .paused("Paused while PDF Studio is off screen.") }
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
      if !gpuAllowed { throw CancellationError() }
      let item = chapter.lines[line]
      let voice = book.voice(for: item)
      let t0 = Date()
      let audio: [Float]
      do {
        audio = try await speakWithRetry(item.t, voice: voice)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // If the app left the screen mid-line, iOS rejected the GPU work: pause, don't fail.
        if !gpuAllowed { throw CancellationError() }
        // Otherwise skip this one line rather than blocking the whole queue, and keep the message.
        noteEngineError(error, line: item.t)
        consecutiveFailures += 1
        if consecutiveFailures >= 5 { throw error }
        audio = []
      }
      if !audio.isEmpty { consecutiveFailures = 0 }
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

  private var consecutiveFailures = 0

  private func speakWithRetry(_ text: String, voice: String) async throws -> [Float] {
    do {
      return try await engine.speak(text, voice: voice)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard gpuAllowed else { throw error }
      log.error("voice engine error, retrying: \(String(describing: error))")
      return try await engine.speak(text, voice: voice)
    }
  }

  private func noteEngineError(_ error: Error, line: String) {
    let message = "\(String(describing: error)) — line: \(line.prefix(80))"
    log.error("skipped line: \(message)")
    lastEngineError = message
    UserDefaults.standard.set(message, forKey: "narratorLastError")
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
    // Without a background GPU task, iOS rejects GPU work once we're in the background.
    if !backgroundGPUActive, worker != nil {
      worker?.cancel()
      status = .paused("Paused while PDF Studio is in the background.")
    }
  }

  private func enteredForeground() {
    inBackground = false
    guard worker == nil else { return }
    if case .failed = status { return }
    resume()
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
