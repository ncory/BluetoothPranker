import AVFoundation
import Observation

/// Records a short voice clip with the iPhone microphone.
@Observable
final class ClipRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var recordedURL: URL?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var discard = false

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    enum RecordError: LocalizedError {
        case noPermission
        var errorDescription: String? { "Microphone access is off. Enable it in Settings > Privacy > Microphone." }
    }

    @MainActor
    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecordError.noPermission }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        recorder = r
        recordedURL = nil
        discard = false
        r.record(forDuration: ClipConverter.maxSeconds)
        isRecording = true
    }

    func stop() {
        recorder?.stop()
    }

    /// Stops and throws the recording away.
    func cancel() {
        discard = true
        recorder?.stop()
        recorder?.deleteRecording()
        isRecording = false
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordedURL = (flag && !self.discard) ? url : nil
        }
    }
}
