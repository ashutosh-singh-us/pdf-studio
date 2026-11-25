import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import PDFStudio

@MainActor
final class PDFStudioTests: XCTestCase {
  // A 2-page Letter PDF with real text on each page.
  private func samplePDF(pages: Int = 2) -> PDFDocument {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
      for i in 0..<pages {
        ctx.beginPage()
        ("Hello page \(i + 1)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
      }
    }
    return PDFDocument(data: data)!
  }

  private func reload(_ doc: PDFDocument) throws -> PDFDocument {
    try XCTUnwrap(PDFDocument(data: try PDFWriter.data(for: doc)))
  }

  /// Colour at a page-space point, rendered at 1 px per point.
  private func pixel(_ page: PDFPage, at p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let box = page.bounds(for: .mediaBox)
    let img = page.thumbnail(of: box.size, for: .mediaBox)
    let cg = img.cgImage!
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let sx = CGFloat(w) / box.width, sy = CGFloat(h) / box.height
    let x = Int((p.x - box.minX) * sx), y = Int((box.maxY - p.y) * sy)  // image rows go top-down
    let i = (y * w + x) * 4
    return (CGFloat(buf[i]) / 255, CGFloat(buf[i + 1]) / 255, CGFloat(buf[i + 2]) / 255)
  }

  // MARK: Markdown

