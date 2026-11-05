import AVFoundation

/// Renders text-to-speech into an audio file (instead of playing it), so it
/// can be uploaded as a clip.
final class SpeechRenderer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var continuation: CheckedContinuation<URL, Error>?

    override init() {
        super.init()
        synth.delegate = self
    }

    @MainActor
    func render(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Float, pitch: Float) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString).caf")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = rate
        utterance.pitchMultiplier = pitch

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            lock.lock()
            self.file = nil
            self.url = url
            self.continuation = cont
            lock.unlock()

            synth.write(utterance) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {  // an empty buffer marks the end
                    self.finish(nil)
                    return
                }
                self.lock.lock()
                defer { self.lock.unlock() }
                guard self.continuation != nil, let url = self.url else { return }
                do {
                    if self.file == nil {
                        self.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                                    commonFormat: pcm.format.commonFormat,
                                                    interleaved: pcm.format.isInterleaved)
                    }
                    try self.file?.write(from: pcm)
                } catch {
                    let c = self.continuation
                    self.continuation = nil
                    self.file = nil
                    c?.resume(throwing: error)
                }
            }
        }
    }

    // Fallback in case the final empty buffer never arrives.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.finish(nil) }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let c = continuation
        let hadAudio = file != nil
        continuation = nil
        file = nil  // closes the file
        let u = url
        lock.unlock()
        guard let c else { return }
        if let error { c.resume(throwing: error) }
        else if hadAudio, let u { c.resume(returning: u) }
        else { c.resume(throwing: ClipConverter.ConvertError.silent) }
    }

    static var voices: [AVSpeechSynthesisVoice] {
        let lang = String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}
