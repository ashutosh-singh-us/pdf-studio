import Foundation
import PDFKit

/// One spoken line: narration (voice 0) or dialogue inside quotes (voice 1).
struct NarrationLine: Codable, Hashable {
  let v: Int
  let t: String
}

/// Turns PDF pages into clean text and splits it into lines the voice model can speak.
enum ChapterText {
  /// Page range for each chapter: from its first page up to the page before the next chapter.
  static func pageRange(of index: Int, in chapters: [Chapter], pageCount: Int) -> Range<Int> {
    let start = chapters[index].pageIndex
    var end = pageCount
    for next in chapters[(index + 1)...] where next.pageIndex > start {
      end = next.pageIndex
      break
    }
    if index + 1 < chapters.count, chapters[index + 1].pageIndex == start { end = start + 1 }
    return start..<max(end, start + 1)
  }

  private static let pageNumber = try! NSRegularExpression(
    pattern: #"^\s*(page\s*)?\d{1,5}(\s*(/|of)\s*\d{1,5})?\s*$|^\s*[ivxlcdm]{1,6}\s*$"#, options: [.caseInsensitive])

  /// Text of the given pages with page numbers, repeated headers and line-break hyphens removed.
  static func text(doc: PDFDocument, pages: Range<Int>) -> String {
    var lines: [String] = []
    var previousFirst = ""
    for i in pages where i < doc.pageCount {
      autoreleasepool {
        guard let raw = doc.page(at: i)?.string else { return }
        var pageLines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
        pageLines.removeAll { pageNumber.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        // A running header repeats as the first line of consecutive pages.
        if let first = pageLines.first {
          if first == previousFirst, first.count < 80 { pageLines.removeFirst() }
          previousFirst = first
        }
        lines.append(contentsOf: pageLines)
      }
    }
    var out = ""
    for line in lines {
      if out.hasSuffix("-"), let c = line.first, c.isLowercase {
        out.removeLast()
        out += line
      } else {
        if !out.isEmpty { out += " " }
        out += line
      }
    }
    return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }

  static let maxLineChars = 260

  /// Splits text into narration and quoted dialogue, then into sentence groups of at most `maxLineChars`.
  static func lines(from text: String) -> [NarrationLine] {
    // The model reads <tags> as emotion cues, so remove angle brackets from book text.
    let cleaned = text.replacingOccurrences(of: "<", with: "(").replacingOccurrences(of: ">", with: ")")
    var pieces: [(Int, String)] = []
    var current = ""
    var inQuote = false
    for ch in cleaned {
      let opens = ch == "\u{201C}" || (ch == "\"" && !inQuote)
      let closes = ch == "\u{201D}" || (ch == "\"" && inQuote)
      if opens && !inQuote {
        pieces.append((0, current)); current = ""; inQuote = true
      } else if closes && inQuote {
        pieces.append((1, current)); current = ""; inQuote = false
      } else {
        current.append(ch)
      }
    }
    pieces.append((inQuote ? 1 : 0, current))

    var out: [NarrationLine] = []
    for (voice, raw) in pieces {
      // An unbalanced quote would make a whole page "dialogue"; treat very long quotes as narration.
      let v = voice == 1 && raw.count > 700 ? 0 : voice
      let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ",;:")))
      guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
      for chunk in split(trimmed) {
        out.append(NarrationLine(v: v, t: chunk))
      }
    }
    return out
  }

  /// Sentence groups up to `maxLineChars`; very long sentences are cut at commas or spaces.
  static func split(_ text: String) -> [String] {
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
      if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
    }
    if sentences.isEmpty { sentences = [text] }
    var out: [String] = []
    var buf = ""
    func flush() { if !buf.isEmpty { out.append(buf); buf = "" } }
    for s in sentences {
      if s.count > maxLineChars {
        flush()
        var rest = Substring(s)
        while rest.count > maxLineChars {
          let window = rest.prefix(maxLineChars)
          let cut = window.lastIndex(where: { ",;:".contains($0) }) ?? window.lastIndex(of: " ") ?? window.endIndex
          let piece = rest[..<cut].trimmingCharacters(in: .whitespaces)
          if !piece.isEmpty { out.append(piece + (cut < window.endIndex && rest[cut] != " " ? String(rest[cut]) : "")) }
          rest = rest[(cut < rest.endIndex ? rest.index(after: cut) : cut)...]
        }
        buf = rest.trimmingCharacters(in: .whitespaces)
      } else if buf.count + s.count + 1 > maxLineChars {
        flush()
        buf = s
      } else {
        buf = buf.isEmpty ? s : buf + " " + s
      }
    }
    flush()
    return out
  }

  static func wordCount(_ lines: [NarrationLine]) -> Int {
    lines.reduce(0) { $0 + $1.t.split(separator: " ").count }
  }
}
