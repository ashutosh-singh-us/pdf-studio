import AVFoundation
import PDFKit
import XCTest
@testable import PDFStudio

final class NarratorTests: XCTestCase {
  func testDialogueGetsItsOwnVoice() {
    let lines = ChapterText.lines(from: "Grid looked up. “You did it!” she said, laughing. “Don't celebrate yet,” he replied.")
    XCTAssertEqual(lines.map(\.v), [0, 1, 0, 1, 0])
    XCTAssertEqual(lines[1].t, "You did it!")
    XCTAssertEqual(lines[2].t, "she said, laughing.")
    XCTAssertEqual(lines[3].t, "Don't celebrate yet")
  }

  func testStraightQuotesAndUnbalancedQuotes() {
    XCTAssertEqual(ChapterText.lines(from: "He said \"run\" and ran.").map(\.v), [0, 1, 0])
    // A stray opening quote shouldn't turn the rest of the chapter into dialogue.
    let long = "He paused. \"" + String(repeating: "The wind howled across the plain. ", count: 30)
    XCTAssertTrue(ChapterText.lines(from: long).allSatisfy { $0.v == 0 })
  }

  func testLinesStayShortAndKeepAllWords() {
    let text = String(repeating: "The hammer rang against the anvil, and sparks flew across the dark smithy. ", count: 20)
    let lines = ChapterText.lines(from: text)
    XCTAssertTrue(lines.allSatisfy { $0.t.count <= ChapterText.maxLineChars + 1 })
    XCTAssertEqual(ChapterText.wordCount(lines), text.split(separator: " ").count)
    let huge = String(repeating: "word, ", count: 200)
    XCTAssertTrue(ChapterText.lines(from: huge).allSatisfy { $0.t.count <= ChapterText.maxLineChars + 1 })
  }

  func testAngleBracketsCantInjectEmotionTags() {
    XCTAssertFalse(ChapterText.lines(from: "Status window <laugh> opened.").contains { $0.t.contains("<") })
  }

  func testPageTextDropsNumbersHeadersAndHyphens() {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { ctx in
      for i in 0..<3 {
        ctx.beginPage()
        let text = "Overgeared\nThe black-\nsmith worked page \(i).\n\(i + 1)"
        (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 340, height: 540), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
      }
    }
    let doc = PDFDocument(data: data)!
    let text = ChapterText.text(doc: doc, pages: 0..<3)
    XCTAssertEqual(text.components(separatedBy: "Overgeared").count - 1, 1, text)
    XCTAssertFalse(text.contains(" 2 "), text)
    XCTAssertTrue(text.contains("blacksmith"), text)
  }

  func testChapterPageRanges() {
    let ch = [Chapter(title: "A", level: 0, pageIndex: 0, order: 0),
              Chapter(title: "B", level: 0, pageIndex: 4, order: 1),
              Chapter(title: "C", level: 0, pageIndex: 9, order: 2)]
    XCTAssertEqual(ChapterText.pageRange(of: 0, in: ch, pageCount: 12), 0..<4)
    XCTAssertEqual(ChapterText.pageRange(of: 1, in: ch, pageCount: 12), 4..<9)
    XCTAssertEqual(ChapterText.pageRange(of: 2, in: ch, pageCount: 12), 9..<12)
  }

  func testAudioPartsAreSmallAAC() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("part-\(UUID()).m4a")
    let rate = Float(KokoroEngine.sampleRate)
    let samples = (0..<(KokoroEngine.sampleRate * 60)).map { sin(Float($0) * 2 * .pi * 220 / rate) * 0.3 }
    try AudioPartWriter.write(samples, to: url)
    let file = try AVAudioFile(forReading: url)
    XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 60, accuracy: 0.2)
    let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
    print("AAC minute: \(bytes) bytes")
    XCTAssertLessThan(bytes, 400_000) // about 0.24 MB a minute
  }

  func testModelFilesArePinned() {
    XCTAssertEqual(VoiceFiles.all.count, 6 + 18)
    XCTAssertTrue(VoiceFiles.all.allSatisfy { $0.remote.absoluteString.contains("/resolve/") && $0.revision.count == 40 })
    XCTAssertTrue(VoiceFiles.all.filter { $0.size > 1_000_000 }.allSatisfy { $0.sha256 != nil })
    XCTAssertLessThan(VoiceFiles.totalBytes, 400_000_000)
    XCTAssertTrue(VoiceFiles.voiceNames.contains(KokoroEngine.defaultNarrator))
    XCTAssertTrue(VoiceFiles.voiceNames.contains(KokoroEngine.defaultDialogue))
    XCTAssertEqual(KokoroEngine.displayName("am_michael"), "Michael (US ♂)")
  }
}
