import CryptoKit
import Foundation
import UIKit

/// Where the narrator keeps its model and generated audio (Application Support, not backed up to iCloud).
enum NarratorPaths {
  static var root: URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Narrator", isDirectory: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var u = url
      try? u.setResourceValues(values)
    }
    return url
  }

  static var models: URL { dir("Models") }
  static var books: URL { dir("Books") }

  private static func dir(_ name: String) -> URL {
    let url = root.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

/// One file of the voice model, pinned to an exact Hugging Face commit so every install gets the same bytes.
struct ModelFile: Hashable {
  let repo: String
  let revision: String
  let path: String
  let size: Int64
  /// SHA-256 of the large files, checked after download.
  let sha256: String?
  /// Folder the file is saved in (relative to the models folder).
  let folder: String

  var remote: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")! }
  var local: URL { VoiceFiles.dir(folder).appendingPathComponent(path) }
  var id: String { "\(repo)|\(path)" }
  var verifiedMarker: URL { local.appendingPathExtension("ok") }

  var isInstalled: Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value
    guard size == self.size else { return false }
    return sha256 == nil || FileManager.default.fileExists(atPath: verifiedMarker.path)
  }
}

/// Kokoro-82M (hexgrad, Apache-2.0) in MLX format, its English voices, and the English
/// pronunciation dictionary (Misaki/CMUdict based, MIT). About 340 MB in total.
enum VoiceFiles {
  static let kokoroRepo = "mlx-community/Kokoro-82M-bf16"
  private static let kokoroRev = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
  static let g2pRepo = "beshkenadze/kitten-tts-g2p"
  private static let g2pRev = "9c692b92682d959d9013a9cfe6a49541997add18"

  /// The model's folder.
  static let kokoroFolder = "kokoro"
  /// mlx-audio looks for the pronunciation files at <cache>/mlx-audio/<repo with _>.
  static let g2pFolder = "mlx-audio/beshkenadze_kitten-tts-g2p"

  /// English voices: (file name, SHA-256).
  private static let voices: [(String, String)] = [
    ("af_heart", "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094"),
    ("af_bella", "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3"),
    ("af_nicole", "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062"),
    ("af_sarah", "4940072182542f54c1035d1daf4c1cf3136ca9baa9ac57c8e006b4befcc50be6"),
    ("af_sky", "957af332330db8e9bd7f9dc449475a946cb0d7d689afef64b91007bbbf20eaa0"),
    ("am_michael", "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea"),
    ("am_fenrir", "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538"),
    ("am_puck", "9a8c2e56413bd2063f814cb4c3885fc425876157369117c3f8258d03c8a9ad89"),
    ("am_adam", "a4f60a3b9c20353c2604a17485ba53260502a758681a84d41e8af53cc559d929"),
    ("am_liam", "66b65a96e16c3d91035a6e9019d9986ed524d27ce35b487270cdf61c99e3ebad"),
    ("am_onyx", "b5d6132a5747648d98c82c9c4aaa9cf52d7230e63e403c1cb9c12858446ca5f5"),
    ("am_echo", "031fc608a900332c4e1a29bd0884f5d0e84bd0348261fa79981e5cbd138c950d"),
    ("bf_emma", "8878a75a6661305849eeb1d6293a7177250193616e161b4c3100636434dfe69f"),
    ("bf_isabella", "f7b6076f025649699fcfed1a6debf13049a87afdc7aafc8c72b7d81246db6ead"),
    ("bm_george", "a3d9b8995cbbe5536f954b6be2a0f1f312f077118ba0d4d2178fc41dc8306672"),
    ("bm_lewis", "e1e68013c21a141efe527aaec561e1174c2f5a6951b3bcecc8396adab315b247"),
    ("bm_daniel", "b195dec592ee024f57ddc5bf481464596082ba60998a2a295eba90bfc1064f4b"),
    ("bm_fable", "9fa80184e96d016a744bc13b0b2e7695e55d6b855556fa003325cb1e5ebf2c2b"),
  ]

