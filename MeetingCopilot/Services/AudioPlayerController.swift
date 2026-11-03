import AVFoundation
import Foundation

@MainActor
final class AudioPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var playbackRate: Float = 1
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL?) {
        stopTimer()
        player?.stop()
        player = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        errorMessage = nil

        guard let url,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.rate = playbackRate
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to seconds: Double, play: Bool = true) {
        guard let player else { return }
        player.currentTime = min(max(seconds, 0), player.duration)
        currentTime = player.currentTime
        if play && !player.isPlaying {
            player.rate = playbackRate
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = player.duration
            self.stopTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
