#if DEBUG
import AVFoundation
import StickerStoriesKit

/// Developer-only `Narrator` for the story gallery: plays the pack's
/// pre-rendered narration at `rate` (1×–3×, the voice's pitch kept) through
/// AVAudioEngine — AVAudioPlayer stops at 2×. Sound effects and music are
/// mixed into the narration, so they speed up with it; so does everything
/// on the canvas, which runs on `playbackTime`.
@MainActor
final class RateNarrator: Narrator {
    private(set) var state: NarrationState = .idle

    /// Narration seconds per real second; can change while a story plays.
    var rate: Double = 1 {
        didSet { pitch.rate = Float(rate) }
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var finish: CheckedContinuation<Void, any Error>?
    /// Bumped by every play and stop, so a finished callback from an older
    /// playback is ignored.
    private var generation = 0

    init() {
        engine.attach(node)
        engine.attach(pitch)
    }

    /// The player node's own timeline counts the file's samples as they are
    /// played, so it is the narration time whatever the rate.
    var playbackTime: TimeInterval? {
        guard case .playing = state, let file, let rendered = node.lastRenderTime,
            let time = node.playerTime(forNodeTime: rendered)
        else { return nil }
        return min(max(Double(time.sampleTime) / time.sampleRate, 0), Self.duration(of: file))
    }

    var playbackDuration: TimeInterval? {
        guard case .playing = state, let file else { return nil }
        return Self.duration(of: file)
    }

    private static func duration(of file: AVAudioFile) -> TimeInterval {
        Double(file.length) / file.processingFormat.sampleRate
    }

    func narrate(_ story: Story, from pack: LoadedPack) async throws {
        stop()
        guard let audioPath = story.audioPath else {
            throw NarrationError.missingAudio(storyID: story.id)
        }
        state = .preparing
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: pack.url(forAssetPath: audioPath))
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            engine.connect(node, to: pitch, format: audio.processingFormat)
            engine.connect(pitch, to: engine.mainMixerNode, format: audio.processingFormat)
            pitch.rate = Float(rate)
            try engine.start()
        } catch {
            state = .idle
            throw NarrationError.unplayableAudio(String(describing: error))
        }
        file = audio
        generation += 1
        let current = generation
        state = .playing(story)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    finish = continuation
                    node.scheduleFile(audio, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor in self?.played(current) }
                    }
                    node.play()
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
        generation += 1
        node.stop()
        engine.stop()
        file = nil
        state = .idle
        finish?.resume(throwing: CancellationError())
        finish = nil
    }

    private func played(_ playback: Int) {
        guard playback == generation else { return }
        finish?.resume()
        finish = nil
    }
}
#endif