  static var voiceNames: [String] { voices.map(\.0) }

  static let all: [ModelFile] = [
    ModelFile(repo: kokoroRepo, revision: kokoroRev, path: "config.json", size: 2351, sha256: nil, folder: kokoroFolder),
    ModelFile(repo: kokoroRepo, revision: kokoroRev, path: "kokoro-v1_0.safetensors", size: 327_115_152,
              sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8", folder: kokoroFolder),
    ModelFile(repo: g2pRepo, revision: g2pRev, path: "us_bart.safetensors", size: 3_011_692,
              sha256: "dc4a02e62d4fcb4bb4097ecf00db89b8e1a12a549a52ab6adfbba220b80a55c5", folder: g2pFolder),
    ModelFile(repo: g2pRepo, revision: g2pRev, path: "us_bart_config.json", size: 1257, sha256: nil, folder: g2pFolder),
    ModelFile(repo: g2pRepo, revision: g2pRev, path: "us_gold.json", size: 3_001_196,
              sha256: "8507f89840f0813b10cf584740942f58e9cc9ad3660e24088b442ab0a6b126be", folder: g2pFolder),
    ModelFile(repo: g2pRepo, revision: g2pRev, path: "us_silver.json", size: 3_105_352,
              sha256: "ea0e1abca0c9b18fb0d3402034633a337154a3153e9a9f49f97d668c908e140c", folder: g2pFolder),
  ] + voices.map {
    ModelFile(repo: kokoroRepo, revision: kokoroRev, path: "voices/\($0.0).safetensors", size: 522_320, sha256: $0.1,
              folder: kokoroFolder)
  }

  static var totalBytes: Int64 { all.reduce(0) { $0 + $1.size } }

  static func dir(_ folder: String) -> URL {
    let url = NarratorPaths.models.appendingPathComponent(folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// mlx-audio treats a folder with a valid config.json as a complete offline copy; the
  /// pronunciation repo has none, so write an empty one.
  static func finishInstall() {
    let config = dir(g2pFolder).appendingPathComponent("config.json")
    if !FileManager.default.fileExists(atPath: config.path) {
      try? Data("{}".utf8).write(to: config)
    }
    for f in all where f.path.contains("/") {
      try? FileManager.default.createDirectory(at: f.local.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
  }

  /// Earlier test builds downloaded Orpheus (1.9 GB). Remove it.
  static func removeOldModels() {
    let fm = FileManager.default
    for name in ["mlx-community_orpheus-3b-0.1-ft-4bit", "mlx-community_snac_24khz"] {
      let url = NarratorPaths.models.appendingPathComponent(name)
      if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }
  }
}

/// Downloads the voice model with a background URLSession, so it keeps going if you leave the app.
@MainActor
final class ModelDownloader: NSObject, ObservableObject {
  static let shared = ModelDownloader()

  enum State: Equatable {
    case notInstalled
    case downloading
    case verifying
    case installed
    case failed(String)
  }

  @Published private(set) var state: State = .notInstalled
  @Published private(set) var bytesDone: Int64 = 0
  var progress: Double { Double(bytesDone) / Double(VoiceFiles.totalBytes) }
  var isInstalled: Bool { state == .installed }

  /// Set by the app delegate when iOS relaunches the app to deliver finished downloads.
  var backgroundCompletion: (() -> Void)?

  private var taskBytes: [String: Int64] = [:]
  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: (Bundle.main.bundleIdentifier ?? "pdfstudio") + ".models")
    config.sessionSendsLaunchEvents = true
    config.isDiscretionary = false
    config.timeoutIntervalForResource = 60 * 60 * 24
    return URLSession(configuration: config, delegate: self, delegateQueue: .main)
  }()

  override private init() {
    super.init()
    VoiceFiles.removeOldModels()
    VoiceFiles.finishInstall()
    refresh()
  }

  func refresh() {
    if VoiceFiles.all.allSatisfy(\.isInstalled) { state = .installed; return }
    // Reattach to downloads that were running when the app was last closed.
    session.getAllTasks { tasks in
      Task { @MainActor in
        if !tasks.isEmpty, self.state == .notInstalled { self.state = .downloading }
      }
    }
  }

  func start() {
    guard state != .installed else { return }
    state = .downloading
    session.getAllTasks { running in
      Task { @MainActor in
        let active = Set(running.compactMap(\.taskDescription))
        var done: Int64 = 0
        for file in VoiceFiles.all {
          if file.isInstalled { done += file.size; continue }
          if active.contains(file.id) { continue }
          try? FileManager.default.removeItem(at: file.local)
          let task = self.session.downloadTask(with: file.remote)
          task.taskDescription = file.id
          task.countOfBytesClientExpectsToReceive = file.size
          task.resume()
        }
        self.bytesDone = done
        self.taskBytes = [:]
        self.checkFinished()
      }
    }
  }

  func cancel() {
    session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    state = .notInstalled
    bytesDone = 0
  }

  /// Removes the voice model. Generated audio is kept.
  func delete() {
    cancel()
    try? FileManager.default.removeItem(at: NarratorPaths.models)
    state = .notInstalled
  }

  private func file(for task: URLSessionTask) -> ModelFile? {
    VoiceFiles.all.first { $0.id == task.taskDescription }
  }

  private func checkFinished() {
    if VoiceFiles.all.allSatisfy(\.isInstalled) {
      state = .installed
      bytesDone = VoiceFiles.totalBytes
    }
  }

  private func installedBytes() -> Int64 {
    VoiceFiles.all.filter(\.isInstalled).reduce(0) { $0 + $1.size }
  }

  private func verify(_ file: ModelFile) {
    guard let expected = file.sha256 else { checkFinished(); return }
    state = .verifying
    Task.detached(priority: .utility) {
      let ok = Self.sha256(of: file.local) == expected
      await MainActor.run {
        if ok {
          FileManager.default.createFile(atPath: file.verifiedMarker.path, contents: Data())
          self.state = .downloading
          self.checkFinished()
        } else {
          try? FileManager.default.removeItem(at: file.local)
          self.state = .failed("\(file.path) was damaged in transit. Tap Download to try again.")
        }
      }
    }
  }

  nonisolated private static func sha256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = autoreleasepool { try? handle.read(upToCount: 8 << 20) }
      guard let chunk, !chunk.isEmpty else { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

extension ModelDownloader: URLSessionDownloadDelegate {
  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                              didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
    MainActor.assumeIsolated {
      guard let id = downloadTask.taskDescription else { return }
      taskBytes[id] = totalBytesWritten
      bytesDone = installedBytes() + taskBytes.values.reduce(0, +)
      if state == .notInstalled { state = .downloading }
    }
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // The temporary file is deleted when this returns, so move it now (same volume: a rename).
    MainActor.assumeIsolated {
      guard let file = file(for: downloadTask) else { return }
      let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else {
        state = .failed("Download failed (HTTP \(status)) for \(file.path).")
        return
      }
      try? FileManager.default.removeItem(at: file.local)
      try? FileManager.default.createDirectory(at: file.local.deletingLastPathComponent(), withIntermediateDirectories: true)
      do {
        try FileManager.default.moveItem(at: location, to: file.local)
      } catch {
        state = .failed(error.localizedDescription)
        return
      }
      taskBytes[file.id] = nil
      verify(file)
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    MainActor.assumeIsolated {
      guard let error else { return }
      if (error as NSError).code == NSURLErrorCancelled { return }
      state = .failed(error.localizedDescription)
    }
  }

  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    MainActor.assumeIsolated {
      backgroundCompletion?()
      backgroundCompletion = nil
    }
  }
}
