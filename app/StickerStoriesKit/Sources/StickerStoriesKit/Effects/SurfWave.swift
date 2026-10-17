import Foundation

/// `surf-wave`: a wave behind a sticker in the water, rising at its
/// waterline (the stage sinks a floating puppet so that its waterline lies
/// where its feet were, `StageWorld.afloat`). Only a sticker in water when
/// the wave is cued gets one (`rises(at:in:)`); on land the cue draws
/// nothing. Over one cycle it swells, rolls forward along with the
/// sticker, its lip pitches forward in a short hook and crashes down,
/// bursting into foam and spray, and the wave collapses into a spreading
/// band of whitewater that fizzles out — nothing in it ever plays
/// backwards. A low foam line runs in front of the sticker's base so it
/// sits in the wave rather than on top of it.
///
/// Everything about it at a moment is a pure function of the timeline
/// (the effect's start, its options, the time), like the canvas painters,
/// so a seek or a replay shows exactly the same wave. The app draws what
/// `shape` returns (`SurfWaveCoordinator`); nothing here knows SpriteKit.
///
/// Units: the sticker's drawn height at its depth. `x` runs forward —
/// always left to right on screen, the way the painted waves roll, so the
/// sticker rides ahead of the break on its right — from its waterline
/// point; `y` runs up from it. The wave is level with the sea whatever the sticker does: it
/// never turns, tilts or flips with it. The body and the foam over it are drawn behind the
/// sticker, `frontFoam` in front of it, so the wave never covers it.
public enum SurfWave {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// A soft round of foam or a drop of spray.
    public struct Blob: Equatable, Sendable {
        public var x: Double
        public var y: Double
        /// Its vertical radius.
        public var radius: Double
        /// Its width over its height: foam lies flat on the water.
        public var stretch: Double
        public var alpha: Double
    }

    /// Where the wave is in its cycle, and how strong.
    public struct Frame: Equatable, Sendable {
        /// 0…1 within the cycle.
        public var phase: Double
        /// Seconds into the cycle (the foam's bob and the spray's flight
        /// run in real time).
        public var seconds: Double
        public var cycleDuration: Double
        public var intensity: Double
        /// The whole wave's opacity: 0 at the start and the end of a
        /// cycle, eased to 0 when the effect is stopped early.
        public var opacity: Double
    }

    /// What to draw at one moment, back to front.
    public struct Shape: Equatable, Sendable {
        /// The water: a closed outline — a long rounded back, a round
        /// shoulder, the lip pitching forward in a short hook and the face
        /// under it sweeping down to the front foot. Empty when there is
        /// nothing to draw.
        public var body: [Point]
        /// How much of the water shows: it fades under the whitewater as
        /// the wave collapses.
        public var bodyOpacity: Double
        /// The crest's height, for the body's shading.
        public var height: Double
        /// The tip of the lip.
        public var lipTip: Point?
        /// One or two faint highlights following the water's curves.
        public var streaks: [Blob]
        /// Lighter water in the lip, catching the light.
        public var glow: [Blob]
        /// Deeper water under the lip: soft rounds, never an edge.
        public var shade: [Blob]
        /// Foam: the puffy lip, the burst as it crashes, the whitewater it
        /// collapses into — behind the sticker.
        public var foam: [Blob]
        /// Spray: thrown forward and up as the lip crashes, behind the sticker.
        public var spray: [Blob]
        /// The low foam line in front of the sticker's base.
        public var frontFoam: [Blob]
        public var opacity: Double

        public static let none = Shape(
            body: [], bodyOpacity: 0, height: 0, lipTip: nil, streaks: [], glow: [], shade: [], foam: [], spray: [],
            frontFoam: [], opacity: 0)
    }

    // MARK: - Where

    /// Whether a sticker at `p` on the stage is out in open water — on the
    /// water and as far out from its edge as afloat stickers rest
    /// (`StageWorld.inOpenWater`). Only then does a `surf-wave` cued on it
    /// rise. Decided once, when it is cued.
    public static func rises(at p: Vec3, in world: StageWorld) -> Bool {
        p.y < 0.01 && world.inOpenWater(p.ground)
    }

