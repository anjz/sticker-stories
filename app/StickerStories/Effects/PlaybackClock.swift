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
    /// How fast the narration plays (the developer story gallery plays it
    /// at 2× and 3×): the interpolation between resyncs runs at this rate.
    private let rate: () -> Double
    private var anchorValue: TimeInterval?
    private var anchorHost: CFTimeInterval = 0
    private var lastReturned: TimeInterval = 0
    private var isPaused = false
    private var syntheticStart: CFTimeInterval?

    /// - Parameters:
    ///   - rate: how many narration seconds pass per real second (1 normally).
    ///   - source: seconds into the narration, or `nil` when unknown.
    init(rate: @escaping () -> Double = { 1 }, source: @escaping () -> TimeInterval?) {
        self.rate = rate
        self.source = source
    }

    func now() -> TimeInterval {
        let host = CACurrentMediaTime()
        let rate = max(rate(), 0.01)
        guard let value = source() else {
            if syntheticStart == nil { syntheticStart = host - lastReturned / rate }
            return advance(to: (host - syntheticStart!) * rate)
        }
        syntheticStart = nil

        guard let anchor = anchorValue else {
            anchorValue = value
            anchorHost = host
            return advance(to: value)
        }

        let predicted = isPaused ? lastReturned : anchor + (host - anchorHost) * rate
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
