import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// Plays generated chapters in order, with lock-screen and headphone controls.
/// If it catches up with generation it waits, and continues when the next part is ready.
@MainActor
final class NarrationPlayer: ObservableObject {
  static let shared = NarrationPlayer()

  @Published private(set) var bookKey: String?
  @Published private(set) var chapterOrder: Int?
  @Published private(set) var isPlaying = false
  @Published private(set) var waiting = false
  @Published private(set) var elapsed: Double = 0
  @Published var rate: Float = 1.0 { didSet { if isPlaying { player.rate = rate } } }

  private let player = AVPlayer()
  private var part = 0
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var storeWatch: AnyCancellable?
  private var lastSaved = Date.distantPast

  private init() {
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) { [weak self] t in
      MainActor.assumeIsolated { self?.tick(t.seconds) }
    }
    setUpRemoteCommands()
  }

  private var book: NarrationBook? { bookKey.flatMap { Narrator.shared.books[$0] } }
  private var chapter: NarrationChapter? {
    guard let book, let chapterOrder else { return nil }
    return book.chapters.first { $0.order == chapterOrder }
  }

  var chapterTitle: String { chapter?.title ?? "" }
  /// Seconds into the current chapter.
  var chapterElapsed: Double {
    guard let chapter else { return 0 }
    return chapter.parts.prefix(part).reduce(0) { $0 + $1.duration } + elapsed
  }

  // MARK: Control

  /// Plays a book from a chapter (or from where you left off).
  func play(_ key: String, chapter order: Int? = nil) {
    guard let book = Narrator.shared.books[key] else { return }
    let resume = order == nil || order == book.listen?.chapter
    let target = order ?? book.listen?.chapter ?? book.chapters.first?.order ?? 0
    bookKey = key
    chapterOrder = target
    part = resume ? (book.listen?.part ?? 0) : 0
    let time = resume ? (book.listen?.time ?? 0) : 0
    activateSession()
    Narrator.shared.reached(chapter: target, in: key)
    load(seek: time)
  }

  func toggle() { isPlaying ? pause() : resume() }

  func pause() {
    player.pause()
    isPlaying = false
    save(force: true)
    updateNowPlaying()
  }

  func resume() {
    guard bookKey != nil else { return }
    activateSession()
    if player.currentItem == nil { load(seek: elapsed) } else { player.rate = rate; isPlaying = true }
    updateNowPlaying()
  }

  func skip(_ seconds: Double) {
    let t = max(0, player.currentTime().seconds + seconds)
    if let item = player.currentItem, t >= item.duration.seconds, !item.duration.isIndefinite { advance(); return }
    if t == 0, seconds < 0, part > 0 { part -= 1; load(seek: max(0, (chapter?.parts[part].duration ?? 0) + seconds)); return }
    player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
  }

  func nextChapter() {
    guard let book, let chapterOrder, let next = book.chapters.first(where: { $0.order > chapterOrder }) else { return }
    self.chapterOrder = next.order
    part = 0
    Narrator.shared.reached(chapter: next.order, in: book.key)
    load(seek: 0)
  }

  func previousChapter() {
    guard let book, let chapterOrder else { return }
    if chapterElapsed > 5 { part = 0; load(seek: 0); return }
    guard let prev = book.chapters.last(where: { $0.order < chapterOrder }) else { return }
    self.chapterOrder = prev.order
    part = 0
    load(seek: 0)
  }

  func stop() {
    save(force: true)
    player.replaceCurrentItem(with: nil)
    isPlaying = false
    waiting = false
    bookKey = nil
    chapterOrder = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  // MARK: Internals

  private func load(seek: Double) {
    guard let book, let chapter else { return }
    guard part < chapter.parts.count else {
      // Caught up with generation, or the chapter hasn't started yet.
      if chapter.isDone { advance(); return }
      wait()
      return
    }
    waiting = false
    storeWatch = nil
    let item = AVPlayerItem(url: book.url(of: chapter.parts[part]))
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.advance() }
    }
    player.replaceCurrentItem(with: item)
    if seek > 0 { player.seek(to: CMTime(seconds: seek, preferredTimescale: 600)) }
    elapsed = seek
    player.rate = rate
    isPlaying = true
    updateNowPlaying()
  }

  private func advance() {
    guard let book, let chapter else { return }
    if part + 1 < chapter.parts.count || !chapter.isDone {
      part += 1
      load(seek: 0)
      return
    }
    guard let next = book.chapters.first(where: { $0.order > chapter.order }) else {
      // End of what's been queued.
      pause()
      return
    }
    chapterOrder = next.order
    part = 0
    Narrator.shared.reached(chapter: next.order, in: book.key)
    load(seek: 0)
  }

  private func wait() {
    waiting = true
    isPlaying = false
    player.replaceCurrentItem(with: nil)
    updateNowPlaying()
    storeWatch = Narrator.shared.$books.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.waiting, let chapter = self.chapter else { return }
        if self.part < chapter.parts.count || chapter.isDone { self.load(seek: 0) }
      }
    }
  }

  private func tick(_ seconds: Double) {
    guard player.currentItem != nil, seconds.isFinite else { return }
    elapsed = seconds
    save(force: false)
  }

  private func save(force: Bool) {
    guard let bookKey, let chapterOrder, force || Date().timeIntervalSince(lastSaved) > 5 else { return }
    lastSaved = Date()
    Narrator.shared.updateListen(.init(chapter: chapterOrder, part: part, time: elapsed), in: bookKey)
  }

  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    try? session.setActive(true)
  }

  private func updateNowPlaying() {
    guard let book, let chapter else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: chapter.title,
      MPMediaItemPropertyAlbumTitle: book.title,
      MPMediaItemPropertyArtist: "PDF Studio Narrator",
      MPMediaItemPropertyPlaybackDuration: chapter.isDone ? chapter.duration : max(chapter.duration, chapter.estimatedDuration),
      MPNowPlayingInfoPropertyElapsedPlaybackTime: chapterElapsed,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
    ]
  }

  private func setUpRemoteCommands() {
    let c = MPRemoteCommandCenter.shared()
    c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
    c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
    c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
    c.skipForwardCommand.preferredIntervals = [15]
    c.skipBackwardCommand.preferredIntervals = [15]
    c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(15) }; return .success }
    c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-15) }; return .success }
    c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.nextChapter() }; return .success }
    c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previousChapter() }; return .success }
  }
}
