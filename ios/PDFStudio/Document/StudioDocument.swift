import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// One open file: a PDF or a Markdown/plain-text document.
///
/// Saving follows the iOS document model: every edit is registered with the document's undo manager,
/// which marks it as changed, and the system saves it in place (autosave, and when the file is closed).
/// Files that are only read are never rewritten.
final class StudioDocument: ReferenceFileDocument {
  enum Kind { case pdf, markdown }

  // Markdown first: it's the type a brand-new document gets.
  static let readableContentTypes: [UTType] = [.markdownDocument, .pdf, .plainText]
  static let writableContentTypes: [UTType] = [.markdownDocument, .pdf, .plainText]

  let kind: Kind
  /// The PDF being edited (an empty document for Markdown files).
  let pdf: PDFDocument
  @Published var markdown: String
  @Published var isLocked: Bool
  /// The password that unlocked the PDF, so a saved copy can be re-opened while flattening.
  private(set) var password: String?

  init() {
    kind = .markdown
    pdf = PDFDocument()
    markdown = ""
    isLocked = false
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
    if configuration.contentType.conforms(to: .pdf) {
      guard let doc = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
      kind = .pdf
      pdf = doc
      markdown = ""
      isLocked = doc.isLocked
    } else {
      kind = .markdown
      pdf = PDFDocument()
      markdown = Self.decodeText(data)
      isLocked = false
    }
  }

  /// For tests and previews.
  init(pdf: PDFDocument) {
    kind = .pdf
    self.pdf = pdf
    markdown = ""
    isLocked = pdf.isLocked
  }

  func unlock(_ password: String) -> Bool {
    guard pdf.unlock(withPassword: password) else { return false }
    self.password = password
    isLocked = false
    return true
  }

  static func decodeText(_ data: Data) -> String {
    var bytes = data
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
    if let s = String(data: bytes, encoding: .utf8) { return s }
    if let s = String(data: bytes, encoding: .utf16) { return s }
    return String(decoding: bytes, as: UTF8.self)
  }

  func snapshot(contentType: UTType) throws -> Data {
    switch kind {
    case .markdown: return Data(markdown.utf8)
    case .pdf: return try PDFWriter.data(for: pdf, password: password)
    }
  }

  func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: snapshot)
  }
}
