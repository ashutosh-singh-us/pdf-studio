import SwiftUI
import WebKit

struct OutlineItem: Identifiable, Hashable {
  let id: String
  let level: Int
  let title: String
}

/// The formatted Markdown view: a local WKWebView running the bundled renderer (no network
/// access except https pictures the document itself links to).
@MainActor
final class MarkdownPreview: NSObject, ObservableObject {
  let webView: WKWebView
  @Published private(set) var outline: [OutlineItem] = []
  @Published private(set) var words = 0
  private var ready = false
  private var pending: String?
  private var lastRendered: String?
  private var renderWaiters: [CheckedContinuation<Void, Never>] = []

  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.dataDetectorTypes = []
    let controller = WKUserContentController()
    config.userContentController = controller
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    controller.add(WeakHandler(self), name: "md")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.isFindInteractionEnabled = true
    webView.isOpaque = false
    webView.backgroundColor = .systemBackground
    webView.allowsLinkPreview = false
    if let url = Bundle.main.url(forResource: "markdown", withExtension: "html") {
      webView.loadFileURL(url, allowingReadAccessTo: url)
    }
  }

  func render(_ text: String) {
    guard text != lastRendered else { return }
    guard ready else { pending = text; return }
    lastRendered = text
    let json = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    webView.evaluateJavaScript("window.pdfstudio.render(\(json), true)", completionHandler: nil)
  }

  /// Renders and waits until the page has laid out the result (used before printing).
  func renderAndWait(_ text: String) async {
    if text == lastRendered && ready { return }
    await withCheckedContinuation { cont in
      renderWaiters.append(cont)
      lastRendered = nil
      render(text)
    }
  }

  func scroll(to id: String) {
    let json = (try? JSONEncoder().encode(id)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    webView.evaluateJavaScript("window.pdfstudio.scrollToHeading(\(json))", completionHandler: nil)
  }

  func setZoom(_ z: Double) {
    webView.evaluateJavaScript("window.pdfstudio && window.pdfstudio.setZoom(\(z))", completionHandler: nil)
  }

  fileprivate func received(_ body: Any) {
    guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
    switch type {
    case "ready":
      ready = true
      if let p = pending { pending = nil; render(p) }
    case "rendered":
      let items = (msg["outline"] as? [[String: Any]]) ?? []
      outline = items.compactMap { d in
        guard let id = d["id"] as? String, let level = d["level"] as? Int, let title = d["title"] as? String else { return nil }
        return OutlineItem(id: id, level: level, title: title)
      }
      words = msg["words"] as? Int ?? 0
      let waiters = renderWaiters
      renderWaiters = []
      waiters.forEach { $0.resume() }
    default:
      break
    }
  }

  /// A paginated PDF of the formatted document (Letter in the US and Canada, A4 elsewhere).
  func pdfData() -> Data {
    let renderer = PaperRenderer()
    renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
    let data = NSMutableData()
    UIGraphicsBeginPDFContextToData(data, renderer.paperRect, nil)
    renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
    for i in 0..<renderer.numberOfPages {
      UIGraphicsBeginPDFPage()
      renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
    }
    UIGraphicsEndPDFContext()
    return data as Data
  }

  private final class PaperRenderer: UIPrintPageRenderer {
    private let paper: CGRect = {
      let region = Locale.current.region?.identifier ?? ""
      return ["US", "CA", "MX", "PH"].contains(region)
        ? CGRect(x: 0, y: 0, width: 612, height: 792)
        : CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    }()
    override var paperRect: CGRect { paper }
    override var printableRect: CGRect { paper.insetBy(dx: 48, dy: 54) }
  }
}

extension MarkdownPreview: WKNavigationDelegate, WKUIDelegate {
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url
    if action.navigationType == .other, url?.isFileURL == true, action.targetFrame?.isMainFrame == true {
      decisionHandler(.allow)   // the bundled renderer page
      return
    }
    if let url, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
      UIApplication.shared.open(url)
    }
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    if let url = action.request.url, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
      UIApplication.shared.open(url)
    }
    return nil
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    ready = false
    let text = lastRendered
    lastRendered = nil
    pending = text
    if let url = Bundle.main.url(forResource: "markdown", withExtension: "html") {
      webView.loadFileURL(url, allowingReadAccessTo: url)
    }
  }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
  weak var owner: MarkdownPreview?
  init(_ owner: MarkdownPreview) { self.owner = owner }
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    let body = message.body
    MainActor.assumeIsolated { owner?.received(body) }
  }
}

struct MarkdownWebView: UIViewRepresentable {
  let preview: MarkdownPreview
  func makeUIView(context: Context) -> WKWebView { preview.webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}