    // MARK: - The timeline

    /// The wave of a running `surf-wave` effect at `time`, or nil when it
    /// shows nothing then (not started, finished, or another effect).
    public static func frame(of effect: ActiveEffect, at time: TimeInterval) -> Frame? {
        guard effect.name == .surfWave, effect.options.intensity > 0 else { return nil }
        guard case .running(_, let phase) = EffectEvaluator.status(of: effect, at: time) else { return nil }
        var fade = 1.0
        if let stopTime = effect.stopTime, time >= stopTime {
            let ease = EffectEvaluator.easeBackDuration(of: effect, stoppingAt: stopTime)
            fade = ease > 0 ? max(0, 1 - (time - stopTime) / ease) : 0
        }
        let frame = frame(phase: phase, intensity: effect.options.intensity, cycleDuration: effect.cycleDuration)
        return Frame(
            phase: frame.phase, seconds: frame.seconds, cycleDuration: frame.cycleDuration,
            intensity: frame.intensity, opacity: frame.opacity * fade)
    }

    /// One cycle at `phase`.
    public static func frame(phase: Double, intensity: Double, cycleDuration: Double) -> Frame {
        let p = phase.clamped(to: 0...1)
        let opacity = smooth(0, 0.08, p) * (1 - smooth(0.9, 1, p))
        return Frame(
            phase: p, seconds: p * cycleDuration, cycleDuration: cycleDuration,
            intensity: intensity.clamped(to: 0...1), opacity: intensity > 0 ? opacity : 0)
    }

    // MARK: - The shape

    /// The moment the lip hits the water, in the cycle.
    static let impact = 0.6

