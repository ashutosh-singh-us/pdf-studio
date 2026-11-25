import Combine
import PDFKit
import UIKit

enum PDFTool: String, CaseIterable, Identifiable {
  case read, select, text, draw, highlight, rectangle, whiteout
  var id: String { rawValue }

  var title: String {
    switch self {
    case .read: "Read"
    case .select: "Select"
    case .text: "Text"
    case .draw: "Draw"
    case .highlight: "Highlight"
    case .rectangle: "Box"
    case .whiteout: "White-out"
    }
  }

  var symbol: String {
    switch self {
    case .read: "hand.point.up.left"
    case .select: "cursorarrow.rays"
    case .text: "textformat"
    case .draw: "scribble.variable"
    case .highlight: "highlighter"
    case .rectangle: "rectangle"
    case .whiteout: "eraser"
    }
  }

  /// Tools that draw with one finger; the page then scrolls with two fingers.
  var drawsWithOneFinger: Bool { self == .draw || self == .highlight || self == .rectangle || self == .whiteout }
  var usesColor: Bool { self == .text || self == .draw || self == .rectangle || self == .highlight }
}

/// A request for the SwiftUI layer to show the text editor sheet.
struct TextEditRequest: Identifiable {
  let id = UUID()
  var text: String
  var fontSize: CGFloat
  var color: UIColor
  /// nil: create new text at `point` on `page`.
  var annotation: PDFAnnotation?
  var page: PDFPage
  var point: CGPoint
}

/// Owns the PDFView and every edit made to the document. All edits register undo actions,
/// which is also how the document knows it has changes to save.
@MainActor
final class PDFEditor: NSObject, ObservableObject {
  let document: StudioDocument
  let pdfView = PDFView()
  let container = UIView()
  private let overlay = EditorOverlayView()
  private var scrollView: UIScrollView?

