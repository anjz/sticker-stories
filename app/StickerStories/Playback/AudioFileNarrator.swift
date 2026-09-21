import AVFoundation
import StickerStoriesKit

/// v1 `Narrator`: plays the pack's pre-rendered narration file with
/// AVAudioPlayer. A future narrator synthesises speech from `story.text`
/// instead — nothing outside this type may assume audio files exist.
@MainActor
final class AudioFileNarrator: NSObject, Narrator {
    private(set) var state: NarrationState = .idle

    /// The audio player's position — the clock sticker effects follow.
    var playbackTime: TimeInterval? {
        guard case .playing = state, let player else { return nil }
        return player.currentTime
    }

    private var player: AVAudioPlayer?
    private var finish: CheckedContinuation<Void, any Error>?
    /// A finish that arrived before `narrate` was waiting for it (a very
    /// short file, or a decode error straight after `play`).
    private var earlyResult: Result<Void, any Error>?

    /// An `AVAudioPlayer` handed from the audio set-up task to the main
    /// actor. AVAudioPlayer is not Sendable; it is only ever touched on the
    /// main actor once it crosses, so the transfer is safe.
    private struct StartedPlayer: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    func narrate(_ story: Story, from pack: LoadedPack) async throws {
        stop()

        guard let audioPath = story.audioPath else {
            throw NarrationError.missingAudio(storyID: story.id)
        }
        state = .preparing
        earlyResult = nil

        let started: StartedPlayer
        do {
            let url = pack.url(forAssetPath: audioPath)
            started = try await Task.detached(priority: .userInitiated) {
                try Self.startPlayback(of: url, delegate: self)
            }.value
        } catch {
            state = .idle
            throw NarrationError.unplayableAudio(String(describing: error))
        }
        guard case .preparing = state else {
            // Stopped while the audio server was being set up.
            started.player.stop()
            throw CancellationError()
        }
        player = started.player
        state = .playing(story)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if let result = earlyResult {
                        earlyResult = nil
                        continuation.resume(with: result)
                    } else {
                        finish = continuation
                    }
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

    /// Configuring and activating the audio session and starting the player
    /// all block on the audio server — Xcode flags them as hang risks on the
    /// main thread — so the whole set-up runs off it and only the running
    /// player comes back.
    private nonisolated static func startPlayback(of url: URL, delegate: AudioFileNarrator) throws -> StartedPlayer {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = delegate
        player.play()
        return StartedPlayer(player: player)
    }

    func stop() {
        player?.stop()
        player = nil
        state = .idle
        earlyResult = nil
        finish?.resume(throwing: CancellationError())
        finish = nil
    }

    private func playbackFinished(successfully: Bool) {
        player = nil
        let result: Result<Void, any Error> = successfully ? .success(()) : .failure(NarrationError.unplayableAudio("decode failure"))
        if let finish {
            finish.resume(with: result)
            self.finish = nil
        } else if case .playing = state {
            earlyResult = result
        }
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
