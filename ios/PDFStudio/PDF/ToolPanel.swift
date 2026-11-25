import PDFKit
import SwiftUI

/// The bottom bar: a context row for the current tool or selection, and the tool buttons.
struct ToolPanel: View {
  @ObservedObject var editor: PDFEditor
  @Binding var showSignature: Bool
  @Binding var showPhotoPicker: Bool
  @Binding var showImageImporter: Bool

  static let palette: [UIColor] = [
    .black, UIColor(red: 0.84, green: 0.25, blue: 0.17, alpha: 1), .systemBlue, .systemGreen, .systemOrange, .systemPurple,
  ]
  static let highlightPalette: [UIColor] = [
    UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1), UIColor(red: 0.5, green: 0.9, blue: 0.4, alpha: 1),
    UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 1), UIColor(red: 1, green: 0.55, blue: 0.75, alpha: 1),
  ]

  var body: some View {
    VStack(spacing: 6) {
      contextRow
        .frame(minHeight: 34)
        .padding(.horizontal, 12)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(PDFTool.allCases) { t in
            ToolButton(title: t.title, symbol: t.symbol, active: editor.tool == t) { editor.tool = t }
          }
          Divider().frame(height: 30).padding(.horizontal, 4)
          ToolButton(title: "Sign", symbol: "signature", active: false) { showSignature = true }
          Menu {
            Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            Button { showImageImporter = true } label: { Label("Files", systemImage: "folder") }
          } label: {
            ToolLabel(title: "Image", symbol: "photo", active: false)
          }
        }
        .padding(.horizontal, 8)
      }
    }
    .padding(.top, 8)
    .padding(.bottom, 4)
  }

  @ViewBuilder private var contextRow: some View {
    switch editor.tool {
    case .select:
      if let sel = editor.selected {
        HStack(spacing: 14) {
          if sel.type == PDFAnnotationSubtype.freeText.rawValue {
            Button("Edit Text") { editor.requestEdit(sel) }
          }
          if sel.type != PDFAnnotationSubtype.stamp.rawValue, sel.userName != "PDF Studio white-out" {
            swatches(Self.palette) { editor.setColor($0, of: sel) }
          }
          Spacer()
          Button(role: .destructive) { editor.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
          Button("Done") { editor.select(nil) }.fontWeight(.semibold)
        }
      } else {
        hint("Tap something you added to move, resize or delete it.")
      }
    case .read:
      hint("Tap form fields to fill them. Long-press text to select and copy.")
    case .whiteout:
      hint("Drag over an area to cover it. Not redaction: hidden text stays in the file.")
    case .highlight:
      HStack {
        swatches(Self.highlightPalette, current: editor.highlightColor) { editor.highlightColor = $0 }
        Spacer()
        Text("Drag across text").font(.footnote).foregroundStyle(.secondary)
      }
    case .text:
      HStack {
        swatches(Self.palette, current: editor.color) { editor.color = $0 }
        Spacer()
        Stepper("\(Int(editor.fontSize)) pt", value: $editor.fontSize, in: 6...72, step: 2).fixedSize()
          .font(.footnote.monospacedDigit())
      }
    case .draw, .rectangle:
      HStack {
        swatches(Self.palette, current: editor.color) { editor.color = $0 }
        Slider(value: $editor.lineWidth, in: 1...12).frame(maxWidth: 140)
          .accessibilityLabel("Line width")
      }
    }
  }

  private func hint(_ text: String) -> some View {
    Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      .lineLimit(2)
  }

  private func swatches(_ colors: [UIColor], current: UIColor? = nil, pick: @escaping (UIColor) -> Void) -> some View {
    HStack(spacing: 8) {
      ForEach(colors, id: \.self) { c in
        Button { pick(c) } label: {
          Circle().fill(Color(uiColor: c)).frame(width: 24, height: 24)
            .overlay(Circle().strokeBorder(Color.primary.opacity(current == c ? 0.9 : 0.15), lineWidth: current == c ? 2.5 : 1))
        }
        .accessibilityLabel(c.accessibilityName)
      }
    }
  }
}

struct ToolButton: View {
  let title: String
  let symbol: String
  let active: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) { ToolLabel(title: title, symbol: symbol, active: active) }
      .buttonStyle(.plain)
      .accessibilityAddTraits(active ? .isSelected : [])
  }
}

struct ToolLabel: View {
  let title: String
  let symbol: String
  let active: Bool
  var body: some View {
    VStack(spacing: 3) {
      Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(height: 22)
      Text(title).font(.caption2)
    }
    .frame(width: 62, height: 48)
    .foregroundStyle(active ? Color.white : Color.primary)
    .background(active ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    .contentShape(Rectangle())
  }
}

/// Add or edit a text box.
struct TextEntrySheet: View {
  @State var request: TextEditRequest
  let done: (TextEditRequest) -> Void
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Text", text: $request.text, axis: .vertical)
            .lineLimit(3...10)
            .focused($focused)
            .font(.system(size: min(request.fontSize, 28)))
            .foregroundStyle(Color(uiColor: request.color))
        }
        Section("Style") {
          Stepper("Size: \(Int(request.fontSize)) pt", value: $request.fontSize, in: 6...72, step: 1)
          HStack(spacing: 12) {
            ForEach(ToolPanel.palette, id: \.self) { c in
              Button { request.color = c } label: {
                Circle().fill(Color(uiColor: c)).frame(width: 28, height: 28)
                  .overlay(Circle().strokeBorder(Color.primary, lineWidth: request.color == c ? 2.5 : 0))
              }
              .buttonStyle(.plain)
              .accessibilityLabel(c.accessibilityName)
            }
          }
        }
        if request.annotation != nil {
          Section {
            Button("Delete Text", role: .destructive) { request.text = ""; done(request); dismiss() }
          }
        }
      }
      .navigationTitle(request.annotation == nil ? "Add Text" : "Edit Text")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { done(request); dismiss() }.disabled(request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .onAppear { focused = true }
    }
    .presentationDetents([.medium, .large])
  }
}
