import AppKit
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps document extraction independent of the editor and never silently clips a document.
enum SpeechDocument {
    static func read(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 25 * 1024 * 1024 else {
            throw SpeechStudioError.message("This document exceeds 25 MB. Import a smaller document or paste its text.")
        }
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked else {
                throw SpeechStudioError.message("This PDF could not be opened or is password protected.")
            }
            text = document.string ?? ""
        case "rtf", "docx", "doc":
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        default:
            var encoding = String.Encoding.utf8
            text = try String(contentsOf: url, usedEncoding: &encoding)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechStudioError.message("No readable text was found. Scanned PDFs need OCR before import.")
        }
        return text
    }
}

enum SpeechStudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

@MainActor
@Observable
final class SpeechStudio: NSObject, NSSpeechSynthesizerDelegate {
    var text = ""
    var documentName = "Untitled narration"
    var voiceID = NSSpeechSynthesizer.defaultVoice.rawValue
    var rate: Double = 180
    var volume: Double = 0.8
    private(set) var busy = false
    private(set) var paused = false
    private(set) var exporting = false
    var status = ""
    var error = ""
    var savedURL: URL?
    private var synthesizer: NSSpeechSynthesizer?
    private var pendingURL: URL?
    private var cancelled = false

    var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace }).count }

    func start(preview: Bool = false, export: Bool = false) {
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = ""
        guard let speaker = NSSpeechSynthesizer(voice: .init(rawValue: voiceID)) else {
            error = "This voice is unavailable. Select another voice or install one in System Settings."
            return
        }
        speaker.delegate = self
        speaker.rate = Float(rate)
        speaker.volume = Float(volume)
        synthesizer = speaker
        cancelled = false
        busy = true
        paused = false
        exporting = export
        let script = preview ? String(text.prefix(500)) : text
        var started = false
        if export {
            do {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Forge/Media", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("narration-\(UUID().uuidString).aiff")
                pendingURL = url
                started = speaker.startSpeaking(script, to: url)
            } catch { self.error = error.localizedDescription }
        } else {
            started = speaker.startSpeaking(script)
        }
        if started {
            status = export ? "Generating audio…" : (preview ? "Previewing the first 500 characters…" : "Reading…")
        } else {
            cleanupPending()
            busy = false
            exporting = false
            synthesizer = nil
            if error.isEmpty { error = "The selected voice could not start. Try another installed voice." }
        }
    }

    func togglePause() {
        guard busy, !exporting else { return }
        if paused { synthesizer?.continueSpeaking() } else { synthesizer?.pauseSpeaking(at: .immediateBoundary) }
        paused.toggle()
        status = paused ? "Paused" : "Reading…"
    }

    func stop() {
        guard busy else { return }
        cancelled = true
        let speaker = synthesizer
        synthesizer = nil
        speaker?.delegate = nil
        speaker?.stopSpeaking()
        cleanupPending()
        busy = false
        paused = false
        exporting = false
        status = "Stopped."
    }

    private func cleanupPending() {
        if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
        pendingURL = nil
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        guard sender === synthesizer else { return }
        if finishedSpeaking && !cancelled {
            if let url = pendingURL {
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 54 else { throw SpeechStudioError.message("The voice produced no audio. Try another voice.") }
                    savedURL = url
                    pendingURL = nil
                    status = "Audio saved."
                } catch {
                    self.error = error.localizedDescription
                    cleanupPending()
                    status = "Export failed."
                }
            } else { status = "Finished reading." }
        } else {
            cleanupPending()
            status = cancelled ? "Stopped." : "Speech failed."
            if !cancelled { error = "Speech synthesis did not finish. Try another voice." }
        }
        busy = false
        paused = false
        exporting = false
        synthesizer = nil
    }
}

