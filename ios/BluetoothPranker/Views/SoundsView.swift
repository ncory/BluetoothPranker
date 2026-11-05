import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct PreparedSource: Identifiable {
    let id = UUID()
    let url: URL
    let slot: ClipSlot
    let title: String
}

/// Drives the "replace a sound" flow: pick a source (record, text-to-speech,
/// import), then convert, preview and upload. Shared by the Sounds screen and
/// the per-target screen; attach with `.clipFlowHost(flow)`.
@Observable
final class ClipFlow {
    var slot = ClipSlot(targetID: nil, kind: .enter)
    var importing = false
    var recording = false
    var speaking = false
    var pending: PreparedSource?   // waits for the source sheet to close
    var prepared: PreparedSource?  // drives the upload sheet

    func presentPending() {
        if let p = pending {
            pending = nil
            prepared = p
        }
    }
}

struct ClipFlowHost: ViewModifier {
    @Bindable var flow: ClipFlow
    @Environment(BLEManager.self) private var ble

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $flow.importing, allowedContentTypes: [.audio]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let copy = try copyToTemp(url)
                    flow.prepared = PreparedSource(url: copy, slot: flow.slot, title: url.lastPathComponent)
                } catch {
                    ble.lastError = error.localizedDescription
                }
            }
            .sheet(isPresented: $flow.recording, onDismiss: flow.presentPending) {
                RecorderSheet { url in
                    flow.pending = PreparedSource(url: url, slot: flow.slot, title: "Voice recording")
                }
            }
            .sheet(isPresented: $flow.speaking, onDismiss: flow.presentPending) {
                SpeechSheet { url, text in
                    flow.pending = PreparedSource(url: url, slot: flow.slot, title: "“\(text)”")
                }
            }
            .sheet(item: $flow.prepared) { src in
                ClipUploadSheet(source: src)
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

extension View {
    func clipFlowHost(_ flow: ClipFlow) -> some View { modifier(ClipFlowHost(flow: flow)) }
}

/// Shows one clip slot with play / replace / reset actions.
struct ClipSlotRow: View {
    let slot: ClipSlot
    let bytes: Int
    let flow: ClipFlow
    @Environment(BLEManager.self) private var ble

    private var fallback: String { slot.targetID == nil ? "Built-in jingle" : "Uses the default sound" }

    var body: some View {
        HStack {
            Image(systemName: slot.kind.symbol)
                .foregroundStyle(slot.kind == .enter ? .green : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.kind.title)
                Text(bytes > 0 ? String(format: "Custom clip · %.1f s", clipSeconds(bytes)) : fallback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                ble.perform { try await ble.play(slot) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Play on device")
            Menu {
                Button("Record with microphone", systemImage: "mic") { begin { flow.recording = true } }
                Button("Text to speech", systemImage: "text.bubble") { begin { flow.speaking = true } }
                Button("Import audio file", systemImage: "folder") { begin { flow.importing = true } }
                if bytes > 0 {
                    Divider()
                    Button(slot.targetID == nil ? "Use built-in jingle" : "Use default sound",
                           systemImage: "arrow.uturn.backward", role: .destructive) {
                        ble.perform { try await ble.deleteClip(slot) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Replace sound")
        }
    }

    private func begin(_ open: () -> Void) {
        flow.slot = slot
        open()
    }
}

struct SoundsView: View {
    @Environment(BLEManager.self) private var ble
    @State private var flow = ClipFlow()

    var body: some View {
        List {
            Section {
                ForEach(Clip.allCases) { kind in
                    ClipSlotRow(slot: ClipSlot(targetID: nil, kind: kind), bytes: ble.info?.clipBytes(kind) ?? 0,
                                flow: flow)
                }
            } header: {
                Text("Default sounds")
            } footer: {
                Text("Used for every target that doesn't have its own sound.")
            }
            ForEach(ble.targets) { t in
                Section("\(t.name)\(t.enabled ? "" : " (paused)")") {
                    ForEach(Clip.allCases) { kind in
                        ClipSlotRow(slot: ClipSlot(targetID: t.id, kind: kind), bytes: t.clipBytes(kind), flow: flow)
                    }
                }
            }
            Section {
                if let info = ble.info {
                    LabeledContent("Free space on device", value: formatBytes(info.freeBytes))
                }
            } footer: {
                Text("Clips are converted to 16 kHz mono, trimmed, normalized and limited to \(Int(ClipConverter.maxSeconds)) seconds (about 32 KB per second). Short, punchy sounds work best on the tiny speaker. Set the volume in Settings.")
            }
        }
        .navigationTitle("Sounds")
        .clipFlowHost(flow)
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
                    LabeledContent("Will play as", value: slotDescription)
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
                                ble.perform { try await ble.play(source.slot) }
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
            .navigationTitle(source.slot.kind.title)
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

    private var slotDescription: String {
        guard let id = source.slot.targetID else { return "Default \(source.slot.kind.shortTitle.lowercased()) sound" }
        return "\(ble.targetName(id)) \(source.slot.kind.shortTitle.lowercased()) sound"
    }

    private func upload(_ wav: Data) {
        uploading = true
        Task {
            do {
                try await ble.upload(wav, to: source.slot)
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
