import PDFKit
import SwiftUI

/// First-run setup: downloads the voice model once.
struct NarratorSetupView: View {
  @ObservedObject private var downloader = ModelDownloader.shared
  var onDone: () -> Void = {}

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "waveform.and.person.filled").font(.system(size: 52)).foregroundStyle(Color.accentColor)
      Text("Set Up the Narrator").font(.title2.bold())
      Text("PDF Studio can read your books aloud with a voice model that runs entirely on this iPhone. Nothing you read leaves the device.")
        .multilineTextAlignment(.center).foregroundStyle(.secondary)
      Label("One-time download: \(ByteCountFormatter.string(fromByteCount: VoiceFiles.totalBytes, countStyle: .file)). Use Wi-Fi.",
            systemImage: "arrow.down.circle")
        .font(.footnote)
      switch downloader.state {
      case .installed:
        Label("Narrator ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        Button("Done", action: onDone).buttonStyle(.borderedProminent)
      case .downloading, .verifying:
        ProgressView(value: downloader.progress) {
          Text(downloader.state == .verifying ? "Checking files…" :
               "\(ByteCountFormatter.string(fromByteCount: downloader.bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: VoiceFiles.totalBytes, countStyle: .file))")
            .font(.footnote.monospacedDigit())
        }
        Text("It keeps downloading if you leave the app.").font(.caption).foregroundStyle(.secondary)
        Button("Cancel", role: .destructive) { downloader.cancel() }
      case .notInstalled, .failed:
        if case .failed(let message) = downloader.state { Text(message).font(.footnote).foregroundStyle(.red) }
        Button { downloader.start() } label: { Text("Download Voice").frame(maxWidth: 260) }
          .buttonStyle(.borderedProminent).controlSize(.large)
        Button("Not Now", action: onDone)
      }
      Text("Voice: Kokoro-82M by hexgrad (Apache-2.0). Pronunciation: Misaki / CMUdict (MIT).")
        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
    }
    .padding(24)
  }
}

/// Listen: choose chapters to narrate, watch progress, and play.
struct ListenSheet: View {
  let doc: PDFDocument
  let fileURL: URL?
  let bookKey: String
  let title: String
  @ObservedObject var chapters: ChapterModel
  let currentPage: Int

  @ObservedObject private var downloader = ModelDownloader.shared
  @ObservedObject private var narrator = Narrator.shared
  @ObservedObject private var player = NarrationPlayer.shared
  @Environment(\.dismiss) private var dismiss

  @State private var from = 0
  @State private var to = 0
  @State private var narratorVoice = KokoroEngine.defaultNarrator
  @State private var dialogueVoice = KokoroEngine.defaultDialogue
  @State private var keepAhead = true
  @State private var ahead = 50
  @State private var queueing = false
  @State private var confirmDelete = false

  private var book: NarrationBook? { narrator.books[bookKey] }
  private var list: [Chapter] { chapters.chapters }
  private var speed: Double { narrator.speed ?? 5 }

  var body: some View {
    NavigationStack {
      Group {
        if !downloader.isInstalled {
          ScrollView { NarratorSetupView() }
        } else if list.isEmpty {
          ContentUnavailableView(chapters.scanning ? "Finding chapters…" : "No chapters found",
                                 systemImage: "list.bullet",
                                 description: Text("The narrator works chapter by chapter."))
        } else {
          form
        }
      }
      .navigationTitle("Listen")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    .onAppear(perform: setDefaults)
  }

  private var form: some View {
    Form {
      if player.bookKey == bookKey { nowPlaying }

      Section {
        Picker("From", selection: $from) { chapterOptions }
          .pickerStyle(.navigationLink)
          .onChange(of: from) { _, f in if to < f { to = min(f + ahead - 1, list.count - 1) } }
        Picker("To", selection: $to) { chapterOptions }
          .pickerStyle(.navigationLink)
        Picker("Narrator", selection: $narratorVoice) { voiceOptions }
        Picker("Dialogue", selection: $dialogueVoice) { voiceOptions }
        Toggle("Keep generating ahead", isOn: $keepAhead)
        if keepAhead {
          Stepper("\(ahead) chapters ahead of listening", value: $ahead, in: 5...200, step: 5)
        }
        Button {
          queue()
        } label: {
          if queueing { ProgressView() } else { Text("Generate \(max(0, to - from + 1)) Chapters") }
        }
        .disabled(to < from || queueing)
      } header: {
        Text("Generate")
      } footer: {
        Text(estimate + (keepAhead ? " As you listen, more chapters are queued to stay \(ahead) ahead." : ""))
      }

      statusSection

      if let book, !book.chapters.isEmpty {
        Section("Chapters") {
          ForEach(book.chapters) { ch in chapterRow(ch, book: book) }
        }
        Section {
          Button("Delete This Book's Audio", role: .destructive) { confirmDelete = true }
        } footer: {
          Text("\(ByteCountFormatter.string(fromByteCount: book.audioBytes, countStyle: .file)) of audio stored on this iPhone.")
        }
      }
    }
    .confirmationDialog("Delete all generated audio for this book?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete Audio", role: .destructive) {
        if player.bookKey == bookKey { player.stop() }
        narrator.deleteAudio(bookKey)
      }
    }
  }

  @ViewBuilder private var chapterOptions: some View {
    ForEach(Array(list.enumerated()), id: \.offset) { i, ch in Text(ch.title).tag(i) }
  }