  @Published var tool: PDFTool = .read { didSet { toolChanged(from: oldValue) } }
  @Published var color: UIColor = .systemRed
  @Published var highlightColor: UIColor = UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)
  @Published var lineWidth: CGFloat = 3
  @Published var fontSize: CGFloat = 16
  @Published private(set) var selected: PDFAnnotation?
  @Published var textRequest: TextEditRequest?
  @Published private(set) var pageLabel = ""
  @Published private(set) var revision = 0   // bumps when pages change (for thumbnails)
  @Published var message: String?

  var undoManager: UndoManager?

  private let pan = UIPanGestureRecognizer()
  private let tap = UITapGestureRecognizer()
  private var stroke: Stroke?
  private var drag: Drag?
  private var observers: [NSObjectProtocol] = []
  private var offsetObservation: NSKeyValueObservation?

  private struct Stroke {
    let page: PDFPage
    var points: [CGPoint]   // page space
    let start: CGPoint
  }

  private struct Drag {
    let annotation: PDFAnnotation
    let page: PDFPage
    let startBounds: CGRect
    let startPoint: CGPoint  // page space
    let resizing: Bool
  }

  init(document: StudioDocument) {
    self.document = document
    super.init()
    configureView()
  }

  // MARK: - Setup

  private func configureView() {
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.pageShadowsEnabled = true
    pdfView.backgroundColor = .secondarySystemBackground
    pdfView.isFindInteractionEnabled = true
    pdfView.delegate = self
    pdfView.document = document.pdf
    pdfView.translatesAutoresizingMaskIntoConstraints = false

    overlay.isUserInteractionEnabled = false
    overlay.backgroundColor = .clear
    overlay.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(pdfView)
    container.addSubview(overlay)
    NSLayoutConstraint.activate([
      pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      pdfView.topAnchor.constraint(equalTo: container.topAnchor),
      pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: container.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    pan.addTarget(self, action: #selector(handlePan(_:)))
    tap.delegate = self
    tap.addTarget(self, action: #selector(handleTap(_:)))
    pdfView.addGestureRecognizer(pan)
    pdfView.addGestureRecognizer(tap)

    let nc = NotificationCenter.default
    observers.append(nc.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updatePageLabel(); self?.scheduleSavePosition() }
    })
    observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshOverlay() }
    })
    observers.append(nc.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] note in
      let hit = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
      MainActor.assumeIsolated { if let hit { self?.formFieldTouched(hit) } }
    })
    observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.savePosition() }
    })
    updatePageLabel()
  }

  /// Called once the view is in a window, when PDFView has built its scroll view.
  func viewDidAppear() {
    if scrollView == nil, let sv = Self.findScrollView(in: pdfView) {
      scrollView = sv
      offsetObservation = sv.observe(\.contentOffset, options: []) { [weak self] _, _ in
        Task { @MainActor in
          self?.refreshOverlay()
          self?.scheduleSavePosition()
        }
      }
      applyScrollPolicy()
    }
    restorePosition()
  }

  // MARK: - Reading position

  /// Identifies this book for remembering the reading position (nil: don't remember).
  var positionKey: String?
  private var restored = false
  private var saveWork: DispatchWorkItem?

  private func restorePosition() {
    guard !restored else { return }
    restored = true
    guard let key = positionKey, let mark = ReadingPosition.load(key), mark.page > 0 || mark.y > 0,
          let page = doc.page(at: min(mark.page, doc.pageCount - 1)) else { return }
    // Let PDFView finish its first layout, then jump.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self else { return }
      self.pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: mark.x, y: mark.y)))
      self.updatePageLabel()
    }
  }

  private func scheduleSavePosition() {
    guard restored, positionKey != nil else { return }
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.savePosition() }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }

  /// Saves the top-left of what's on screen.
  func savePosition() {
    guard restored, let key = positionKey, let page = pdfView.page(for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.minY + 1), nearest: true) else { return }
    let index = doc.index(for: page)
    guard index != NSNotFound else { return }
    let top = pdfView.convert(CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY + pdfView.safeAreaInsets.top), to: page)
    let box = page.bounds(for: .cropBox)
    let y = min(max(top.y, box.minY), box.maxY)
    ReadingPosition.save(.init(page: index, x: box.minX, y: y, date: Date()), key: key)
  }

  private static func findScrollView(in view: UIView) -> UIScrollView? {
    for sub in view.subviews {
      if let sv = sub as? UIScrollView { return sv }
      if let sv = findScrollView(in: sub) { return sv }
    }
    return nil
  }

  private func applyScrollPolicy() {
    scrollView?.panGestureRecognizer.minimumNumberOfTouches = tool.drawsWithOneFinger ? 2 : 1
  }

  private func toolChanged(from old: PDFTool) {
    if tool != .select { select(nil) }
    applyScrollPolicy()
    stroke = nil
    overlay.preview = nil
    overlay.setNeedsDisplay()
    if tool != .read { pdfView.clearSelection() }
  }

  func updatePageLabel() {
    guard let page = pdfView.currentPage, let doc = pdfView.document, doc.pageCount > 0 else { pageLabel = ""; return }
    pageLabel = "\(doc.index(for: page) + 1) of \(doc.pageCount)"
  }

  // MARK: - Geometry

  private func pagePoint(_ viewPoint: CGPoint) -> (PDFPage, CGPoint)? {
    guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
    return (page, pdfView.convert(viewPoint, to: page))
  }

  private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
    pdfView.convert(rect, from: page)
  }

  private var scale: CGFloat { max(pdfView.scaleFactor, 0.01) }

  // MARK: - Gestures

  @objc private func handleTap(_ g: UITapGestureRecognizer) {
    let loc = g.location(in: pdfView)
    guard let (page, pt) = pagePoint(loc) else { return }
    switch tool {
    case .text:
      if let existing = editableAnnotation(at: pt, on: page), existing.type == PDFAnnotationSubtype.freeText.rawValue {
        requestEdit(existing)
      } else {
        textRequest = TextEditRequest(text: "", fontSize: fontSize, color: color, annotation: nil, page: page, point: pt)
      }
    case .select:
      select(editableAnnotation(at: pt, on: page))
    default:
      break
    }
  }

  @objc private func handlePan(_ g: UIPanGestureRecognizer) {
    let loc = g.location(in: pdfView)
    switch tool {
    case .select: handleDrag(g, at: loc)
    case .draw, .highlight, .rectangle, .whiteout: handleStroke(g, at: loc)
    default: break
    }
  }

  private func handleStroke(_ g: UIPanGestureRecognizer, at loc: CGPoint) {
    switch g.state {
    case .began:
      guard let (page, pt) = pagePoint(loc) else { return }
      stroke = Stroke(page: page, points: [pt], start: pt)
    case .changed:
      guard var s = stroke else { return }
      let pt = pdfView.convert(loc, to: s.page)
      s.points.append(pt)
      stroke = s
      updateStrokePreview(s)
    case .ended:
      if var s = stroke {
        s.points.append(pdfView.convert(loc, to: s.page))
        commitStroke(s)
      }
      stroke = nil
      overlay.preview = nil
      overlay.setNeedsDisplay()
    default:
      stroke = nil
      overlay.preview = nil
      overlay.setNeedsDisplay()
    }
  }

  private func updateStrokePreview(_ s: Stroke) {
    switch tool {
    case .draw:
      let path = UIBezierPath()
      for (i, p) in s.points.enumerated() {
        let v = pdfView.convert(p, from: s.page)
        if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
      }
      overlay.preview = .stroke(path, color, lineWidth * scale)
    case .highlight:
      if let lines = textLines(from: s.start, to: s.points.last ?? s.start, on: s.page), !lines.isEmpty {
        overlay.preview = .fills(lines.map { viewRect($0, on: s.page) }, highlightColor.withAlphaComponent(0.4))
      } else {
        overlay.preview = .fills([viewRect(rect(s.start, s.points.last ?? s.start), on: s.page)], highlightColor.withAlphaComponent(0.4))
      }
    case .rectangle:
      overlay.preview = .box(viewRect(rect(s.start, s.points.last ?? s.start), on: s.page), color, lineWidth * scale)
    case .whiteout:
      overlay.preview = .fills([viewRect(rect(s.start, s.points.last ?? s.start), on: s.page)], .white)
    default:
      overlay.preview = nil
    }
    overlay.setNeedsDisplay()
  }

  private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
  }

  /// Line rectangles of the text between two points, or nil if there's no text there.
  private func textLines(from a: CGPoint, to b: CGPoint, on page: PDFPage) -> [CGRect]? {
    guard let sel = page.selection(from: a, to: b), let str = sel.string,
          !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return sel.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0.5 && $0.height > 0.5 }
  }

  private func commitStroke(_ s: Stroke) {
    let end = s.points.last ?? s.start
    switch tool {
    case .draw:
      guard s.points.count > 1 else { return }
      add(InkBuilder.annotation(points: s.points, color: color, width: lineWidth), to: s.page, name: "Drawing")
    case .highlight:
      if let lines = textLines(from: s.start, to: end, on: s.page), !lines.isEmpty {
        let anns = lines.map { line -> PDFAnnotation in
          let a = PDFAnnotation(bounds: line, forType: .highlight, withProperties: nil)
          a.color = highlightColor.withAlphaComponent(0.5)
          return a
        }
        add(anns, to: s.page, name: "Highlight")
      } else {
        let r = rect(s.start, end)
        guard r.width > 3, r.height > 3 else { return }
        let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        a.color = .clear
        a.interiorColor = highlightColor.withAlphaComponent(0.35)
        a.border = Self.border(0)
        add(a, to: s.page, name: "Highlight")
      }
    case .rectangle:
      let r = rect(s.start, end)
      guard r.width > 3, r.height > 3 else { return }
      let a = PDFAnnotation(bounds: r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2), forType: .square, withProperties: nil)
      a.color = color
      a.border = Self.border(lineWidth)
      add(a, to: s.page, name: "Box")
    case .whiteout:
      let r = rect(s.start, end)
      guard r.width > 3, r.height > 3 else { return }
      let a = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
      a.color = .white
      a.interiorColor = .white
      a.border = Self.border(0)
      a.userName = "PDF Studio white-out"
      add(a, to: s.page, name: "White-out")
    default:
      break
    }
  }

  nonisolated static func border(_ width: CGFloat) -> PDFBorder {
    let b = PDFBorder()
    b.lineWidth = width
    b.style = .solid
    return b
  }

  // MARK: - Selection, move and resize

  private func isEditable(_ a: PDFAnnotation) -> Bool {
    let blocked: Set<String> = [PDFAnnotationSubtype.widget.rawValue, PDFAnnotationSubtype.link.rawValue, PDFAnnotationSubtype.popup.rawValue]
    return !blocked.contains(a.type ?? "")
  }

  private func editableAnnotation(at pt: CGPoint, on page: PDFPage) -> PDFAnnotation? {
    let slop = 8 / scale
    return page.annotations.reversed().first { isEditable($0) && $0.bounds.insetBy(dx: -slop, dy: -slop).contains(pt) }
  }

  func select(_ annotation: PDFAnnotation?) {
    selected = annotation
    refreshOverlay()
  }

  private func refreshOverlay() {
    if let a = selected, let page = a.page {
      overlay.selection = viewRect(a.bounds, on: page)
      overlay.showsHandle = canResize(a)
    } else {
      overlay.selection = nil
    }
    overlay.setNeedsDisplay()
  }

  private func canResize(_ a: PDFAnnotation) -> Bool {
    a.type != PDFAnnotationSubtype.ink.rawValue && a.type != PDFAnnotationSubtype.highlight.rawValue
  }

  private func handleDrag(_ g: UIPanGestureRecognizer, at loc: CGPoint) {
    switch g.state {
    case .began:
      guard let a = selected, let page = a.page else { return }
      let vr = viewRect(a.bounds, on: page)
      let handle = CGRect(x: vr.maxX - 22, y: vr.maxY - 22, width: 44, height: 44)
      drag = Drag(annotation: a, page: page, startBounds: a.bounds, startPoint: pdfView.convert(loc, to: page),
                  resizing: canResize(a) && handle.contains(loc))
    case .changed:
      guard let d = drag else { return }
      let pt = pdfView.convert(loc, to: d.page)
      let dx = pt.x - d.startPoint.x, dy = pt.y - d.startPoint.y
      var b = d.startBounds
      if d.resizing {
        // The handle is at the bottom-right in view space, which is (maxX, minY) in page space.
        var w = max(12, b.width + dx)
        var h = max(12, b.height - dy)
        if d.annotation is ImageStampAnnotation {
          let ratio = d.startBounds.width / max(d.startBounds.height, 1)
          if abs(dx) > abs(dy) { h = w / ratio } else { w = h * ratio }
        }
        b = CGRect(x: b.minX, y: b.maxY - h, width: w, height: h)
      } else {
        b = b.offsetBy(dx: dx, dy: dy)
      }
      d.annotation.bounds = b
      refreshOverlay()
    case .ended, .cancelled, .failed:
      guard let d = drag else { return }
      drag = nil
      let final = d.annotation.bounds
      d.annotation.bounds = d.startBounds
      if final != d.startBounds { setBounds(final, of: d.annotation, name: d.resizing ? "Resize" : "Move") }
      refreshOverlay()
    default:
      break
    }
  }

  // MARK: - Edits (all undoable)

  func add(_ annotation: PDFAnnotation, to page: PDFPage, name: String) {
    add([annotation], to: page, name: name)
  }

  func add(_ annotations: [PDFAnnotation], to page: PDFPage, name: String) {
    annotations.forEach { page.addAnnotation($0) }
    pdfView.annotationsChanged(on: page)
    undoManager?.registerUndo(withTarget: self) { $0.remove(annotations, from: page, name: name) }
    undoManager?.setActionName(name)
  }

  func remove(_ annotations: [PDFAnnotation], from page: PDFPage, name: String) {
    annotations.forEach { page.removeAnnotation($0) }
    pdfView.annotationsChanged(on: page)
    if let s = selected, annotations.contains(s) { select(nil) }
    undoManager?.registerUndo(withTarget: self) { $0.add(annotations, to: page, name: name) }
    undoManager?.setActionName(name)
  }

  func deleteSelected() {
    guard let a = selected, let page = a.page else { return }
    remove([a], from: page, name: "Delete")
  }

  func setBounds(_ bounds: CGRect, of a: PDFAnnotation, name: String) {
    let old = a.bounds
    a.bounds = bounds
    // PDFKit doesn't always redraw moved annotations; re-adding forces it.
    if let page = a.page { page.removeAnnotation(a); page.addAnnotation(a); pdfView.annotationsChanged(on: page) }
    undoManager?.registerUndo(withTarget: self) { $0.setBounds(old, of: a, name: name) }
    undoManager?.setActionName(name)
    refreshOverlay()
  }

  func setColor(_ c: UIColor, of a: PDFAnnotation) {
    let oldColor = a.color, oldFont = a.fontColor
    if a.type == PDFAnnotationSubtype.freeText.rawValue { a.fontColor = c } else { a.color = c }
    undoManager?.registerUndo(withTarget: self) { me in
      a.color = oldColor
      a.fontColor = oldFont
      me.undoManager?.registerUndo(withTarget: me) { $0.setColor(c, of: a) }
    }
    undoManager?.setActionName("Color")
  }

  // MARK: - Text

  func requestEdit(_ a: PDFAnnotation) {
    guard let page = a.page, a.type == PDFAnnotationSubtype.freeText.rawValue else { return }
    textRequest = TextEditRequest(text: a.contents ?? "", fontSize: a.font?.pointSize ?? fontSize,
                                  color: a.fontColor ?? color, annotation: a, page: page, point: a.bounds.origin)
  }

  func commitText(_ req: TextEditRequest) {
    let text = req.text.trimmingCharacters(in: .newlines)
    fontSize = req.fontSize
    color = req.color
    if let existing = req.annotation {
      if text.isEmpty { remove([existing], from: req.page, name: "Delete Text"); return }
      replaceText(existing, text: text, size: req.fontSize, color: req.color)
      return
    }
    guard !text.isEmpty else { return }
    // Create it at its final size: PDFView doesn't redraw a text box that was created empty and then resized.
    let frame = TextStyle.frame(text: text, size: req.fontSize, topLeft: req.point, page: req.page)
    let a = PDFAnnotation(bounds: frame, forType: .freeText, withProperties: nil)
    TextStyle.apply(text: text, size: req.fontSize, color: req.color, to: a, topLeft: req.point, page: req.page)
    add(a, to: req.page, name: "Text")
  }

  private func replaceText(_ a: PDFAnnotation, text: String, size: CGFloat, color: UIColor) {
    let old = (a.contents ?? "", a.font?.pointSize ?? size, a.fontColor ?? color)
    guard let page = a.page else { return }
    TextStyle.apply(text: text, size: size, color: color, to: a, topLeft: CGPoint(x: a.bounds.minX, y: a.bounds.maxY), page: page)
    page.removeAnnotation(a); page.addAnnotation(a)
    pdfView.annotationsChanged(on: page)
    undoManager?.registerUndo(withTarget: self) { $0.replaceText(a, text: old.0, size: old.1, color: old.2) }
    undoManager?.setActionName("Edit Text")
    refreshOverlay()
  }

  // MARK: - Pictures and signatures

  /// Places an image in the middle of the visible part of the current page and selects it.
  func insertImage(_ image: UIImage, widthFraction: CGFloat = 0.4, name: String = "Picture") {
    guard let page = pdfView.currentPage else { return }
    let img = ImageStampAnnotation.prepared(image)
    let box = page.bounds(for: .cropBox)
    let visible = pdfView.convert(pdfView.bounds, to: page).intersection(box)
    let area = visible.isNull || visible.isEmpty ? box : visible
    let ratio = img.size.height / max(img.size.width, 1)
    var w = box.width * widthFraction
    var h = w * ratio
    if h > area.height * 0.8 { h = area.height * 0.8; w = h / ratio }
    let rect = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    let a = ImageStampAnnotation(image: img, bounds: rect)
    add(a, to: page, name: name)
    tool = .select
    select(a)
  }

  // MARK: - Forms

  /// Filling a form field isn't an undo action PDFKit reports, so register one when a field is touched:
  /// it marks the document as changed and lets Undo restore the field's previous value.
  private func formFieldTouched(_ a: PDFAnnotation) {
    guard a.type == PDFAnnotationSubtype.widget.rawValue, a.widgetFieldType != .signature else { return }
    let oldString = a.widgetStringValue
    let oldState = a.buttonWidgetState
    undoManager?.registerUndo(withTarget: self) { me in
      let curString = a.widgetStringValue, curState = a.buttonWidgetState
      a.widgetStringValue = oldString
      a.buttonWidgetState = oldState
      me.undoManager?.registerUndo(withTarget: me) { _ in
        a.widgetStringValue = curString
        a.buttonWidgetState = curState
      }
    }
    undoManager?.setActionName("Fill Form")
  }

  // MARK: - Pages

  var doc: PDFDocument { document.pdf }

  private func pagesChanged() {
    revision += 1
    pdfView.layoutDocumentView()
    updatePageLabel()
  }

  func rotate(_ indexes: [Int], by degrees: Int) {
    let pages = indexes.compactMap { doc.page(at: $0) }
    pages.forEach { $0.rotation = (($0.rotation + degrees) % 360 + 360) % 360 }
    undoManager?.registerUndo(withTarget: self) { me in me.rotate(pages.map { me.doc.index(for: $0) }, by: -degrees) }
    undoManager?.setActionName("Rotate")
    pagesChanged()
  }

  func deletePages(_ indexes: [Int]) {
    let sorted = Array(Set(indexes)).sorted()
    guard !sorted.isEmpty, sorted.count < doc.pageCount else {
      message = "A PDF needs at least one page."
      return
    }
    let removed = sorted.compactMap { i in doc.page(at: i).map { (i, $0) } }
    for (i, _) in removed.reversed() { doc.removePage(at: i) }
    undoManager?.registerUndo(withTarget: self) { me in me.insert(removed, name: "Delete Pages") }
    undoManager?.setActionName("Delete Pages")
    pagesChanged()
  }

  /// Inserts pages at their indexes (ascending order).
  func insert(_ pages: [(Int, PDFPage)], name: String) {
    for (i, p) in pages { doc.insert(p, at: min(i, doc.pageCount)) }
    undoManager?.registerUndo(withTarget: self) { me in
      let idx = pages.map { me.doc.index(for: $0.1) }.filter { $0 != NSNotFound }
      let removed = idx.sorted().compactMap { i in me.doc.page(at: i).map { (i, $0) } }
      for (i, _) in removed.reversed() { me.doc.removePage(at: i) }
      me.undoManager?.registerUndo(withTarget: me) { $0.insert(removed, name: name) }
      me.pagesChanged()
    }
    undoManager?.setActionName(name)
    pagesChanged()
  }

  func insertBlankPage(after index: Int) {
    let size = doc.page(at: max(0, min(index, doc.pageCount - 1)))?.bounds(for: .cropBox).size ?? CGSize(width: 612, height: 792)
    guard let page = Self.blankPage(size: size) else { return }
    insert([(index + 1, page)], name: "Insert Page")
  }

  static func blankPage(size: CGSize) -> PDFPage? {
    let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { ctx in ctx.beginPage() }
    guard let d = PDFDocument(data: data) else { return nil }
    return d.page(at: 0)
  }

  /// Moves the page at `from` so it ends up at index `to`.
  func movePage(from: Int, to: Int) {
    guard from != to, let page = doc.page(at: from), (0..<doc.pageCount).contains(to) else { return }
    doc.removePage(at: from)
    doc.insert(page, at: to)
    undoManager?.registerUndo(withTarget: self) { $0.movePage(from: to, to: from) }
    undoManager?.setActionName("Move Page")
    pagesChanged()
  }

  /// Appends the pages of other PDFs.
  func merge(_ others: [PDFDocument]) {
    var start = doc.pageCount
    var added: [(Int, PDFPage)] = []
    for other in others where !other.isLocked {
      for i in 0..<other.pageCount {
        guard let p = other.page(at: i) else { continue }
        added.append((start, p))
        start += 1
      }
    }
    guard !added.isEmpty else { message = "No pages could be added (is the PDF password-protected?)."; return }
    insert(added, name: "Merge")
    message = "Added \(added.count) page\(added.count == 1 ? "" : "s")."
  }

  /// A new PDF containing the given pages, with all edits applied.
  func extract(_ indexes: [Int]) throws -> Data {
    let full = try PDFWriter.data(for: doc, password: document.password)
    guard let src = PDFDocument(data: full) else { throw PDFWriterError.couldNotWrite }
    if src.isLocked, let pw = document.password { src.unlock(withPassword: pw) }
    let out = PDFDocument()
    for (n, i) in indexes.sorted().enumerated() {
      if let p = src.page(at: i) { out.insert(p, at: n) }
    }
    guard let data = out.dataRepresentation() else { throw PDFWriterError.couldNotWrite }
    return data
  }

  func exportData() throws -> Data { try PDFWriter.data(for: doc, password: document.password) }

  func go(toPage index: Int) {
    if let p = doc.page(at: index) { pdfView.go(to: p) }
  }
}