  func testMarkdownDecodesBOMAndRoundTrips() throws {
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data("# Title\n\nCafé ✓\n".utf8))
    XCTAssertEqual(StudioDocument.decodeText(data), "# Title\n\nCafé ✓\n")
    let doc = StudioDocument()
    doc.markdown = "# Hi\n"
    XCTAssertEqual(try doc.snapshot(contentType: .markdownDocument), Data("# Hi\n".utf8))
  }

  func testNewDocumentsAreMarkdown() {
    XCTAssertEqual(StudioDocument.writableContentTypes.first, .markdownDocument)
    XCTAssertTrue(UTType.markdownDocument.conforms(to: .plainText))
  }

  // MARK: Annotations survive saving

  func testInkIsSavedWhereItWasDrawn() throws {
    let doc = samplePDF()
    let page = doc.page(at: 0)!
    let pts = (0...20).map { CGPoint(x: 300 + CGFloat($0) * 5, y: 400) }   // horizontal line y=400, x 300…400
    page.addAnnotation(InkBuilder.annotation(points: pts, color: .blue, width: 6))
    let saved = try reload(doc).page(at: 0)!
    XCTAssertEqual(saved.annotations.filter { $0.type == "Ink" }.count, 1)
    let on = pixel(saved, at: CGPoint(x: 350, y: 400))
    XCTAssertGreaterThan(on.b, 0.5); XCTAssertLessThan(on.r, 0.5, "ink should be drawn on its points")
    let off = pixel(saved, at: CGPoint(x: 350, y: 440))
    XCTAssertGreaterThan(off.r, 0.9, "nothing should be drawn away from the stroke")
  }

  func testTextBoxRoundTrips() throws {
    let doc = samplePDF()
    let page = doc.page(at: 0)!
    let a = PDFAnnotation(bounds: .zero, forType: .freeText, withProperties: nil)
    TextStyle.apply(text: "Signed off", size: 18, color: .red, to: a, topLeft: CGPoint(x: 100, y: 500), page: page)
    page.addAnnotation(a)
    let saved = try reload(doc).page(at: 0)!
    let text = try XCTUnwrap(saved.annotations.first { $0.type == "FreeText" })
    XCTAssertEqual(text.contents, "Signed off")
    XCTAssertEqual(text.bounds.maxY, 500, accuracy: 1, "text box hangs down from the tap point")
  }

  func testTextBoxIsVisible() throws {
    let doc = samplePDF(pages: 1)
    let page = doc.page(at: 0)!
    let a = PDFAnnotation(bounds: .zero, forType: .freeText, withProperties: nil)
    TextStyle.apply(text: "WWWWWWWW", size: 40, color: .red, to: a, topLeft: CGPoint(x: 100, y: 500), page: page)
    page.addAnnotation(a)
    func redPixels(_ p: PDFPage) -> Int {
      (0..<40).reduce(0) { n, i in let c = pixel(p, at: CGPoint(x: 105 + CGFloat(i) * 5, y: 480)); return n + (c.r > 0.7 && c.g < 0.4 ? 1 : 0) }
    }
    XCTAssertGreaterThan(redPixels(page), 3, "live text box should render")
    XCTAssertGreaterThan(redPixels(try reload(doc).page(at: 0)!), 3, "saved text box should render")
  }

  func testImagesAreFlattenedIntoThePageKeepingTextAndOtherAnnotations() throws {
    let doc = samplePDF()
    let page = doc.page(at: 0)!
    let red = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { c in
      UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    }
    page.addAnnotation(ImageStampAnnotation(image: red, bounds: CGRect(x: 200, y: 200, width: 100, height: 100)))
    page.addAnnotation(InkBuilder.annotation(points: [CGPoint(x: 400, y: 600), CGPoint(x: 500, y: 600)], color: .blue, width: 4))

    let saved = try reload(doc)
    let p = saved.page(at: 0)!
    XCTAssertEqual(saved.pageCount, 2)
    XCTAssertTrue(p.annotations.allSatisfy { $0.type != "Stamp" }, "picture must be part of the page, not an annotation")
    XCTAssertEqual(p.annotations.filter { $0.type == "Ink" }.count, 1, "other annotations stay editable")
    XCTAssertTrue(p.string?.contains("Hello page 1") == true, "page text must survive flattening")
    let c = pixel(p, at: CGPoint(x: 250, y: 250))
    XCTAssertGreaterThan(c.r, 0.8); XCTAssertLessThan(c.g, 0.2)
    // The live document still has its editable picture.
    XCTAssertEqual(page.annotations.compactMap { $0 as? ImageStampAnnotation }.count, 1)
  }

  func testRotatedPageFlattensUpright() throws {
    let doc = samplePDF(pages: 1)
    let page = doc.page(at: 0)!
    page.rotation = 90
    let img = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { c in
      UIColor.green.setFill(); c.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    }
    page.addAnnotation(ImageStampAnnotation(image: img, bounds: CGRect(x: 50, y: 50, width: 60, height: 60)))
    let p = try reload(doc).page(at: 0)!
    XCTAssertEqual(p.rotation, 90)
    XCTAssertTrue(p.string?.contains("Hello page 1") == true)
  }

  // MARK: Editing with undo

  private func makeEditor(pages: Int = 3) -> (PDFEditor, UndoManager) {
    let editor = PDFEditor(document: StudioDocument(pdf: samplePDF(pages: pages)))
    let um = UndoManager()
    um.groupsByEvent = false
    editor.undoManager = um
    return (editor, um)
  }

  private func step(_ um: UndoManager, _ body: () -> Void) {
    um.beginUndoGrouping(); body(); um.endUndoGrouping()
  }

  func testPageOperationsUndo() throws {
    let (e, um) = makeEditor()
    let first = e.doc.page(at: 0)!
    step(um) { e.deletePages([0]) }
    XCTAssertEqual(e.doc.pageCount, 2)
    um.undo()
    XCTAssertEqual(e.doc.pageCount, 3)
    XCTAssertTrue(e.doc.page(at: 0) === first)
    um.redo()
    XCTAssertEqual(e.doc.pageCount, 2)
    um.undo()

    step(um) { e.movePage(from: 0, to: 2) }
    XCTAssertTrue(e.doc.page(at: 2) === first)
    um.undo()
    XCTAssertTrue(e.doc.page(at: 0) === first)

    step(um) { e.rotate([0, 1], by: 90) }
    XCTAssertEqual(e.doc.page(at: 1)?.rotation, 90)
    um.undo()
    XCTAssertEqual(e.doc.page(at: 1)?.rotation, 0)

    step(um) { e.insertBlankPage(after: 0) }
    XCTAssertEqual(e.doc.pageCount, 4)
    XCTAssertEqual(e.doc.page(at: 1)?.string ?? "", "")
    um.undo()
    XCTAssertEqual(e.doc.pageCount, 3)

    e.deletePages([0, 1, 2])
    XCTAssertEqual(e.doc.pageCount, 3, "can't delete every page")
    XCTAssertNotNil(e.message)
  }

  func testMergeAndExtract() throws {
    let (e, um) = makeEditor(pages: 2)
    step(um) { e.merge([samplePDF(pages: 3)]) }
    XCTAssertEqual(e.doc.pageCount, 5)
    let out = try XCTUnwrap(PDFDocument(data: try e.extract([4, 0])))
    XCTAssertEqual(out.pageCount, 2)
    XCTAssertTrue(out.page(at: 0)?.string?.contains("Hello page 1") == true)
    XCTAssertTrue(out.page(at: 1)?.string?.contains("Hello page 3") == true)
    um.undo()
    XCTAssertEqual(e.doc.pageCount, 2)
    // Merged pages are still written correctly after the source document is gone.
    let reloaded = try reload(e.doc)
    XCTAssertEqual(reloaded.pageCount, 2)
  }

  func testAnnotationAddMoveDeleteUndo() throws {
    let (e, um) = makeEditor(pages: 1)
    let page = e.doc.page(at: 0)!
    let a = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 50), forType: .square, withProperties: nil)
    step(um) { e.add(a, to: page, name: "Box") }
    XCTAssertEqual(page.annotations.count, 1)
    step(um) { e.setBounds(CGRect(x: 100, y: 100, width: 50, height: 50), of: a, name: "Move") }
    XCTAssertEqual(a.bounds.minX, 100)
    um.undo()
    XCTAssertEqual(a.bounds.minX, 10)
    um.undo()
    XCTAssertEqual(page.annotations.count, 0)
    um.redo()
    XCTAssertEqual(page.annotations.count, 1)
  }

  func testEditingTextBoxIsUndoable() throws {
    let (e, um) = makeEditor(pages: 1)
    let page = e.doc.page(at: 0)!
    step(um) { e.commitText(TextEditRequest(text: "One", fontSize: 14, color: .black, annotation: nil, page: page, point: CGPoint(x: 72, y: 700))) }
    let a = try XCTUnwrap(page.annotations.first)
    step(um) { e.commitText(TextEditRequest(text: "Two words", fontSize: 20, color: .red, annotation: a, page: page, point: .zero)) }
    XCTAssertEqual(a.contents, "Two words")
    XCTAssertEqual(a.bounds.maxY, 700, accuracy: 0.5, "editing keeps the top-left corner in place")
    um.undo()
    XCTAssertEqual(a.contents, "One")
  }

  func testSignatureRendering() {
    XCTAssertNil(SignatureRenderer.image(text: "  ", color: .black))
    let img = SignatureRenderer.image(text: "Jane Doe", color: .black)
    XCTAssertNotNil(img)
    XCTAssertGreaterThan(img!.size.width, img!.size.height)
  }

  func testMarkdownRendererIsBundled() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "markdown", withExtension: "html"))
    let html = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(html.contains("Content-Security-Policy"))
    XCTAssertTrue(html.contains("window.pdfstudio"))
  }

  // MARK: Chapters and reading position

  private func novel() -> PDFDocument {
    // Page 1 title page, chapters on pages 2, 4, 5; page 3 has a running header repeating chapter 1.
    let pages = ["OVERGEARED\nVolume 1", "Chapter 1 - The Beginning\nGrid was poor.", "Chapter 1 - The Beginning\nStill chapter one.",
                 "Chapter 2: Legendary Class\nText.", "Epilogue\nThe end of the chapter was near."]
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { ctx in
      for text in pages {
        ctx.beginPage()
        (text as NSString).draw(in: CGRect(x: 40, y: 40, width: 320, height: 500), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
      }
    }
    return PDFDocument(data: data)!
  }

  func testHeadingDetection() {
    XCTAssertTrue(ChapterIndex.isHeading("Chapter 12"))
    XCTAssertTrue(ChapterIndex.isHeading("CHAPTER 1563 - Grid's Choice"))
    XCTAssertTrue(ChapterIndex.isHeading("Prologue"))
    XCTAssertTrue(ChapterIndex.isHeading("Side Story 3"))
    XCTAssertFalse(ChapterIndex.isHeading("The chapter ended with a bang and everyone went home happily ever after."))
    XCTAssertFalse(ChapterIndex.isHeading("Grid was poor."))
  }

  func testScanFindsChaptersAndSkipsRunningHeaders() {
    let found = ChapterIndex.scan(novel(), isCancelled: { false }) { _, _ in }
    XCTAssertEqual(found.map(\.pageIndex), [0, 1, 3, 4])
    XCTAssertEqual(found.map(\.title).prefix(2), ["Volume 1", "Chapter 1 - The Beginning"])
    XCTAssertEqual(found.last?.title, "Epilogue")
  }

  func testOutlineIsUsedWhenPresent() {
    let doc = novel()
    let root = PDFOutline()
    for (i, title) in ["Start", "Middle"].enumerated() {
      let item = PDFOutline()
      item.label = title
      item.destination = PDFDestination(page: doc.page(at: i * 2)!, at: CGPoint(x: 0, y: 600))
      root.insertChild(item, at: i)
    }
    doc.outlineRoot = root
    let chapters = ChapterIndex.fromOutline(doc)
    XCTAssertEqual(chapters.map(\.title), ["Start", "Middle"])
    XCTAssertEqual(chapters.map(\.pageIndex), [0, 2])
  }

  func testReadingPositionIsRemembered() {
    let key = "test-\(UUID().uuidString)"
    XCTAssertNil(ReadingPosition.load(key))
    ReadingPosition.save(.init(page: 42, x: 0, y: 300, date: Date()), key: key)
    XCTAssertEqual(ReadingPosition.load(key)?.page, 42)
    XCTAssertEqual(ReadingPosition.load(key)?.y, 300)
    XCTAssertEqual(DocumentKey.make(fileURL: URL(fileURLWithPath: "/x/Overgeared.pdf"), doc: novel()), "Overgeared.pdf#5")
  }

  func testScanSpeedOnANovel() {
    let body = String(repeating: "Grid swung the hammer and the anvil rang across the smithy. ", count: 40)
    let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { ctx in
      for i in 0..<2000 {
        ctx.beginPage()
        let text = (i % 10 == 0 ? "Chapter \(i / 10 + 1)\n" : "") + body
        (text as NSString).draw(in: CGRect(x: 30, y: 30, width: 340, height: 540), withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
      }
    }
    let doc = PDFDocument(data: data)!
    let start = Date()
    let found = ChapterIndex.scan(doc, isCancelled: { false }) { _, _ in }
    let seconds = Date().timeIntervalSince(start)
    print("SCAN 2000 pages: \(seconds)s")
    XCTAssertEqual(found.count, 200)
  }
}
