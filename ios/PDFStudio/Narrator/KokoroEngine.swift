import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioTTS

/// Runs Kokoro-82M with MLX. Loads only from the downloaded files; never touches the network.
/// Small enough to run on the CPU too, which iOS allows in the background when the GPU isn't.
final class KokoroEngine: @unchecked Sendable {
  static let sampleRate = 24_000
  static var voices: [String] { VoiceFiles.voiceNames }
  static let defaultNarrator = "am_michael"
  static let defaultDialogue = "af_heart"

  /// "am_michael" → "Michael (US)".
  static func displayName(_ voice: String) -> String {
    let parts = voice.split(separator: "_", maxSplits: 1)
    guard parts.count == 2 else { return voice }
    let region = parts[0].first == "b" ? "UK" : "US"
    let gender = parts[0].last == "f" ? "♀" : "♂"
    return "\(parts[1].capitalized) (\(region) \(gender))"
  }

  private var model: KokoroModel?
  private let lock = NSLock()

  var isLoaded: Bool { lock.withLock { model != nil } }

  func load() async throws {
    if isLoaded { return }
    #if !targetEnvironment(simulator)  // the simulator has no Metal device for MLX
    Memory.cacheLimit = 32 * 1024 * 1024
    #endif
    VoiceFiles.finishInstall()
    let processor = MisakiTextProcessor(cache: HubCache(cacheDirectory: NarratorPaths.models))
    let m = try await KokoroModel.fromModelDirectory(VoiceFiles.dir(VoiceFiles.kokoroFolder), textProcessor: processor)
    lock.withLock { model = m }
  }

  func unload() {
    lock.withLock { model = nil }
    #if !targetEnvironment(simulator)
    Memory.clearCache()
    #endif
  }

  /// Speaks one line. `cpu` runs it on the CPU (for when iOS doesn't allow background GPU use).
  func speak(_ text: String, voice: String, cpu: Bool = false) async throws -> [Float] {
    guard let model = lock.withLock({ model }) else { throw CancellationError() }
    try Task.checkCancellation()
    let run = {
      try await model.generate(text: text, voice: voice, refAudio: nil, refText: nil, language: "en-us",
                               generationParameters: model.defaultGenerationParameters)
    }
    let audio = cpu ? try await Device.withDefaultDevice(.cpu, run) : try await run()
    return audio.asArray(Float.self)
  }
}