    /// The wave for `frame` behind a drawing `aspect` (its width over its
    /// height) wide.
    public static func shape(_ frame: Frame, aspect: Double) -> Shape {
        let i = frame.intensity, p = frame.phase
        guard i > 0, frame.opacity > 0 else { return .none }
        let a = max(aspect, 0.2)
        // The crest's full height. A long, low sticker (the seal, a boat)
        // gets a wave a little taller than its height alone would give.
        let full = pow(i, 0.6) * pow(max(1, a), 0.4)
        let t = frame.seconds

        // The stages, each only ever going forward: it swells, its lip
        // pitches forward and crashes down, then the water flattens into
        // whitewater that spreads and fizzles away.
        let rise = smooth(0, 0.4, p)
        let pitch = smooth(0.28, 0.55, p)
        let crash = smooth(0.53, impact + 0.02, p)
        let collapse = smooth(impact, 0.86, p)
        let fizzle = smooth(0.78, 1, p)
        let hx = full * rise  // its size along the water: never shrinks back
        let hy = hx * (1 - 0.92 * collapse)  // its height: flattens as it collapses
        guard hx > 0.002 else { return .none }

        // The crest rides behind the sticker's back, rolling forward with
        // it; the lip crashes just behind its back.
        let cx = -0.5 * a - 0.65 * full + 0.1 * full * p
        let top = Point(x: cx, y: hy)
        let back = Point(x: cx - (0.6 + 1.7 * full) * (0.7 + 0.3 * rise), y: -0.02 * full)
        let run = top.x - back.x
        // A full, rounded back: it swells up early and rounds over into the
        // shoulder, never a straight ramp.
        let backSlope = (back, Point(x: back.x + 0.22 * run, y: 0.42 * hy), Point(x: top.x - 0.42 * run, y: hy), top)

        // The lip: from the round shoulder it throws forward and down in a
        // short hook, further and lower as it pitches, down to the water
        // as it crashes.
        let reach = hx * (0.08 + 0.36 * pitch + 0.13 * crash)
        let drop = hy * (0.05 + 0.3 * pitch + 0.6 * crash)
        let tip = Point(x: cx + reach, y: hy - drop)
        let lip = (
            top, Point(x: cx + 0.55 * reach, y: hy * (1 + 0.06 * pitch * (1 - crash))),
            Point(x: tip.x + 0.12 * hx * pitch, y: tip.y + 0.3 * drop + 0.03 * hx), tip
        )
        // Under the lip, the face sweeps down to the foot: a rounded swell
        // at first, hollowing a little under the overhang as it pitches.
        let throat = Point(x: cx + 0.25 * reach, y: hy - 0.55 * drop - 0.1 * hy * pitch)
        let frontFoot = Point(x: max(tip.x, cx + 0.2 * hx) + hx * (0.12 + 0.6 * (1 - pitch)), y: -0.02 * full)
        let face = (
            throat,
            Point(x: throat.x + 0.4 * hx * (1 - pitch) - 0.06 * hx * pitch, y: throat.y - (0.02 + 0.28 * pitch) * hy),
            Point(x: frontFoot.x - 0.4 * (frontFoot.x - throat.x), y: 0.02 * hy), frontFoot
        )
        let underside = cubic(
            tip, Point(x: tip.x - 0.03 * hx, y: tip.y + 0.08 * hy), Point(x: throat.x + 0.15 * reach, y: throat.y + 0.02 * hy),
            throat, steps: 8)
        let overhang = underside + cubic(face.0, face.1, face.2, face.3).dropFirst()
        // As the lip comes down the overhang closes smoothly into one
        // curtain from the tip to the foot — no notch as it lands.
        let curtain = cubic(
            tip, Point(x: tip.x + 0.05 * hx, y: tip.y * 0.5),
            Point(x: frontFoot.x - 0.35 * (frontFoot.x - tip.x), y: 0.02 * hy), frontFoot, steps: overhang.count - 1)
        let closing = smooth(0.42, impact, p)
        var body = cubic(backSlope.0, backSlope.1, backSlope.2, backSlope.3)
        body += cubic(lip.0, lip.1, lip.2, lip.3).dropFirst()
        body += zip(overhang, curtain).dropFirst().map { o, c in
            Point(x: o.x + (c.x - o.x) * closing, y: o.y + (c.y - o.y) * closing)
        }
        let bodyOpacity = 1 - smooth(0.66, 0.88, p)

        // Light in the lip, deeper water under it: soft rounds, no edges.
        let hooked = pitch * (1 - crash)
        var glow: [Blob] = []
        var shade: [Blob] = []
        if hooked > 0.01 {
            for point in cubic(lip.0, lip.1, lip.2, lip.3, steps: 8)[2...6] {
                glow.append(Blob(x: point.x - 0.04 * hx, y: point.y - 0.07 * hx, radius: 0.1 * hx, stretch: 1.2, alpha: 0.35 * hooked))
            }
            for point in cubic(face.0, face.1, face.2, face.3, steps: 10)[0...4] {
                shade.append(Blob(x: point.x - 0.05 * hx, y: point.y, radius: 0.13 * hx, stretch: 1.1, alpha: 0.2 * hooked))
            }
        }

        // One or two faint highlights following the curves, uneven in
        // width like a brush stroke.
        var streaks: [Blob] = []
        func highlight(_ points: ArraySlice<Point>, width: Double, alpha: Double, salt: Int) {
            let n = Double(max(points.count - 1, 1))
            for (k, point) in points.enumerated() where point.y > 0.1 * hy {
                let u = Double(k) / n
                let uneven = 0.65 + 0.35 * sin(2 * .pi * (1.7 * u + random(salt, 30)))
                streaks.append(Blob(x: point.x, y: point.y, radius: width * sin(.pi * u) * uneven, stretch: 1, alpha: alpha))
            }
        }
        if hy > 0.05 {
            let faceLine = cubic(face.0, face.1, face.2, face.3, steps: 40).map { Point(x: $0.x - 0.08 * hx, y: $0.y) }
            highlight(faceLine[6...28], width: 0.014 * full, alpha: 0.22 * (1 - collapse), salt: 1)
            let backLine = cubic(backSlope.0, backSlope.1, backSlope.2, backSlope.3, steps: 60).map {
                Point(x: $0.x + 0.03 * full, y: $0.y * 0.8)
            }
            highlight(backLine[30...54], width: 0.012 * full, alpha: 0.16 * (1 - collapse), salt: 2)
        }

        // The foam lip: puffy and lumpy along the crest and the hook, with
        // little dots breaking off near its tip; it bursts as it crashes.
        var foam: [Blob] = []
        let lipFoam = smooth(0.06, 0.35, p) * (1 - smooth(impact, impact + 0.08, p))
        if lipFoam > 0 {
            let crest = cubic(
                Point(x: top.x - 0.3 * run, y: 0.82 * hy), Point(x: top.x - 0.2 * run, y: 0.97 * hy),
                Point(x: top.x - 0.06 * run, y: hy), top, steps: 22)
            let edge = crest.map { ($0, 0.0) } + cubic(lip.0, lip.1, lip.2, lip.3, steps: 14).dropFirst().enumerated().map {
                ($0.element, Double($0.offset + 1) / 14)
            }
            for (k, (point, u)) in edge.enumerated() {
                let r = random(k, 1)
                let size = full * (0.05 + 0.03 * r) * (0.5 + 0.5 * pitch) * (k < crest.count ? 0.7 + 0.3 * Double(k) / Double(crest.count) : 0.85 + 0.3 * u)
                let bob = 0.01 * full * sin(2 * .pi * (t / (1.1 + 0.4 * r) + r))
                foam.append(Blob(
                    x: point.x + 0.015 * full * (random(k, 2) - 0.5), y: point.y + bob - 0.2 * size,
                    radius: size, stretch: 1.15, alpha: lipFoam * (0.8 + 0.2 * random(k, 3))))
                if k % 2 == 0 {
                    foam.append(Blob(
                        x: point.x + 0.03 * full * (random(k, 20) - 0.5), y: point.y + 0.3 * size + bob,
                        radius: 0.6 * size, stretch: 1, alpha: lipFoam * 0.9))
                }
            }
            // Dots breaking off the lip, thrown ahead of it.
            for k in 0..<8 {
                let r = random(k, 21)
                let beat = (t / (1.4 + r) + r).truncatingRemainder(dividingBy: 1)
                let from = cubic(lip.0, lip.1, lip.2, lip.3, steps: 10)[4 + k % 6]
                foam.append(Blob(
                    x: from.x + (0.03 + 0.12 * beat) * full, y: from.y + (0.05 * beat - 0.08 * beat * beat) * full,
                    radius: full * (0.01 + 0.012 * random(k, 23)), stretch: 1,
                    alpha: lipFoam * pitch * sin(.pi * beat) * 0.9))
            }
        }

        // The crash: where the lip hits the water, a quick burst of white
        // foam thrown forward and up, puffing out and slowing as it goes.
        let splash = Point(x: cx + 0.57 * hx + 0.1 * full * (p - impact), y: 0.08 * full * rise)
        let age = (p - impact) * frame.cycleDuration
        var spray: [Blob] = []
        if age > 0 {
            let puffs = 20 + Int((8 * i).rounded())
            for k in 0..<puffs {
                let r = random(k, 40)
                let angle = (30 + 120 * random(k, 41)) * .pi / 180  // up, forward and back
                let speed = full * (1.5 + 1.6 * random(k, 42))
                let out = (1 - exp(-5 * age)) / 5
                let life = 0.8 + 0.5 * random(k, 43)
                guard age < life else { continue }
                foam.append(Blob(
                    x: splash.x + cos(angle) * speed * out,
                    y: splash.y + sin(angle) * speed * out + 0.2 * full * (1 - exp(-4 * age)) - 0.15 * full * age * age,
                    radius: full * (0.06 + 0.07 * r) * (0.5 + 0.7 * (1 - exp(-6 * age))), stretch: 1.1,
                    alpha: 1 - smooth(0.3 * life, life, age)))
            }
            // Spray thrown forward and up, arcing down.
            let drops = 8 + Int((12 * i).rounded())
            for k in 0..<drops {
                let delay = 0.12 * random(k, 8)
                let life = 0.8 + 0.4 * random(k, 9)
                let flight = age - delay
                guard flight > 0, flight < life else { continue }
                let speed = full * (0.9 + 0.6 * random(k, 10))
                let angle = (25 + 85 * random(k, 11)) * .pi / 180
                spray.append(Blob(
                    x: splash.x + speed * cos(angle) * flight,
                    y: splash.y + speed * sin(angle) * flight - full * flight * flight,
                    radius: full * (0.018 + 0.017 * random(k, 13)), stretch: 1,
                    alpha: 0.95 * (1 - smooth(0.5, 1, flight / life))))
            }
        }

        // The whitewater: the collapsed wave as a churning band of foam
        // that spreads both ways along the water and fizzles out.
        let whitewater = smooth(impact - 0.02, impact + 0.06, p) * (1 - fizzle)
        if whitewater > 0 {
            let spread = smooth(impact, 1, p)
            let from = cx - (0.25 + 0.9 * spread) * full, to = splash.x + (0.15 + 0.45 * spread) * full
            for k in 0..<26 {
                let u = (Double(k) + random(k, 50)) / 26
                let r = random(k, 51)
                let churn = sin(2 * .pi * (t / (0.7 + 0.4 * r) + random(k, 52)))
                let heap = (0.05 + 0.28 * (1 - spread) * random(k, 53)) * full * sin(.pi * u)
                foam.append(Blob(
                    x: from + (to - from) * u, y: heap + 0.015 * full * churn,
                    radius: full * (0.05 + 0.05 * r) * (1 - 0.5 * fizzle) * (0.85 + 0.15 * churn) * (0.5 + 0.5 * sin(.pi * u)),
                    stretch: 1.6, alpha: whitewater * (0.75 + 0.25 * random(k, 54))))
            }
            // Fizz: little bubbles popping in and out over it.
            for k in 0..<14 {
                let beat = (t / (0.6 + 0.5 * random(k, 55)) + random(k, 56)).truncatingRemainder(dividingBy: 1)
                let u = random(k, 57)
                foam.append(Blob(
                    x: from + (to - from) * u, y: (0.02 + 0.12 * random(k, 58) * (1 - spread)) * full + 0.03 * full * beat,
                    radius: full * (0.008 + 0.01 * random(k, 59)), stretch: 1, alpha: whitewater * sin(.pi * beat)))
            }
        }

        // A low foam line in front of the sticker's base: thin whatever the
        // wave's size, so it only ever overlaps the very bottom of it.
        var frontFoam: [Blob] = []
        let line = smooth(0.06, 0.32, p) * (1 - smooth(0.85, 1, p)) * min(1, i * 2.5)
        if line > 0 {
            let from = cx + 0.3 * hx, to = 0.5 * a + 0.1
            let count = 10 + Int((a * 12).rounded())
            for k in 0..<count {
                let u = (Double(k) + 0.6 * random(k, 14)) / Double(count)
                let r = random(k, 15)
                let ends = min(1, 4 * min(u, 1 - u) + 0.3)
                frontFoam.append(Blob(
                    x: from + (to - from) * u,
                    y: -0.006 + 0.006 * sin(2 * .pi * (t / (1.4 + 0.5 * r) + r)),
                    radius: (0.028 + 0.02 * r) * ends, stretch: 2.2,
                    alpha: line * (0.8 + 0.2 * random(k, 16))))
            }
        }

        return Shape(
            body: bodyOpacity > 0 ? body : [], bodyOpacity: bodyOpacity, height: hy, lipTip: tip,
            streaks: streaks, glow: glow, shade: shade, foam: foam, spray: spray, frontFoam: frontFoam,
            opacity: frame.opacity)
    }

    // MARK: - Helpers

    /// Smoothstep from `a` to `b`.
    public static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = ((x - a) / (b - a)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    /// A cubic Bézier sampled at `steps` + 1 points, both ends included.
    static func cubic(_ p0: Point, _ p1: Point, _ p2: Point, _ p3: Point, steps: Int = 16) -> [Point] {
        (0...steps).map { k in
            let t = Double(k) / Double(steps), m = 1 - t
            let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, d = t * t * t
            return Point(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
        }
    }

    /// A fixed pseudo-random number in 0..<1 for (`index`, `salt`): the
    /// same on every run, so the foam and the spray replay exactly.
    public static func random(_ index: Int, _ salt: Int) -> Double {
        var z = UInt64(truncatingIfNeeded: index &* 0x9E37_79B9 &+ salt &* 0x85EB_CA6B) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
