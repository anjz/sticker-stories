import QuartzCore
import StickerStoriesKit

/// The timeline sticker effects run on: the narrator's playback time (the
/// same clock any word cues would use), smoothed for frame rate.
///
/// `AVAudioPlayer.currentTime` only advances in audio-buffer steps, so it
/// is interpolated with `CACurrentMediaTime` between hard resyncs (every
/// ~250 ms or whenever drift exceeds ~40 ms). When the narrator reports no
/// time (audio failed to load) a synthetic clock keeps the screen alive.
/// The result is monotonic except for genuine seeks, so a resync never
/// makes effects stutter backwards.
@MainActor
final class PlaybackClock {
    static let resyncInterval: CFTimeInterval = 0.25
    static let driftTolerance: TimeInterval = 0.04
    /// Backward source jumps smaller than this are held rather than replayed.
    static let seekThreshold: TimeInterval = 0.5

    private let source: () -> TimeInterval?
    private var anchorValue: TimeInterval?
    private var anchorHost: CFTimeInterval = 0
    private var lastReturned: TimeInterval = 0
    private var isPaused = false
    private var syntheticStart: CFTimeInterval?

    /// - Parameter source: seconds into the narration, or `nil` when unknown.
    init(source: @escaping () -> TimeInterval?) {
        self.source = source
    }

    func now() -> TimeInterval {
        let host = CACurrentMediaTime()
        guard let value = source() else {
            if syntheticStart == nil { syntheticStart = host - lastReturned }
            return advance(to: host - syntheticStart!)
        }
        syntheticStart = nil

        guard let anchor = anchorValue else {
            anchorValue = value
            anchorHost = host
            return advance(to: value)
        }

        let predicted = isPaused ? lastReturned : anchor + (host - anchorHost)
        let due = host - anchorHost >= Self.resyncInterval || abs(value - predicted) > Self.driftTolerance
        guard due else { return advance(to: predicted) }

        if value == anchor {
            // The source has not moved since the last resync: paused.
            isPaused = true
            return lastReturned
        }
        isPaused = false
        anchorValue = value
        anchorHost = host
        return advance(to: value)
    }

    private func advance(to candidate: TimeInterval) -> TimeInterval {
        // Hold small backward corrections (interpolation overshoot); let
        // real seeks through.
        let result = candidate < lastReturned && lastReturned - candidate < Self.seekThreshold ? lastReturned : candidate
        lastReturned = result
        return result
    }
}
