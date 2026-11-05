import AVFoundation
import Observation

/// Plays a converted clip on the phone so you can hear it before uploading.
@Observable
final class PreviewPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ wav: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: wav)
            p.delegate = self
            player = p
            isPlaying = p.play()
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false }
    }
}
