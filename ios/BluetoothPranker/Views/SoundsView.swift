import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct PreparedSource: Identifiable {
    let id = UUID()
    let url: URL
    let clip: Clip
    let title: String
}

struct SoundsView: View {
    @Environment(BLEManager.self) private var ble
    @State private var target: Clip = .enter
    @State private var importing = false
    @State private var recording = false
    @State private var speaking = false
    @State private var pending: PreparedSource?   // waits for the source sheet to close
    @State private var prepared: PreparedSource?  // drives the upload sheet

    var body: some View {
        List {
            ForEach(Clip.allCases) { clip in
                let bytes = ble.info?.clipBytes(clip) ?? 0
                Section {
                    LabeledContent("Current") {
                        Text(bytes > 0 ? String(format: "Custom clip · %.1f s", clipSeconds(bytes)) : "Built-in jingle")
                    }
                    Button {
                        ble.perform { try await ble.play(clip) }
                    } label: {
                        Label("Play on device", systemImage: "play.fill")
                    }
                    Menu {
                        Button("Record with microphone", systemImage: "mic") { target = clip; recording = true }
                        Button("Text to speech", systemImage: "text.bubble") { target = clip; speaking = true }
                        Button("Import audio file", systemImage: "folder") { target = clip; importing = true }
                    } label: {
                        Label("Replace…", systemImage: "square.and.arrow.down")
                    }
                    if bytes > 0 {
                        Button("Go back to built-in jingle", role: .destructive) {
                            ble.perform { try await ble.deleteClip(clip) }
                        }
                    }
                } header: {
                    Label(clip.title, systemImage: clip.symbol)
                }
            }
            Section {
                if let info = ble.info {
                    LabeledContent("Free space on device", value: formatBytes(info.freeBytes))
                }
            } footer: {
                Text("Clips are converted to 16 kHz mono, trimmed, normalized and limited to \(Int(ClipConverter.maxSeconds)) seconds. Short, punchy sounds work best on the tiny speaker. Set the volume in Settings.")
            }
        }
        .navigationTitle("Sounds")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result else { return }
            do {
                let copy = try copyToTemp(url)
                prepared = PreparedSource(url: copy, clip: target, title: url.lastPathComponent)
            } catch {
                ble.lastError = error.localizedDescription
            }
        }
        .sheet(isPresented: $recording, onDismiss: presentPending) {
            RecorderSheet { url in
                pending = PreparedSource(url: url, clip: target, title: "Voice recording")
            }
        }
        .sheet(isPresented: $speaking, onDismiss: presentPending) {
            SpeechSheet { url, text in
                pending = PreparedSource(url: url, clip: target, title: "“\(text)”")
            }
        }
        .sheet(item: $prepared) { src in
            ClipUploadSheet(source: src)
        }
    }

    private func presentPending() {
        if let p = pending {
            pending = nil
            prepared = p
        }
    }

    private func copyToTemp(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

struct ClipUploadSheet: View {
    let source: PreparedSource
    @Environment(BLEManager.self) private var ble
    @Environment(\.dismiss) private var dismiss
    @State private var result: ClipConverter.Result?
    @State private var error: String?
    @State private var uploading = false
    @State private var done = false
    @State private var player = PreviewPlayer()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Source", value: source.title)
                    LabeledContent("Will play on", value: source.clip.title)
                }
                if let r = result {
                    Section {
                        LabeledContent("Length", value: String(format: "%.1f s", r.duration))
                        LabeledContent("Size", value: formatBytes(r.wav.count))
                        Button {
                            player.isPlaying ? player.stop() : player.play(r.wav)
                        } label: {
                            Label(player.isPlaying ? "Stop" : "Preview on this phone",
                                  systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                        }
                    }
                    Section {
                        if uploading {
                            ProgressView(value: ble.uploadProgress ?? 0) {
                                Text("Uploading… \(Int((ble.uploadProgress ?? 0) * 100))%")
                            }
                        } else if done {
                            Label("Uploaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button {
                                ble.perform { try await ble.play(source.clip) }
                            } label: {
                                Label("Play on device", systemImage: "speaker.wave.2.fill")
                            }
                        } else {
                            Button {
                                upload(r.wav)
                            } label: {
                                Label("Upload to device", systemImage: "arrow.up.circle.fill")
                            }
                            .disabled(ble.phase != .connected)
                        }
                    } footer: {
                        Text("Uploading usually takes 5 to 20 seconds. Keep the phone near the device.")
                    }
                } else if let error {
                    Section { Text(error).foregroundStyle(.red) }
                } else {
                    Section { ProgressView("Converting…") }
                }
            }
            .navigationTitle(source.clip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: done ? .confirmationAction : .cancellationAction) {
                    Button(done ? "Done" : "Cancel") {
                        player.stop()
                        dismiss()
                    }
                    .disabled(uploading)
                }
            }
            .interactiveDismissDisabled(uploading)
            .task {
                let url = source.url
                do {
                    result = try await Task.detached { try ClipConverter.convert(url: url) }.value
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func upload(_ wav: Data) {
        uploading = true
        Task {
            do {
                try await ble.upload(wav, to: source.clip)
                done = true
            } catch {
                ble.lastError = error.localizedDescription
            }
            uploading = false
        }
    }
}

struct RecorderSheet: View {
    var onFinish: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = ClipRecorder()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(String(format: "%.1f s", recorder.isRecording ? recorder.currentTime : 0))
                        .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                }
                Text("Up to \(Int(ClipConverter.maxSeconds)) seconds. Tap to start, tap again to stop.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    toggle()
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 88))
                        .foregroundStyle(.red)
                }
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
                if let error {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        dismiss()
                    }
                }
            }
            .onChange(of: recorder.recordedURL) { _, url in
                if let url {
                    onFinish(url)
                    dismiss()
                }
            }
        }
    }

    private func toggle() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            Task {
                do { try await recorder.start() } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct SpeechSheet: View {
    var onFinish: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Welcome home, your majesty."
    @State private var voiceID = SpeechRenderer.voices.first?.identifier ?? ""
    @State private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    @State private var pitch: Float = 1.0
    @State private var renderer = SpeechRenderer()
    @State private var busy = false
    @State private var error: String?

    private let ideas = [
        "Welcome home, your majesty.",
        "Intruder alert! Intruder alert!",
        "I see you.",
        "Leaving so soon?",
        "Did you remember to feed the cat?",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("What should it say?") {
                    TextField("Text", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                    Menu("Ideas") {
                        ForEach(ideas, id: \.self) { idea in Button(idea) { text = idea } }
                    }
                }
                Section("Voice") {
                    Picker("Voice", selection: $voiceID) {
                        ForEach(SpeechRenderer.voices, id: \.identifier) { v in
                            Text(v.quality == .default ? v.name : "\(v.name) ★").tag(v.identifier)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Speed").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $rate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                    }
                    VStack(alignment: .leading) {
                        Text("Pitch").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $pitch, in: 0.5...2.0)
                    }
                }
                Section {
                    Button {
                        generate()
                    } label: {
                        if busy { ProgressView() } else { Label("Create clip", systemImage: "waveform") }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Download better voices in Settings › Accessibility › Spoken Content › Voices (★ = enhanced).")
                }
            }
            .navigationTitle("Text to speech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func generate() {
        busy = true
        error = nil
        let spoken = text
        Task {
            do {
                let url = try await renderer.render(spoken, voice: AVSpeechSynthesisVoice(identifier: voiceID),
                                                    rate: rate, pitch: pitch)
                onFinish(url, spoken)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