// MARK: - Gesture delegate

extension PDFEditor: UIGestureRecognizerDelegate {
  nonisolated func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    MainActor.assumeIsolated {
      if g === tap { return tool == .text || tool == .select }
      if g === pan {
        switch tool {
        case .draw, .highlight, .rectangle, .whiteout: return true
        case .select:
          guard let a = selected, let page = a.page else { return false }
          return viewRect(a.bounds, on: page).insetBy(dx: -24, dy: -24).contains(g.location(in: pdfView))
        default: return false
        }
      }
      return true
    }
  }

  // The page scroll waits for our pan to fail, so dragging a selected item doesn't scroll.
  nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
    MainActor.assumeIsolated { g === pan && other === scrollView?.panGestureRecognizer }
  }

  nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
    MainActor.assumeIsolated { g === tap && tool == .select }
  }
}

extension PDFEditor: PDFViewDelegate {
  nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
    MainActor.assumeIsolated {
      guard tool == .read, ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") else { return }
      UIApplication.shared.open(url)
    }
  }
}

// MARK: - Helpers

enum InkBuilder {
  /// An ink annotation through page-space points. PDFKit expects ink paths relative to the
  /// annotation's bounds origin.
  static func annotation(points: [CGPoint], color: UIColor, width: CGFloat) -> PDFAnnotation {
    var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
    for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
    let pad = width * 2
    let bounds = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
    let path = UIBezierPath()
    let local = points.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
    path.move(to: local[0])
    if local.count == 2 { path.addLine(to: local[1]) }
    // Smooth through the midpoints of successive points.
    for i in 1..<max(1, local.count - 1) where local.count > 2 {
      let mid = CGPoint(x: (local[i].x + local[i + 1].x) / 2, y: (local[i].y + local[i + 1].y) / 2)
      path.addQuadCurve(to: mid, controlPoint: local[i])
    }
    if local.count > 2 { path.addLine(to: local[local.count - 1]) }
    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
    a.add(path)
    a.color = color
    a.border = PDFEditor.border(width)
    return a
  }
}

