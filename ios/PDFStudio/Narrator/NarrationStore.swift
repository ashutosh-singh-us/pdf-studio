import AVFoundation
import Foundation

/// A chapter queued for narration, with its text and the audio parts made so far.
struct NarrationChapter: Codable, Identifiable, Hashable {
  struct Part: Codable, Hashable {
    let file: String
    let duration: Double
  }

  /// Index in the book's chapter list.
  let order: Int
  let title: String
  let pageIndex: Int
  var lines: [NarrationLine]
  /// Lines before this one are saved in `parts`.
  var nextLine = 0
  var parts: [Part] = []

  var id: Int { order }
  var isDone: Bool { nextLine >= lines.count }
  var duration: Double { parts.reduce(0) { $0 + $1.duration } }
  var fraction: Double { lines.isEmpty ? 1 : Double(nextLine) / Double(lines.count) }
  /// At about 150 words a minute.
  var estimatedDuration: Double { Double(ChapterText.wordCount(lines)) / 2.5 }
}

/// Everything the narrator knows about one book. Saved as Books/<key>/book.json.
struct NarrationBook: Codable, Identifiable {
  struct Listen: Codable, Hashable {
    var chapter: Int
    var part: Int
    var time: Double
  }

  struct TOCEntry: Codable, Hashable {
    let title: String
    let pageIndex: Int
  }

  let key: String
  var title: String
  var narratorVoice: String
  var dialogueVoice: String
  /// Full chapter list, so later chapters can be queued while you listen.
  var toc: [TOCEntry]
  var chapters: [NarrationChapter]
  /// Bookmark to the PDF, for reading more chapters without the book open.
  var bookmark: Data?
  /// Keep this many chapters generated ahead of where you're listening (0 = only the chosen range).
  var ahead: Int
  var listen: Listen?
  var updated: Date

  var id: String { key }
  var pending: [NarrationChapter] { chapters.filter { !$0.isDone } }

  func voice(for line: NarrationLine) -> String { line.v == 1 ? dialogueVoice : narratorVoice }

  var dir: URL {
    let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
    let url = NarratorPaths.books.appendingPathComponent(String(safe.prefix(120)), isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func url(of part: NarrationChapter.Part) -> URL { dir.appendingPathComponent(part.file) }

  var audioBytes: Int64 {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return files.filter { $0.pathExtension == "m4a" }
      .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
  }
}

enum NarrationStore {
  static func loadAll() -> [String: NarrationBook] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: NarratorPaths.books, includingPropertiesForKeys: nil)) ?? []
    var out: [String: NarrationBook] = [:]
    for dir in dirs {
      if let data = try? Data(contentsOf: dir.appendingPathComponent("book.json")),
         let book = try? JSONDecoder().decode(NarrationBook.self, from: data) {
        out[book.key] = book
      }
    }
    return out
  }

  static func save(_ book: NarrationBook) {
    if let data = try? JSONEncoder().encode(book) {
      try? data.write(to: book.dir.appendingPathComponent("book.json"), options: .atomic)
    }
  }

  static func delete(_ book: NarrationBook) {
    try? FileManager.default.removeItem(at: book.dir)
  }
}

/// Writes speech as AAC in .m4a: 32 kbps mono is about 14 MB per hour.
enum AudioPartWriter {
  static func write(_ samples: [Float], to url: URL) throws {
    let rate = Double(KokoroEngine.sampleRate)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
    ]
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + url.lastPathComponent)
    try? FileManager.default.removeItem(at: tmp)
    do {
      let file = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
      let chunk = 1 << 16
      var start = 0
      while start < samples.count {
        let n = min(chunk, samples.count - start)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        let dst = buffer.floatChannelData![0]
        for i in 0..<n { dst[i] = max(-1, min(1, samples[start + i])) }
        try file.write(from: buffer)
        start += n
      }
    }
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: tmp, to: url)
  }
}
