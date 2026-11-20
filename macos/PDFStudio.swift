// PDF Studio for macOS: a native app window around the single-file web app (PDF-Studio.html).
// WebKit runs the app unchanged. This file supplies what a browser would otherwise provide:
// Finder "Open With", open/save/print dialogs, JavaScript dialogs and an unsaved-changes guard.
// Build with macos/build.sh.

import Cocoa
import PDFKit
import UniformTypeIdentifiers
import WebKit

private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PDF Studio"
private let markdownType = UTType("net.daringfireball.markdown")
private let externalSchemes: Set<String> = ["http", "https", "mailto"]

// Runs in the page before the app's own code. The app saves with showSaveFilePicker (Chrome/Edge only)
// and prints through window.open / window.print, so those are routed to native dialogs here.
// window.__pdfstudio is the app's own hook object (see the end of src/app.js).
private let bridgeScript = #"""
(() => {
  const native = window.webkit.messageHandlers;
  const toBase64 = (blob) => new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => { const s = String(r.result); resolve(s.slice(s.indexOf(',') + 1)); };
    r.onerror = () => reject(r.error);
    r.readAsDataURL(blob);
  });
  window.showSaveFilePicker = async (opts = {}) => {
    const exts = (opts.types || []).flatMap((t) => Object.values(t.accept || {}).flat()).map((e) => String(e).replace(/^\./, ''));
    const target = await native.pdfstudioReply.postMessage({ type: 'savePanel', name: String(opts.suggestedName || 'Untitled'), exts });
    if (!target) throw new DOMException('Save cancelled', 'AbortError');
    return {
      kind: 'file', name: target.name,
      async createWritable() {
        const parts = [];
        return {
          async write(data) { parts.push(data); },
          async close() { await native.pdfstudioReply.postMessage({ type: 'saveWrite', token: target.token, data: await toBase64(new Blob(parts)) }); },
        };
      },
    };
  };
  window.print = () => native.pdfstudio.postMessage({ type: 'printPage' });
  const openWindow = window.open;
  window.open = function (url, ...rest) {
    if (typeof url === 'string' && url.startsWith('blob:')) {
      fetch(url).then((r) => r.blob()).then(toBase64)
        .then((data) => native.pdfstudio.postMessage({ type: 'showPdf', title: (window.__pdfstudio && window.__pdfstudio.S.name) || 'Document', data }))
        .catch((e) => console.error('PDF Studio: could not open the print preview', e));
      return {}; // not null, so the app reports that the preview opened in a new window
    }
    return openWindow.call(window, url, ...rest);
  };
  window.__pdfstudioNative = {
    state() {
      const S = window.__pdfstudio && window.__pdfstudio.S;
      return { hasDoc: !!S && (S.pages.length > 0 || S.mode === 'md'), dirty: !!(S && S.dirty) };
    },
    async open(name, type, base64) {
      let bytes;
      if (Uint8Array.fromBase64) bytes = Uint8Array.fromBase64(base64);
      else { const bin = atob(base64); bytes = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i); }
      await window.__pdfstudio.openAny([new File([bytes], name, { type })]);
    },
  };
})();
"""#

// MARK: - Shared helpers

private func makeAlert(_ message: String, buttons: [String]) -> NSAlert {
  let alert = NSAlert()
  let paragraphs = message.components(separatedBy: "\n\n")
  alert.messageText = paragraphs[0]
  alert.informativeText = paragraphs.dropFirst().joined(separator: "\n\n")
  buttons.forEach { alert.addButton(withTitle: $0) }
  return alert
}

/// Shows an alert as a sheet on `window` (or app-modal without one).
@MainActor
private func present(_ alert: NSAlert, for window: NSWindow?, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
  #if DEBUG
  if let answer = TestHooks.answer(alert) { done(answer); return }
  #endif
  if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
}

@MainActor
private func runPrint(_ op: NSPrintOperation, for window: NSWindow, testFile: String) {
  op.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
  #if DEBUG
  if let dir = TestHooks.dir {
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    op.printInfo.jobDisposition = .save
    op.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = dir.appendingPathComponent(testFile)
    TestHooks.log("print: \(testFile)")
  }
  #endif
  op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
}

/// WKUserContentController keeps its handlers alive; this proxy lets a window controller be freed.
@MainActor
private final class ScriptHandler: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
  weak var owner: DocumentWindowController?
  init(_ owner: DocumentWindowController) { self.owner = owner }

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.handle(message)
  }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard let owner else { replyHandler(nil, "The window was closed."); return }
    owner.handle(message, reply: replyHandler)
  }
}

// MARK: - Document window

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  /// Set once a file has been sent to this window, so a batch of files gets one window each.
  private(set) var hasReceivedFile = false
  var onClose: ((DocumentWindowController) -> Void)?

  private let pageURL: URL
  private var pageLoaded = false
  private var pendingFiles: [URL] = []
  private var documentFolder: URL?
  private var saveTargets: [String: URL] = [:]   // token -> file the user picked in a Save dialog
  private var closeConfirmed = false
  private var titleObservation: NSKeyValueObservation?

  init(pageURL: URL) {
    self.pageURL = pageURL
    let config = WKWebViewConfiguration()
    config.userContentController.addUserScript(
      WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    webView = WKWebView(frame: .zero, configuration: config)

    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    let size = NSSize(width: min(1280, visible.width * 0.9), height: min(880, visible.height * 0.9))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = appName
    window.minSize = NSSize(width: 640, height: 420)
    window.isRestorable = false
    window.tabbingIdentifier = "PDF Studio Document"   // documents share one tab bar
    window.contentView = webView
    super.init(window: window)
    window.delegate = self

    let handler = ScriptHandler(self)
    config.userContentController.add(handler, name: "pdfstudio")
    config.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "pdfstudioReply")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    #if DEBUG
    if #available(macOS 13.3, *) { webView.isInspectable = true }
    #endif
    titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
      let title = webView.title
      DispatchQueue.main.async { self?.updateTitle(title) }
    }
    loadApp()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private func loadApp() {
    pageLoaded = false
    webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
  }

  /// The page shows "• name — PDF Studio" while there are unsaved changes.
  private func updateTitle(_ title: String?) {
    var text = title ?? ""
    let edited = text.hasPrefix("\u{2022} ")
    if edited { text.removeFirst(2) }
    let suffix = " \u{2014} PDF Studio"
    if text.hasSuffix(suffix) { text.removeLast(suffix.count) }
    window?.title = text.isEmpty ? appName : text
    window?.isDocumentEdited = edited
  }

  // MARK: Opening files

  func open(_ url: URL) {
    hasReceivedFile = true
    if pageLoaded { send(url) } else { pendingFiles.append(url) }
  }

  /// Marks this window as taken before an asynchronous check, so the next file in a batch can't claim it too.
  func claim() { hasReceivedFile = true }

  private func send(_ url: URL) {
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      present(makeAlert("Could not open “\(url.lastPathComponent)”.\n\n\(error.localizedDescription)", buttons: ["OK"]), for: window) { _ in }
      return
    }
    documentFolder = url.deletingLastPathComponent()
    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? ""
    webView.callAsyncJavaScript("await window.__pdfstudioNative.open(name, type, data)",
                                arguments: ["name": url.lastPathComponent, "type": type, "data": data.base64EncodedString()],
                                in: nil, in: .page) { [weak self] result in
      if case .failure(let error) = result {
        present(makeAlert("Could not open “\(url.lastPathComponent)”.\n\n\(error.localizedDescription)", buttons: ["OK"]), for: self?.window) { _ in }
      }
      #if DEBUG
      self?.runTestChecks()
      #endif
    }
  }

  /// Asks the page whether it shows a document and whether it has unsaved changes.
  func pageState(_ done: @escaping (_ hasDoc: Bool, _ dirty: Bool) -> Void) {
    webView.callAsyncJavaScript("return window.__pdfstudioNative.state()", arguments: [:], in: nil, in: .page) { result in
      let state = (try? result.get()) as? [String: Any]
      done(state?["hasDoc"] as? Bool ?? false, state?["dirty"] as? Bool ?? false)
    }
  }

  // MARK: Menu actions (also reached when the page doesn't handle the shortcut itself)

  @objc func saveDocument(_ sender: Any?) { clickPageButton("btnSave") }
  @objc func printDocument(_ sender: Any?) { clickPageButton("btnPrint") }

  private func clickPageButton(_ id: String) {
    webView.callAsyncJavaScript("document.getElementById(id)?.click()", arguments: ["id": id], in: nil, in: .page)
  }

  // MARK: Messages from the page

  fileprivate func handle(_ message: WKScriptMessage) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
    switch type {
    case "printPage":
      guard let window else { return }
      let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
      info.isHorizontallyCentered = false
      info.isVerticallyCentered = false
      let op = webView.printOperation(with: info)
      op.view?.frame = webView.bounds   // WebKit prints blank pages if its print view has no size
      runPrint(op, for: window, testFile: "print-page.pdf")
    case "showPdf":
      guard let base64 = body["data"] as? String, let data = Data(base64Encoded: base64), let doc = PDFDocument(data: data) else {
        present(makeAlert("Could not prepare the document for printing.", buttons: ["OK"]), for: window) { _ in }
        return
      }
      (NSApp.delegate as? AppDelegate)?.showPrintPreview(doc, title: body["title"] as? String ?? "Document")
    default:
      break
    }
  }

  fileprivate func handle(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
    guard let body = message.body as? [String: Any], let type = body["type"] as? String else { reply(nil, "Invalid request."); return }
    switch type {
    case "savePanel":
      let name = body["name"] as? String ?? "Untitled"
      let exts = (body["exts"] as? [String] ?? []).filter { !$0.isEmpty && !$0.contains("/") }
      chooseSaveURL(name: name, extensions: exts) { [weak self] url in
        guard let self, let url else { reply(nil, nil); return }
        let token = UUID().uuidString
        self.saveTargets[token] = url
        reply(["token": token, "name": url.lastPathComponent], nil)
      }
    case "saveWrite":
      // The page can only write to a file the user just picked, identified by a one-time token.
      guard let token = body["token"] as? String, let url = saveTargets.removeValue(forKey: token) else {
        reply(nil, "This save wasn't started from a Save dialog."); return
      }
      guard let base64 = body["data"] as? String, let data = Data(base64Encoded: base64) else {
        reply(nil, "The document data was invalid."); return
      }
      do {
        try data.write(to: url, options: .atomic)
        reply(true, nil)
      } catch {
        reply(nil, error.localizedDescription)
      }
    default:
      reply(nil, "Unknown request.")
    }
  }

  private func chooseSaveURL(name: String, extensions: [String], _ done: @escaping (URL?) -> Void) {
    let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    #if DEBUG
    if let dir = TestHooks.dir { TestHooks.log("save: \(safeName)"); done(dir.appendingPathComponent(safeName)); return }
    #endif
    guard let window else { done(nil); return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = safeName
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    let types = extensions.compactMap { UTType(filenameExtension: $0) }
    if !types.isEmpty { panel.allowedContentTypes = types }
    if let documentFolder { panel.directoryURL = documentFolder }
    panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    pageLoaded = true
    let files = pendingFiles
    pendingFiles = []
    files.forEach(send)
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { decisionHandler(.cancel); return }
    if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
    // The app itself (including #anchors inside it) may load; web links open in the default browser.
    if url.isFileURL && url.path == pageURL.path { decisionHandler(.allow); return }
    if externalSchemes.contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    decisionHandler(.cancel)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loadApp() }

  // MARK: WKUIDelegate

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url, externalSchemes.contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
    return nil
  }

  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    guard let window else { completionHandler(nil); return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    present(makeAlert(message, buttons: ["OK"]), for: window) { _ in completionHandler() }
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    present(makeAlert(message, buttons: ["OK", "Cancel"]), for: window) { completionHandler($0 == .alertFirstButtonReturn) }
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
               initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    let alert = makeAlert(prompt, buttons: ["OK", "Cancel"])
    // The app's only prompt asks for a PDF password, so hide what is typed there.
    let field = prompt.lowercased().contains("password")
      ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = defaultText ?? ""
    #if DEBUG
    if let text = TestHooks.env["PDFSTUDIO_TEST_PROMPT"] { field.stringValue = text }
    #endif
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    present(alert, for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
  }

  // MARK: NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeConfirmed { return true }
    if sender.attachedSheet != nil { return false }
    pageState { [weak self] _, dirty in
      guard let self else { return }
      guard dirty else { self.closeConfirmed = true; sender.close(); return }
      sender.tabGroup?.selectedWindow = sender   // show the tab being asked about
      let alert = makeAlert("Close “\(sender.title)” without saving?\n\nYour changes will be lost.",
                            buttons: ["Cancel", "Close Without Saving"])
      present(alert, for: sender) { response in
        if response == .alertSecondButtonReturn { self.closeConfirmed = true; sender.close() }
      }
    }
    return false
  }

  func windowWillClose(_ notification: Notification) {
    titleObservation = nil
    webView.configuration.userContentController.removeAllScriptMessageHandlers()
    onClose?(self)
  }

  // MARK: Automated checks

  #if DEBUG
  private static var testCount = 0

  /// After a file opens: run PDFSTUDIO_TEST_JS, then write a state JSON and a snapshot into PDFSTUDIO_TEST_DIR.
  private func runTestChecks() {
    guard let dir = TestHooks.dir else { return }
    DocumentWindowController.testCount += 1
    let n = DocumentWindowController.testCount
    let script = TestHooks.env["PDFSTUDIO_TEST_JS"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "return null"
    if TestHooks.env["PDFSTUDIO_TEST_ZOOM"] != nil, let window, !window.isZoomed { window.zoom(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self else { return }
      self.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
        var report: [String: Any] = [:]
        switch result {
        case .success(let value): report["result"] = value
        case .failure(let error): report["error"] = String(describing: error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          let stateJS = "const S = window.__pdfstudio.S; return { mode: S.mode, name: S.name, pages: S.pages.length, dirty: S.dirty, rotations: S.pages.map((p) => p.rot) }"
          self.webView.callAsyncJavaScript(stateJS, arguments: [:], in: nil, in: .page) { state in
            report["state"] = (try? state.get()) ?? "unavailable"
            report["windowTitle"] = self.window?.title ?? ""
            report["windowEdited"] = self.window?.isDocumentEdited ?? false
            report["tabs"] = self.window?.tabbedWindows?.map(\.title) ?? []
            report["tabBarVisible"] = self.window?.tabGroup?.isTabBarVisible ?? false
            let json = JSONSerialization.isValidJSONObject(report)
              ? (try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]))
              : Data(String(describing: report).utf8)
            try? json?.write(to: dir.appendingPathComponent("w\(n)-state.json"))
            self.webView.takeSnapshot(with: nil) { image, _ in
              if let tiff = image?.tiffRepresentation,
                 let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("w\(n)-snapshot.png"))
              }
              for title in ["View", "Window"] {
                let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu
                menu?.update()
                TestHooks.log("\(title) menu: " + (menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []).joined(separator: " | "))
              }
              TestHooks.log("window \(n): checks done")
              switch TestHooks.env["PDFSTUDIO_TEST_THEN"] {
              case "close": self.window?.performClose(nil)
              case "quit": NSApp.terminate(nil)
              default: break
              }
            }
          }
        }
      }
    }
  }
  #endif
}

// MARK: - Print preview window (for the edited PDF)

@MainActor
final class PrintPreviewController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
  var onClose: ((PrintPreviewController) -> Void)?
  private let pdf: PDFDocument
  private let printItem = NSToolbarItem.Identifier("print")

  init(document: PDFDocument, title: String) {
    self.pdf = document
    let pdfView = PDFView()
    pdfView.document = document
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.title = "Print Preview \u{2014} \(title)"
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.contentView = pdfView
    super.init(window: window)
    window.delegate = self
    let toolbar = NSToolbar(identifier: "PrintPreview")
    toolbar.delegate = self
    toolbar.displayMode = .iconAndLabel
    window.toolbar = toolbar
    window.center()
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  @objc func printDocument(_ sender: Any?) {
    guard let window else { return }
    let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
    guard let op = pdf.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
    runPrint(op, for: window, testFile: "print-pdf.pdf")
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, printItem] }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, printItem] }
  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    guard id == printItem else { return nil }
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = "Print"
    item.toolTip = "Print, or choose “Save as PDF” in the print window"
    item.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "Print")
    item.target = self
    item.action = #selector(printDocument(_:))
    return item
  }

  func windowWillClose(_ notification: Notification) { onClose?(self) }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var documents: [DocumentWindowController] = []
  private var previews: [PrintPreviewController] = []
  private var quitConfirmed = false
  private let pageURL: URL = {
    guard let url = Bundle.main.url(forResource: "PDF-Studio", withExtension: "html") else {
      fatalError("PDF-Studio.html is missing from the app bundle")
    }
    return url
  }()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMainMenu()
    // Files from "Open With" arrive before this, and already have windows.
    if documents.isEmpty { newDocumentWindow() }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    urls.forEach(openFile)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag && documents.isEmpty { newDocumentWindow(); return false }
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitConfirmed || documents.isEmpty { return .terminateNow }
    var dirtyCount = 0
    let group = DispatchGroup()
    for doc in documents {
      group.enter()
      doc.pageState { _, dirty in
        if dirty { dirtyCount += 1 }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      guard dirtyCount > 0 else { sender.reply(toApplicationShouldTerminate: true); return }
      let what = dirtyCount == 1 ? "A document has unsaved changes." : "\(dirtyCount) documents have unsaved changes."
      let alert = makeAlert("\(what)\n\nQuit \(appName) anyway? Your changes will be lost.", buttons: ["Cancel", "Quit Anyway"])
      present(alert, for: nil) { response in
        self.quitConfirmed = response == .alertSecondButtonReturn
        sender.reply(toApplicationShouldTerminate: self.quitConfirmed)
      }
    }
    return .terminateLater
  }

  /// The frontmost document window. orderedWindows (front to back) still works while another app
  /// is active, as when a file is opened from Terminal or Finder; NSApp.mainWindow is nil then.
  private var frontDocument: DocumentWindowController? {
    NSApp.orderedWindows.lazy.compactMap { $0.windowController as? DocumentWindowController }.first ?? documents.last
  }

  /// Use the front tab if nothing is open in it yet, otherwise a new tab.
  func openFile(_ url: URL) {
    guard let window = frontDocument, !window.hasReceivedFile else {
      newDocumentWindow().open(url)
      return
    }
    window.claim()
    window.pageState { [weak self] hasDoc, _ in
      if hasDoc { self?.newDocumentWindow().open(url) } else { window.open(url) }
    }
  }

  /// A new document goes in a tab of the front window; `inTab: false` makes a separate window.
  @discardableResult
  func newDocumentWindow(inTab: Bool = true) -> DocumentWindowController {
    let doc = DocumentWindowController(pageURL: pageURL)
    doc.onClose = { [weak self] closed in self?.documents.removeAll { $0 === closed } }
    if let window = doc.window {
      if inTab, let host = frontDocument?.window {
        host.addTabbedWindow(window, ordered: .above)   // takes on the tab group's size and place
      } else {
        window.center()
        // The first window remembers its size and place; further windows cascade from the last one.
        if !window.setFrameAutosaveName("PDF Studio Window"), let last = documents.last?.window {
          window.setFrame(last.frame.offsetBy(dx: 24, dy: -24), display: false)
        }
      }
    }
    documents.append(doc)
    doc.showWindow(nil)
    return doc
  }

  func showPrintPreview(_ document: PDFDocument, title: String) {
    let preview = PrintPreviewController(document: document, title: title)
    preview.onClose = { [weak self] closed in self?.previews.removeAll { $0 === closed } }
    previews.append(preview)
    preview.showWindow(nil)
    DispatchQueue.main.async { preview.printDocument(nil) }
  }

  // MARK: Menu actions

  @objc func newWindow(_ sender: Any?) { newDocumentWindow(inTab: false) }
  /// Also what the tab bar's + button sends.
  @objc func newWindowForTab(_ sender: Any?) { newDocumentWindow() }

  @objc func openDocument(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.pdf] + [markdownType].compactMap { $0 }
    panel.begin { [weak self] response in
      if response == .OK { panel.urls.forEach { self?.openFile($0) } }
    }
  }

  private func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      holder.submenu = menu
      main.addItem(holder)
      return menu
    }
    func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = mods
      return item
    }
    _ = submenu(appName, [
      item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      .separator(),
      item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
      item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
      item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
      .separator(),
      item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
    ])
    _ = submenu("File", [
      item("New Tab", #selector(newWindowForTab(_:)), "t"),
      item("New Window", #selector(newWindow(_:)), "n"),
      item("Open\u{2026}", #selector(openDocument(_:)), "o"),
      .separator(),
      item("Close", #selector(NSWindow.performClose(_:)), "w"),
      item("Save\u{2026}", #selector(DocumentWindowController.saveDocument(_:)), "s"),
      .separator(),
      item("Print\u{2026}", #selector(DocumentWindowController.printDocument(_:)), "p"),
    ])
    _ = submenu("Edit", [
      item("Undo", Selector(("undo:")), "z"),
      item("Redo", Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item("Cut", #selector(NSText.cut(_:)), "x"),
      item("Copy", #selector(NSText.copy(_:)), "c"),
      item("Paste", #selector(NSText.paste(_:)), "v"),
      item("Select All", #selector(NSText.selectAll(_:)), "a"),
    ])
    // AppKit fills these in itself: Enter Full Screen and the tab bar items under View,
    // and the tab commands (Show Next Tab, Merge All Windows, …) under Window.
    _ = submenu("View", [])
    let windowMenu = submenu("Window", [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
      item("Zoom", #selector(NSWindow.performZoom(_:))),
      .separator(),
      item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
    ])
    NSApp.windowsMenu = windowMenu
    return main
  }
}

// MARK: - Automated checks (debug builds only: macos/build.sh --debug)

#if DEBUG
//   PDFSTUDIO_TEST_DIR     answer dialogs automatically, save and print into this folder, and write
//                          w<N>-state.json + w<N>-snapshot.png for each window after it opens a file
//   PDFSTUDIO_TEST_JS      file holding an async JavaScript function body to run after a file opens
//   PDFSTUDIO_TEST_PROMPT  text to answer prompt() with (for example a PDF password)
//   PDFSTUDIO_TEST_PRESS   comma-separated alert button titles to press (default: the first button)
//   PDFSTUDIO_TEST_ZOOM    maximize the window before the checks run
//   PDFSTUDIO_TEST_THEN    "close" or "quit" once the checks have run
@MainActor
enum TestHooks {
  static let env = ProcessInfo.processInfo.environment
  static let dir = env["PDFSTUDIO_TEST_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

  static func log(_ line: String) {
    guard let dir else { return }
    let url = dir.appendingPathComponent("log.txt")
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url)
    }
  }

  static func answer(_ alert: NSAlert) -> NSApplication.ModalResponse? {
    guard dir != nil else { return nil }
    let titles = alert.buttons.map(\.title)
    let press = (env["PDFSTUDIO_TEST_PRESS"] ?? "").split(separator: ",").map(String.init)
    let index = titles.firstIndex(where: press.contains) ?? 0
    log("alert: \(alert.messageText) [\(titles.joined(separator: " | "))] -> \(titles.isEmpty ? "-" : titles[index])")
    return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
  }
}
#endif

@main
enum Main {
  @MainActor static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate   // a weak reference, so keep the delegate alive while the app runs
    withExtendedLifetime(delegate) { app.run() }
  }
}
