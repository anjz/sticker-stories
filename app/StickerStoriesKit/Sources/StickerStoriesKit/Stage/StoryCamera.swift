import Foundation

/// Where the view looks while a story plays in a window narrower than the
/// art (portrait, Split View, a narrow phone; `docs/architecture.md`, 3a):
/// the story plays on the whole art, the same at every window size, and
/// the camera glides to keep what is happening in view — whoever acts,
/// changes face or moves now, or is about to. It moves only as far as it
/// must to take that in, and when that is more than the window shows it
/// goes with whatever began last. After the child pans by hand it leaves
/// the view to them for a while. Pure: the scene asks it every frame.
public enum StoryCamera {
    /// Something a sticker does in the story: an action, a face, an
    /// effect (every sticker of that kind), or a move (one sticker).
    public struct Beat: Equatable, Sendable {
        public var stickerID: String
        /// The one sticker that moves; nil: every sticker of the kind.
        public var instance: UUID?
        public var from: TimeInterval
        public var to: TimeInterval

        public init(stickerID: String, instance: UUID? = nil, from: TimeInterval, to: TimeInterval) {
            self.stickerID = stickerID
            self.instance = instance
            self.from = from
            self.to = max(to, from)
        }
    }

    /// What the camera should show: a span across the world, and when
    /// the beat it belongs to began (the latest wins when not all fit).
    public struct Focus: Equatable, Sendable {
        public var minX: Double
        public var maxX: Double
        public var since: TimeInterval

        public init(minX: Double, maxX: Double, since: TimeInterval) {
            self.minX = min(minX, maxX)
            self.maxX = max(minX, maxX)
            self.since = since
        }
    }

    /// Seconds before a beat the camera sets off for it, so it is there
    /// as the beat begins.
    public static let lead: TimeInterval = 0.8
    /// Seconds after a beat it stays in focus.
    public static let linger: TimeInterval = 0.6
    /// Seconds after the child last panned during which the camera stays
    /// where they left it.
    public static let handsOff: TimeInterval = 4
    /// A face or an effect holds the camera this long (a face has no
    /// duration; it stays until the next).
    static let glance: TimeInterval = 1.5
    /// How long an effect without a duration of its own holds it.
    static let effectSpan: TimeInterval = 2
    /// How quickly the camera closes on where it should be (seconds to
    /// cover about two thirds of the way), and how fast it may go, in
    /// window widths a second: slow enough for a four-year-old to follow.
    static let easing: TimeInterval = 0.45
    static let topSpeed = 0.9

    /// The beats of the story's cues: its actions (held back for moves,
    /// as they play), faces and effects. Moves come from the stage's plan.
    /// - Parameter duration: how long an action plays, when known.
    public static func beats(
        live: [LiveAnimationTrigger], duration: (LiveAnimationKey) -> TimeInterval?, faces: [ExpressionTrigger],
        effects: [EffectTrigger]
    ) -> [Beat] {
        var out: [Beat] = []
        for trigger in live {
            let length = duration(LiveAnimationKey(stickerID: trigger.stickerID, animationID: trigger.animationID)) ?? 2
            out.append(Beat(stickerID: trigger.stickerID, from: trigger.at, to: trigger.at + min(length, 6)))
        }
        // Going back to its own face is not news.
        for face in faces where face.expression != ExpressionTrigger.normal {
            out.append(Beat(stickerID: face.stickerID, from: face.at, to: face.at + glance))
        }
        for effect in effects {
            let length = min(effect.options.duration ?? effectSpan, 6)
            out.append(Beat(stickerID: effect.stickerID, from: effect.at, to: effect.at + length))
        }
        return out.sorted { $0.from < $1.from }
    }

    /// The beats the camera follows at `time`: from `lead` before each
    /// until `linger` after.
    public static func current(_ beats: [Beat], at time: TimeInterval) -> [Beat] {
        beats.filter { time >= $0.from - lead && time <= $0.to + linger }
    }

    /// Where the camera's centre should be, from where it is: the least
    /// move that puts every focus inside the window, `margin` in from its
    /// sides; when they do not all fit, the latest first and then as many
    /// of the others as still fit, latest first. Then as much of the rest
    /// of the `cast` (the other stickers on show) as still fits, nearest
    /// first; and nobody is left cut by the window's edge when the camera
    /// can help it: a sticker it cannot take in whole it leaves wholly
    /// out, if that keeps what it must show in view. On the world always.
    /// - Parameters:
    ///   - center: the camera's centre now; `view`, the window's width;
    ///     `world`, the art's span. All in world points.
    public static func target(
        center: Double, view: Double, world: ClosedRange<Double>, focus: [Focus], cast: [Focus] = [], margin: Double
    ) -> Double {
        let half = view / 2
        guard world.upperBound - world.lowerBound > view else { return (world.lowerBound + world.upperBound) / 2 }
        // Where the centre may go: on the world.
        let first = world.lowerBound + half, last = world.upperBound - half
        func onWorld(_ x: Double) -> Double { min(max(x, first), last) }
        let room = max(view - 2 * margin, 0)
        var span: (lo: Double, hi: Double)?
        for f in focus.sorted(by: { $0.since > $1.since }) {
            guard let s = span else {
                span = (f.minX, f.maxX)
                continue
            }
            let l = min(s.lo, f.minX), h = max(s.hi, f.maxX)
            if h - l <= room { span = (l, h) }
        }
        guard var s = span else { return onWorld(center) }
        if s.hi - s.lo > room { return onWorld((s.lo + s.hi) / 2) }
        // The rest of the cast that still fits, nearest first.
        let middle = (s.lo + s.hi) / 2
        for f in cast.sorted(by: { abs(($0.minX + $0.maxX) / 2 - middle) < abs(($1.minX + $1.maxX) / 2 - middle) }) {
            let l = min(s.lo, f.minX), h = max(s.hi, f.maxX)
            if h - l <= room { s = (l, h) }
        }
        // As little as it can: just enough that both ends are in.
        let lo = max(first, s.hi + margin - half), hi = min(last, s.lo - margin + half)
        // Against the art's edge there is no room for the margin: as near as it gets.
        guard lo <= hi else { return onWorld(min(max(center, s.hi + margin - half), s.lo - margin + half)) }
        var x = min(max(center, lo), hi)
        // Nobody cut by the edge: whoever straddles one goes wholly out,
        // the least way that keeps the rest in.
        for _ in 0..<3 {
            var moved = false
            for f in focus + cast {
                let left = x - half, right = x + half
                let cutLeft = f.minX < left && f.maxX > left, cutRight = f.minX < right && f.maxX > right
                guard cutLeft || cutRight else { continue }
                let options = [f.maxX + half, f.minX - half].filter { $0 >= lo && $0 <= hi }
                guard let best = options.min(by: { abs($0 - x) < abs($1 - x) }) else { continue }
                x = best
                moved = true
            }
            if !moved { break }
        }
        return x
    }

    /// The camera's centre a frame (`dt` seconds) later on its way to
    /// `target`: easing in on it, never faster than `topSpeed`.
    public static func step(center: Double, toward target: Double, dt: TimeInterval, view: Double) -> Double {
        let gap = target - center
        guard abs(gap) > 0.5, dt > 0 else { return target }
        let eased = gap * (1 - exp(-dt / easing))
        let limit = topSpeed * view * dt
        return center + min(max(eased, -limit), limit)
    }
}
