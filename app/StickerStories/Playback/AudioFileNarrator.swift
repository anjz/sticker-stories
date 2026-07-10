import AVFoundation
import StickerStoriesKit

/// v1 `Narrator`: plays the pack's pre-rendered narration file with
/// AVAudioPlayer. A future narrator synthesises speech from `story.text`
/// instead — nothing outside this type may assume audio files exist.
@MainActor
final class AudioFileNarrator: NSObject, Narrator {
    private(set) var state: NarrationState = .idle

    private var player: AVAudioPlayer?
    private var finish: CheckedContinuation<Void, any Error>?

    func narrate(_ story: Story, from pack: LoadedPack) async throws {
        stop()

        guard let audioPath = story.audioPath else {
            throw NarrationError.missingAudio(storyID: story.id)
        }
        state = .preparing

        let newPlayer: AVAudioPlayer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            newPlayer = try AVAudioPlayer(contentsOf: pack.url(forAssetPath: audioPath))
        } catch {
            state = .idle
            throw NarrationError.unplayableAudio(String(describing: error))
        }

        newPlayer.delegate = self
        player = newPlayer
        state = .playing(story)
        newPlayer.play()

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    finish = continuation
                }
            } onCancel: {
                Task { @MainActor in self.stop() }
            }
            state = .finished
        } catch {
            state = .idle
            throw error
        }
    }

    func stop() {
        player?.stop()
        player = nil
        state = .idle
        finish?.resume(throwing: CancellationError())
        finish = nil
    }

    private func playbackFinished(successfully: Bool) {
        player = nil
        if successfully {
            finish?.resume()
        } else {
            finish?.resume(throwing: NarrationError.unplayableAudio("decode failure"))
        }
        finish = nil
    }
}

extension AudioFileNarrator: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playbackFinished(successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in self.playbackFinished(successfully: false) }
    }
}
