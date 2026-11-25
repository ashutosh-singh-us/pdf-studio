import XCTest

/// Drives the real app: open files from the document browser and use the main tools.
/// Set SEED_DIR (TEST_RUNNER_SEED_DIR) to a folder holding Sample.pdf and README.md.
/// Set SCREENSHOT_DIR to save PNGs (also used for App Store screenshots).
final class PDFStudioUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  /// Opens a file from SEED_DIR directly in the editor (debug builds only).
  private func launch(with fileName: String) {
    let seed = ProcessInfo.processInfo.environment["SEED_DIR"] ?? ""
    app.launchEnvironment["PDFSTUDIO_OPEN_FILE"] = seed + "/" + fileName
    app.launch()
  }

  private func shot(_ name: String) {
    let png = XCUIScreen.main.screenshot().pngRepresentation
    let att = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    att.name = name
    att.lifetime = .keepAlways
    add(att)
    if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
      try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
  }

  func testPDFWorkflow() throws {
    launch(with: "Sample.pdf")
    let read = app.buttons["Read"]
    XCTAssertTrue(read.waitForExistence(timeout: 15))
    sleep(1)
    shot("01-pdf-read")

    // Draw a squiggle.
    app.buttons["Draw"].tap()
    let page = app.otherElements.firstMatch
    let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45))
    let end = page.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end)
    // Box.
    app.buttons["Box"].tap()
    page.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25))
      .press(forDuration: 0.1, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.32)))
    // Text.
    app.buttons["Text"].tap()
    page.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.6)).tap()
    let sheet = app.navigationBars["Add Text"]
    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    sleep(1)
    app.typeText("Approved by PDF Studio")
    shot("02a-text-sheet")
    sheet.buttons["Done"].tap()
    sleep(1)
    shot("02-pdf-annotated")

    XCTAssertTrue(app.buttons["Undo"].isEnabled, "edits should be undoable")

    // Signature (scroll the tool bar to reach it).
    app.buttons["Box"].swipeLeft()
    app.buttons["Sign"].tap()
    app.buttons["Type"].tap()
    app.textFields["Your name"].tap()
    app.textFields["Your name"].typeText("Ashu")
    shot("03-signature")
    app.buttons["Add"].tap()
    sleep(1)
    shot("04-signature-placed")

    // Pages.
    app.buttons["More"].tap()
    app.buttons["Pages…"].tap()
    sleep(2)
    shot("05-pages")
    app.buttons["Done"].firstMatch.tap()
  }

  func testMarkdownWorkflow() throws {
    launch(with: "README.md")
    sleep(3)
    shot("06-markdown-preview")
    app.buttons["Edit"].tap()
    sleep(1)
    shot("07-markdown-edit")
    app.buttons["Preview"].tap()
    app.buttons["More"].tap()
    app.buttons["Outline"].tap()
    sleep(1)
    shot("08-markdown-outline")
  }
}