enum TextStyle {
  static func font(_ size: CGFloat) -> UIFont { UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size) }

  /// Sets text and style, sizing the box to the text with its top-left at `topLeft` (page space).
  /// The box for `text`, hanging down from `topLeft` (page space).
  static func frame(text: String, size: CGFloat, topLeft: CGPoint, page: PDFPage) -> CGRect {
    let box = page.bounds(for: .cropBox)
    let maxW = max(60, box.maxX - topLeft.x - 8)
    let measured = (text as NSString).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: [.font: font(size)], context: nil)
    let w = ceil(measured.width) + 10, h = ceil(measured.height) + 6
    return CGRect(x: topLeft.x, y: topLeft.y - h, width: w, height: h)
  }

  static func apply(text: String, size: CGFloat, color: UIColor, to a: PDFAnnotation, topLeft: CGPoint, page: PDFPage) {
    a.bounds = frame(text: text, size: size, topLeft: topLeft, page: page)
    a.contents = text
    a.font = font(size)
    a.fontColor = color
    a.color = .clear
    a.alignment = .left
    a.border = PDFEditor.border(0)
  }
}

/// Draws the live preview of the current stroke and the selection outline.
final class EditorOverlayView: UIView {
  enum Preview {
    case stroke(UIBezierPath, UIColor, CGFloat)
    case fills([CGRect], UIColor)
    case box(CGRect, UIColor, CGFloat)
  }
  var preview: Preview?
  var selection: CGRect?
  var showsHandle = true

  override func draw(_ rect: CGRect) {
    switch preview {
    case let .stroke(path, color, width):
      color.setStroke()
      path.lineWidth = width
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.stroke()
    case let .fills(rects, color):
      color.setFill()
      rects.forEach { UIBezierPath(rect: $0).fill() }
      if color == .white { UIColor.systemGray3.setStroke(); rects.forEach { UIBezierPath(rect: $0).stroke() } }
    case let .box(r, color, width):
      color.setStroke()
      let p = UIBezierPath(rect: r)
      p.lineWidth = width
      p.stroke()
    case nil:
      break
    }
    if let sel = selection {
      let r = sel.insetBy(dx: -4, dy: -4)
      let p = UIBezierPath(roundedRect: r, cornerRadius: 3)
      p.lineWidth = 1.5
      p.setLineDash([5, 3], count: 2, phase: 0)
      tintColor.setStroke()
      p.stroke()
      if showsHandle {
        let h = UIBezierPath(ovalIn: CGRect(x: r.maxX - 9, y: r.maxY - 9, width: 18, height: 18))
        UIColor.systemBackground.setFill()
        h.fill()
        tintColor.setStroke()
        h.lineWidth = 2
        h.stroke()
      }
    }
  }
}
