import PDFKit
import SwiftUI

@main
enum Launcher {
  static func main() {
    #if DEBUG
    // UI tests open one file directly: the document browser runs in a separate system process
    // that UI automation can't reliably drive.
    if ProcessInfo.processInfo.environment["PDFSTUDIO_OPEN_FILE"] != nil { HarnessApp.main(); return }
    #endif
    PDFStudioApp.main()
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    _ = ModelDownloader.shared
    _ = Narrator.shared
    _ = NarrationPlayer.shared
    return true
  }

  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                   completionHandler: @escaping () -> Void) {
    ModelDownloader.shared.backgroundCompletion = completionHandler
    ModelDownloader.shared.refresh()
  }
}

struct PDFStudioApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    documentScenes
  }

  @SceneBuilder private var documentScenes: some Scene {
    DocumentGroup(newDocument: { StudioDocument() }) { file in
      DocumentRoot(document: file.document, fileURL: file.fileURL)
    }

    DocumentGroupLaunchScene("PDF Studio") {
      NewDocumentButton("New Markdown File")
    } background: {
      LinearGradient(colors: [Color(red: 0.84, green: 0.25, blue: 0.17), Color(red: 0.55, green: 0.12, blue: 0.10)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
    }
  }
}

struct DocumentRoot: View {
  @ObservedObject var document: StudioDocument
  let fileURL: URL?

  var body: some View {
    switch document.kind {
    case .pdf: PDFEditorView(document: document, fileURL: fileURL)
    case .markdown: MarkdownEditorView(document: document, fileURL: fileURL)
    }
  }
}

#if DEBUG
import UniformTypeIdentifiers

private struct HarnessApp: App {
  var body: some Scene {
    WindowGroup { DebugHarness(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PDFSTUDIO_OPEN_FILE"]!)) }
  }
}

private struct DebugHarness: View {
  let url: URL
  @State private var document: StudioDocument?
  var body: some View {
    NavigationStack {
      if let document { DocumentRoot(document: document, fileURL: url).navigationTitle(url.lastPathComponent) }
    }
    .onAppear {
      let type = UTType(filenameExtension: url.pathExtension) ?? .plainText
      guard let data = try? Data(contentsOf: url) else { return }
      if type.conforms(to: .pdf), let pdf = PDFDocument(data: data) { document = StudioDocument(pdf: pdf) }
      else { let d = StudioDocument(); d.markdown = StudioDocument.decodeText(data); document = d }
    }
  }
}
#endif
