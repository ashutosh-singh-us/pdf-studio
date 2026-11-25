import PencilKit
import SwiftUI

/// Draw or type a signature, or reuse a saved one. Saved signatures stay on this device only.
struct SignatureSheet: View {
  let use: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss
  @StateObject private var store = SignatureStore()
  @State private var mode = 0
  @State private var canvas = PKCanvasView()
  @State private var typed = ""
  @State private var inkBlue = false
  @State private var remember = true

  private var ink: UIColor { inkBlue ? UIColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1) : .black }

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        Picker("Mode", selection: $mode) {
          Text("Draw").tag(0)
          Text("Type").tag(1)
          if !store.items.isEmpty { Text("Saved").tag(2) }
        }
        .pickerStyle(.segmented)

        switch mode {
        case 0:
          SignaturePad(canvas: canvas, ink: ink)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .overlay(alignment: .bottom) {
              Rectangle().fill(.gray.opacity(0.4)).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 50)
                .allowsHitTesting(false)
            }
          HStack {
            Toggle("Blue ink", isOn: $inkBlue).fixedSize()
            Spacer()
            Button("Clear") { canvas.drawing = PKDrawing() }
          }
        case 1:
          TextField("Your name", text: $typed)
            .textFieldStyle(.roundedBorder)
            .textContentType(.name)
          Text(typed.isEmpty ? "Signature" : typed)
            .font(.custom("SnellRoundhand-Bold", size: 44))
            .foregroundStyle(Color(uiColor: ink).opacity(typed.isEmpty ? 0.3 : 1))
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .light)
          Toggle("Blue ink", isOn: $inkBlue)
        default:
          List {
            ForEach(store.items) { item in
              Button { finish(item.image, save: false) } label: {
                Image(uiImage: item.image).resizable().scaledToFit().frame(height: 60)
                  .frame(maxWidth: .infinity).padding(8)
                  .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
              }
            }
            .onDelete { store.delete(at: $0) }
          }
          .listStyle(.plain)
        }
        if mode != 2 { Toggle("Save for next time", isOn: $remember) }
        Spacer(minLength: 0)
      }
      .padding()
      .navigationTitle("Signature")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        if mode != 2 {
          ToolbarItem(placement: .confirmationAction) { Button("Add") { add() } }
        }
      }
    }
  }

  private func add() {
    let image: UIImage?
    if mode == 0 {
      image = SignatureRenderer.image(from: canvas.drawing)
    } else {
      image = SignatureRenderer.image(text: typed, color: ink)
    }
    guard let image else { return }
    finish(image, save: remember)
  }

  private func finish(_ image: UIImage, save: Bool) {
    if save { store.add(image) }
    use(image)
    dismiss()
  }
}

struct SignaturePad: UIViewRepresentable {
  let canvas: PKCanvasView
  let ink: UIColor
  func makeUIView(context: Context) -> PKCanvasView {
    canvas.drawingPolicy = .anyInput
    canvas.backgroundColor = .white
    canvas.overrideUserInterfaceStyle = .light   // keep black ink black in dark mode
    canvas.tool = PKInkingTool(.pen, color: ink, width: 4)
    canvas.isScrollEnabled = false
    return canvas
  }
  func updateUIView(_ v: PKCanvasView, context: Context) {
    v.tool = PKInkingTool(.pen, color: ink, width: 4)
  }
}

enum SignatureRenderer {
  static func image(from drawing: PKDrawing) -> UIImage? {
    guard !drawing.strokes.isEmpty else { return nil }
    var result: UIImage?
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
      result = drawing.image(from: drawing.bounds.insetBy(dx: -6, dy: -6), scale: 3)
    }
    return result
  }

  static func image(text: String, color: UIColor) -> UIImage? {
    let name = text.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    let font = UIFont(name: "SnellRoundhand-Bold", size: 96) ?? .italicSystemFont(ofSize: 96)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (name as NSString).size(withAttributes: attrs)
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 1
    let canvas = CGSize(width: ceil(size.width) + 24, height: ceil(size.height) + 12)
    return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
      (name as NSString).draw(at: CGPoint(x: 12, y: 6), withAttributes: attrs)
    }
  }
}

@MainActor
final class SignatureStore: ObservableObject {
  struct Item: Identifiable {
    let id: String
    let url: URL
    let image: UIImage
  }
  @Published private(set) var items: [Item] = []
  private let dir: URL

  init() {
    let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? FileManager.default.temporaryDirectory
    dir = base.appendingPathComponent("Signatures", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    load()
  }

  private func load() {
    let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
    items = urls.filter { $0.pathExtension == "png" }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
      .compactMap { url in UIImage(contentsOfFile: url.path).map { Item(id: url.lastPathComponent, url: url, image: $0) } }
  }

  func add(_ image: UIImage) {
    guard let data = image.pngData() else { return }
    let name = "\(Int(Date().timeIntervalSince1970 * 1000)).png"
    try? data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    load()
    // Keep the five most recent.
    for old in items.dropFirst(5) { try? FileManager.default.removeItem(at: old.url) }
    load()
  }

  func delete(at offsets: IndexSet) {
    for i in offsets { try? FileManager.default.removeItem(at: items[i].url) }
    load()
  }
}
