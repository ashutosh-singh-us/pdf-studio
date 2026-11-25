import AVFoundation
import MLX
import XCTest
@testable import PDFStudio

/// Downloads the real voice files (about 340 MB) and speaks a line. Opt-in (RUN_KOKORO_E2E=1), and only
/// on a real device: MLX needs a Metal device, which the iOS simulator doesn't provide.
final class KokoroEndToEndTests: XCTestCase {
  func testKokoroSpeaksOfflineFromDownloadedFiles() async throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("MLX can't run in the iOS simulator")
    #endif
    try XCTSkipUnless(ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_KOKORO_E2E"] == "1"
                      || ProcessInfo.processInfo.environment["RUN_KOKORO_E2E"] == "1", "opt-in")
    for file in VoiceFiles.all where !file.isInstalled {
      let (tmp, response) = try await URLSession.shared.download(from: file.remote)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, file.path)
      try FileManager.default.createDirectory(at: file.local.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: file.local)
      try FileManager.default.moveItem(at: tmp, to: file.local)
      FileManager.default.createFile(atPath: file.verifiedMarker.path, contents: Data())
    }
    XCTAssertTrue(VoiceFiles.all.allSatisfy(\.isInstalled))

    let engine = KokoroEngine()
    // MLX has no GPU in the simulator: load and run everything on the CPU.
    try await Device.withDefaultDevice(.cpu) { try await engine.load() }
    let text = "The blacksmith wiped the soot from his face and stared at the glowing blade."
    let start = Date()
    let samples = try await Device.withDefaultDevice(.cpu) { try await engine.speak(text, voice: KokoroEngine.defaultNarrator, cpu: true) }
    let seconds = Double(samples.count) / Double(KokoroEngine.sampleRate)
    let compute = Date().timeIntervalSince(start)
    print("KOKORO cpu: \(seconds)s audio in \(compute)s (\(seconds / compute)x real time)")
    XCTAssertGreaterThan(seconds, 2)
    XCTAssertLessThan(seconds, 15)
    XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.05)

    let dialogue = try await Device.withDefaultDevice(.cpu) {
      try await engine.speak("You actually did it!", voice: KokoroEngine.defaultDialogue, cpu: true)
    }
    XCTAssertGreaterThan(dialogue.count, KokoroEngine.sampleRate / 2)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-e2e.m4a")
    try AudioPartWriter.write(samples + dialogue, to: url)
    print("KOKORO wrote \(url.path)")
  }
}