  @ViewBuilder private var voiceOptions: some View {
    ForEach(KokoroEngine.voices, id: \.self) { Text(KokoroEngine.displayName($0)).tag($0) }
  }

  private var nowPlaying: some View {
    Section("Now Playing") {
      VStack(alignment: .leading, spacing: 10) {
        Text(player.chapterTitle).font(.headline)
        Text(player.waiting ? "Waiting for the next part to be generated…" : Self.clock(player.chapterElapsed))
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        HStack(spacing: 28) {
          Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
          Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
          Button { player.toggle() } label: {
            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
          }
          Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
          Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .frame(maxWidth: .infinity)
        Picker("Speed", selection: $player.rate) {
          ForEach([0.8, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag(Float($0)) }
        }
        .pickerStyle(.segmented)
      }
    }
  }

  private var statusSection: some View {
    Section {
      switch narrator.status {
      case .idle:
        Label(narrator.hasPendingWork ? "Ready to continue" : "Nothing left to generate", systemImage: "checkmark.circle")
        if narrator.hasPendingWork { Button("Continue Generating") { narrator.start() } }
      case .loadingModel:
        Label("Loading the voice…", systemImage: "hourglass")
      case .generating(let key, let order):
        let ch = narrator.books[key]?.chapters.first { $0.order == order }
        VStack(alignment: .leading) {
          Label("Generating \(ch?.title ?? "")", systemImage: "waveform")
          ProgressView(value: ch?.fraction ?? 0)
        }
        Button("Pause", role: .destructive) { narrator.stop() }
      case .paused(let why):
        Label(why, systemImage: "pause.circle")
        Button("Continue Generating") { narrator.start() }
      case .failed(let why):
        Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        Button("Try Again") { narrator.start() }
      }
      if let e = narrator.lastEngineError {
        Text("Last skipped line: \(e)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let s = narrator.speed {
        LabeledContent("Speed on this iPhone", value: String(format: "%.2f× real time", s))
      }
    } header: {
      Text("Status")
    } footer: {
      Text(narrator.backgroundMode)
    }
  }

  private func chapterRow(_ ch: NarrationChapter, book: NarrationBook) -> some View {
    Button {
      player.play(bookKey, chapter: ch.order)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(ch.title).foregroundStyle(.primary).lineLimit(1)
          Group {
            if ch.isDone { Text(Self.clock(ch.duration)) }
            else if ch.nextLine > 0 { Text("\(Int(ch.fraction * 100))% · \(Self.clock(ch.duration)) ready") }
            else { Text("Queued · about \(Int(ch.estimatedDuration / 60)) min") }
          }
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Spacer()
        if player.bookKey == bookKey, player.chapterOrder == ch.order {
          Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
        } else if ch.isDone {
          Image(systemName: "play.circle").foregroundStyle(Color.accentColor)
        } else if ch.nextLine > 0 {
          Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
      }
    }
    .disabled(ch.parts.isEmpty)
    .swipeActions {
      Button("Remove", role: .destructive) { narrator.remove(chapter: ch.order, from: bookKey) }
    }
  }

  /// Rough numbers from page text before anything is generated.
  private var estimate: String {
    guard to >= from, !list.isEmpty else { return "" }
    let pages = (from...to).reduce(0) { $0 + ChapterText.pageRange(of: $1, in: list, pageCount: doc.pageCount).count }
    // Sample a few pages for words per page.
    let sample = stride(from: list[from].pageIndex, to: min(list[from].pageIndex + 6, doc.pageCount), by: 1)
      .map { doc.page(at: $0)?.string?.split(separator: " ").count ?? 0 }
    let wordsPerPage = Double(sample.reduce(0, +)) / Double(max(sample.count, 1))
    let minutes = Double(pages) * wordsPerPage / 150
    let mb = minutes * 60 * 32_000 / 8 / 1_000_000
    let work = minutes / speed / 60
    return String(format: "About %@ of audio, %@ on this iPhone, and roughly %.0f hours of generating at %.2f× real time%@.",
                  Self.duration(minutes * 60), ByteCountFormatter.string(fromByteCount: Int64(mb * 1_000_000), countStyle: .file),
                  work, speed, narrator.speed == nil ? " (estimate until measured)" : "")
  }

  private func setDefaults() {
    guard !list.isEmpty else { return }
    if let book {
      // Books queued with an older voice model fall back to the defaults.
      narratorVoice = KokoroEngine.voices.contains(book.narratorVoice) ? book.narratorVoice : KokoroEngine.defaultNarrator
      dialogueVoice = KokoroEngine.voices.contains(book.dialogueVoice) ? book.dialogueVoice : KokoroEngine.defaultDialogue
      keepAhead = book.ahead > 0
      ahead = book.ahead > 0 ? book.ahead : 50
    }
    let current = list.lastIndex { $0.pageIndex <= currentPage } ?? 0
    let start = book.flatMap { b in b.chapters.last.map { min($0.order + 1, list.count - 1) } } ?? current
    from = start
    to = min(start + ahead - 1, list.count - 1)
  }

  private func queue() {
    queueing = true
    Task {
      await narrator.enqueue(fileURL: fileURL, doc: doc, key: bookKey, title: title, chapters: list, range: from...to,
                             narratorVoice: narratorVoice, dialogueVoice: dialogueVoice, ahead: keepAhead ? ahead : 0)
      queueing = false
    }
  }

  static func clock(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
  }

  static func duration(_ s: Double) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = s >= 3600 ? [.hour, .minute] : [.minute]
    f.unitsStyle = .short
    return f.string(from: s) ?? ""
  }
}