struct SpeechStudioView: View {
    @Bindable var studio: SpeechStudio
    @State private var voices = NSSpeechSynthesizer.availableVoices
    @State private var importing = false
    @State private var readingDocument = false
    @State private var style = "Custom"
    @State private var recordings: [URL] = []

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("Text to Speech", systemImage: "waveform").font(.title2.bold())
                    Text("Turn a document into spoken narration using voices on your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("Reader’s voice", selection: $studio.voiceID) {
                        ForEach(voices, id: \.rawValue) { voice in
                            Text(voiceLabel(voice)).tag(voice.rawValue)
                        }
                    }
                    Button("Refresh installed voices") { voices = NSSpeechSynthesizer.availableVoices }
                    Text("Add voices in System Settings → Accessibility → Read & Speak (Spoken Content on older macOS versions).")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Reading pace preset", selection: $style) {
                        ForEach(["Custom", "Deliberate", "Audiobook", "Conversational", "Brisk"], id: \.self) { Text($0) }
                    }
                    .onChange(of: style) { _, value in
                        switch value {
                        case "Deliberate": studio.rate = 130
                        case "Audiobook": studio.rate = 160
                        case "Conversational": studio.rate = 180
                        case "Brisk": studio.rate = 230
                        default: break
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Speaking rate: \(Int(studio.rate)) words per minute")
                        Slider(value: $studio.rate, in: 80...400, step: 5)
                            .accessibilityLabel("Words per minute")
                        Text("Actual pace varies by voice and punctuation.").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading) {
                        Text("Volume: \(Int(studio.volume * 100))%")
                        Slider(value: $studio.volume, in: 0...1).accessibilityLabel("Speech volume")
                    }
                    Text("Edit the narration to control wording, pronunciation, and paragraph breaks. The reader speaks the text as written.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(studio.busy)
                .padding(20)
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { importing = true } label: { Label("Import Document", systemImage: "doc.badge.plus") }
                        .disabled(studio.busy || readingDocument)
                    Text(studio.documentName).lineLimit(1).foregroundStyle(.secondary)
                    if readingDocument { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text("PDF, Word (.docx, .doc), RTF, TXT, or Markdown • or paste text below")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $studio.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Theme.composerBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                    .disabled(studio.busy || readingDocument)
                    .accessibilityLabel("Narration text")
                Text("\(studio.wordCount) words • estimated audio \(estimatedDuration)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Preview Voice") { studio.start(preview: true) }
                        .disabled(!canStart)
                    Button("Read Aloud") { studio.start() }
                        .buttonStyle(.borderedProminent).tint(Theme.ember)
                        .disabled(!canStart)
                    if studio.busy {
                        if !studio.exporting {
                            Button(studio.paused ? "Resume" : "Pause") { studio.togglePause() }
                        }
                        Button("Stop") { studio.stop() }
                    }
                    Spacer()
                    Button("Generate Audio") { studio.start(export: true) }.disabled(!canStart)
                }
                if !studio.status.isEmpty { Text(studio.status).font(.callout) }
                if !studio.error.isEmpty {
                    Text(studio.error).foregroundStyle(.red).textSelection(.enabled)
                }
                if !recordings.isEmpty {
                    Menu("Previous Recordings (\(recordings.count))") {
                        ForEach(recordings, id: \.self) { url in
                            Button(url.lastPathComponent) { studio.savedURL = url }
                        }
                    }
                }
                if let url = studio.savedURL {
                    HStack {
                        Label("Saved narration (AIFF)", systemImage: "waveform")
                        Button("Play Audio") { NSWorkspace.shared.open(url) }
                        Button("Save a Copy…") { saveCopy(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }.font(.callout)
                }
            }.padding(20).frame(minWidth: 420)
        }
        .background(Theme.backgroundGradient)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText, .rtf] + ["docx", "doc", "md"].compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case .success(let url):
                readingDocument = true
                studio.error = ""
                Task { @MainActor in
                    do {
                        let text = try await Task.detached { try SpeechDocument.read(url) }.value
                        studio.text = text
                        studio.documentName = url.lastPathComponent
                        studio.status = "Document ready."
                    } catch { studio.error = error.localizedDescription }
                    readingDocument = false
                }
            case .failure(let error): studio.error = error.localizedDescription
            }
        }
        .onAppear { refreshRecordings() }
        .onChange(of: studio.savedURL) { _, _ in refreshRecordings() }
        .onDisappear { studio.stop() }
    }

    private var estimatedDuration: String {
        let seconds = Int(ceil(Double(studio.wordCount) / studio.rate * 60))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func refreshRecordings() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forge/Media", isDirectory: true)
        recordings = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "aiff" }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
            }
    }

    private var canStart: Bool {
        !studio.busy && !readingDocument && !voices.isEmpty && studio.wordCount > 0
    }

    private func voiceLabel(_ voice: NSSpeechSynthesizer.VoiceName) -> String {
        let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
        let name = attributes[.name] as? String ?? voice.rawValue
        let locale = attributes[.localeIdentifier] as? String ?? ""
        return "\(name) (\(locale))"
    }

    private func saveCopy(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.aiff]
        panel.nameFieldStringValue = "\((studio.documentName as NSString).deletingPathExtension).aiff"
        panel.begin { response in
            guard response == .OK, let destination = panel.url, destination != url else { return }
            do { try Data(contentsOf: url).write(to: destination, options: .atomic) }
            catch { studio.error = error.localizedDescription }
        }
    }
}
