import PDFKit
import UIKit

enum PDFWriterError: LocalizedError {
  case couldNotWrite
  var errorDescription: String? { "The PDF could not be saved." }
}

/// Turns the live PDFDocument into file data.
///
/// PDFKit saves standard annotations (ink, highlight, text, shapes, filled form fields) as real PDF
/// annotations that stay editable in other apps. Pictures and signatures are custom-drawn
/// annotations PDFKit can't serialise, so on save they're drawn into the page itself (vector content
/// and text on that page are kept as-is; other annotations on the page stay annotations).
enum PDFWriter {
  static func data(for doc: PDFDocument, password: String? = nil) throws -> Data {
    var stamped: [(index: Int, stamps: [ImageStampAnnotation])] = []
    for i in 0..<doc.pageCount {
      guard let page = doc.page(at: i) else { continue }
      let stamps = page.annotations.compactMap { $0 as? ImageStampAnnotation }
      if !stamps.isEmpty { stamped.append((i, stamps)) }
    }
    if stamped.isEmpty {
      guard let data = doc.dataRepresentation() else { throw PDFWriterError.couldNotWrite }
      return data
    }

    // Write the document without the pictures, then draw them into a re-opened copy.
    for (i, stamps) in stamped { stamps.forEach { doc.page(at: i)?.removeAnnotation($0) } }
    let base = doc.dataRepresentation()
    for (i, stamps) in stamped { stamps.forEach { doc.page(at: i)?.addAnnotation($0) } }

    guard let base, let copy = PDFDocument(data: base) else { throw PDFWriterError.couldNotWrite }
    if copy.isLocked, let password { copy.unlock(withPassword: password) }
    var keepAlive: [PDFDocument] = []
    for (i, stamps) in stamped {
      guard let page = copy.page(at: i), let (flat, owner) = flattened(page, stamps: stamps) else {
        throw PDFWriterError.couldNotWrite
      }
      keepAlive.append(owner)
      copy.removePage(at: i)
      copy.insert(flat, at: i)
    }
    guard let out = copy.dataRepresentation() else { throw PDFWriterError.couldNotWrite }
    withExtendedLifetime(keepAlive) {}
    return out
  }

  /// A new page with `page`'s content plus the pictures drawn in, carrying over `page`'s annotations.
  private static func flattened(_ page: PDFPage, stamps: [ImageStampAnnotation]) -> (PDFPage, PDFDocument)? {
    guard let ref = page.pageRef else { return nil }
    var media = page.bounds(for: .mediaBox)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
    ctx.beginPDFPage(nil)
    ctx.drawPDFPage(ref)            // content stream only: no rotation, no annotation appearances
    for stamp in stamps { stamp.drawImage(in: ctx) }
    ctx.endPDFPage()
    ctx.closePDF()

    guard let doc = PDFDocument(data: data as Data), let flat = doc.page(at: 0) else { return nil }
    flat.setBounds(page.bounds(for: .cropBox), for: .cropBox)
    flat.rotation = page.rotation
    for annotation in page.annotations {
      page.removeAnnotation(annotation)
      flat.addAnnotation(annotation)
    }
    return (flat, doc)
  }
}

/// A picture or signature placed on a page. Drawn live by PDFKit; flattened into the page on save.
final class ImageStampAnnotation: PDFAnnotation {
  let image: UIImage

  init(image: UIImage, bounds: CGRect) {
    self.image = image
    super.init(bounds: bounds, forType: .stamp, withProperties: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(with box: PDFDisplayBox, in context: CGContext) {
    drawImage(in: context)
  }

  /// Draws into a page-space (y-up) context.
  func drawImage(in ctx: CGContext) {
    guard let cg = image.cgImage else { return }
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: bounds)
    ctx.restoreGState()
  }

  /// Upright, at most `maxPixels` on the long side (keeps saved files reasonably small).
  static func prepared(_ image: UIImage, maxPixels: CGFloat = 2400) -> UIImage {
    let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let factor = min(1, maxPixels / max(px.width, px.height, 1))
    let size = CGSize(width: (px.width * factor).rounded(), height: (px.height * factor).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
