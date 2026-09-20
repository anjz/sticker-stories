import Foundation

/// One effect's fixed shape: what it animates, its default duration, its
/// pivot and its easing. Content only ever tunes `intensity`, `duration`,
/// `repeat`, `color` and `hold` (see `EffectOptions`); everything here is
/// deliberately not exposed.
///
/// Every cycle is closed (P2): `curve(0, i) == curve(1, i) == identity` for
/// all `i`, except the two one-way fades. `curve(phase, 0)` is identity for
/// every effect (acceptance criterion 4).
public struct EffectDefinition: Sendable {
    public let name: EffectName
    public let defaultDuration: TimeInterval
    public let anchor: EffectAnchor
    public let defaultColor: RGBA?
    /// A one-line, authoring-facing description (mirrored in `docs/effects/effects.json`).
    public let summary: String

    /// `phase` is 0...1 within one cycle; `cycleDuration` lets time-based
    /// shapes (shake's tremble period) stay in real seconds.
    let curve: @Sendable (_ phase: Double, _ intensity: Double, _ cycleDuration: TimeInterval) -> EffectDelta

    /// Evaluates one cycle at `phase` with the pivot and default colour filled in.
    public func delta(atPhase phase: Double, intensity: Double, cycleDuration: TimeInterval) -> EffectDelta {
        var delta = curve(phase.clamped(to: 0...1), intensity.clamped(to: 0...1), cycleDuration)
        delta.anchor = anchor
        return delta
    }

    public static func definition(for name: EffectName) -> EffectDefinition {
        library[name]!
    }

    // MARK: - The library

    public static let library: [EffectName: EffectDefinition] = {
        var all: [EffectName: EffectDefinition] = [:]
        for definition in definitions { all[definition.name] = definition }
        precondition(all.count == EffectName.allCases.count, "every effect needs a definition")
        return all
    }()

    private static let definitions: [EffectDefinition] = [
        // MARK: Motion

        EffectDefinition(
            name: .pulse, defaultDuration: 0.5, anchor: .center, defaultColor: nil,
            summary: "One gentle size beat. The universal \"look at this one\"."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.scaleMul = 1 + 0.15 * i * Easing.upAndDown(phase, Easing.inOut)
            return d
        },

        EffectDefinition(
            name: .wobble, defaultDuration: 0.6, anchor: .bottomCenter, defaultColor: nil,
            summary: "Tilts side to side around its base. The default \"this thing is reacting\"."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.rotationAdd = Easing.keyframes([(0, 0), (1.0 / 3.0, 8), (2.0 / 3.0, -8), (1, 0)], at: phase, Easing.inOut) * i
            return d
        },

        EffectDefinition(
            name: .shake, defaultDuration: 0.5, anchor: .center, defaultColor: nil,
            summary: "Fast, small horizontal tremble. Fear, cold, excitement."
        ) { phase, i, cycleDuration in
            var d = EffectDelta()
            // ~0.08s per tremble; an integer number of trembles so the cycle
            // ends at 0, windowed so it starts and stops softly.
            let trembles = max(1, (cycleDuration / 0.08).rounded())
            d.offsetXSelf = 0.04 * i * sin(2 * .pi * trembles * phase) * sin(.pi * phase)
            return d
        },

        EffectDefinition(
            name: .hop, defaultDuration: 0.6, anchor: .bottomCenter, defaultColor: nil,
            summary: "One small arc up and back down. The most charming one in the list."
        ) { phase, i, _ in
            var d = EffectDelta()
            let height = phase < 0.5 ? Easing.out(phase * 2) : 1 - Easing.in(phase * 2 - 1)
            d.offsetYSelf = -0.5 * i * height  // negative = up (content convention)
            return d
        },

        EffectDefinition(
            name: .spin, defaultDuration: 0.9, anchor: .center, defaultColor: nil,
            summary: "One full clockwise rotation about the centre."
        ) { phase, i, _ in
            var d = EffectDelta()
            // A spin is always exactly one turn; intensity only switches it off
            // at 0 (a partial turn would not be a closed cycle).
            d.rotationAdd = i > 0 ? 360 * Easing.inOut(phase) : 0
            return d
        },

        EffectDefinition(
            name: .float, defaultDuration: 3.0, anchor: .center, defaultColor: nil,
            summary: "Very slow vertical bob. Built for loop."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.offsetYSelf = -0.06 * i * sin(2 * .pi * phase)  // up first
            return d
        },

        // MARK: Opacity and colour

        EffectDefinition(
            name: .fadeIn, defaultDuration: 0.6, anchor: .center, defaultColor: nil,
            summary: "Appears from nothing. One-way."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.opacityMul = 1 - i * (1 - Easing.out(phase))
            return d
        },

        EffectDefinition(
            name: .fadeOut, defaultDuration: 0.6, anchor: .center, defaultColor: nil,
            summary: "Fades away. One-way."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.opacityMul = 1 - i * Easing.in(phase)
            return d
        },

        EffectDefinition(
            name: .glow, defaultDuration: 1.0, anchor: .center, defaultColor: RGBA(hex: "#FFF3C4"),
            summary: "A soft bloom rises around the sticker and falls away. Reads as magic."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.glow = 0.8 * i * Easing.upAndDown(phase, Easing.inOut)
            return d
        },

        EffectDefinition(
            name: .tint, defaultDuration: 0.8, anchor: .center, defaultColor: nil,
            summary: "A colour washes over the sticker and drains away. White + short duration = a flash."
        ) { phase, i, _ in
            var d = EffectDelta()
            d.tintAmount = 0.5 * i * Easing.upAndDown(phase, Easing.inOut)
            return d
        },

        // MARK: Particles (the delta is identity; emission is handled by the emitter coordinator)

        EffectDefinition(
            name: .sparkle, defaultDuration: 1.0, anchor: EffectAnchor(x: 0.5, y: 0.35),
            defaultColor: RGBA(hex: "#FFD166"),
            summary: "A small shower of twinkles above the sticker. The generic magic/delight beat."
        ) { _, _, _ in EffectDelta() },

        EffectDefinition(
            name: .hearts, defaultDuration: 1.2, anchor: EffectAnchor(x: 0.5, y: 0.2), defaultColor: nil,
            summary: "A few hearts drift up. Affection, a hug, a friend."
        ) { _, _, _ in EffectDelta() },
    ]
}

/// The few easing shapes the library uses. Fixed per effect, never content-tunable.
enum Easing {
    static func `in`(_ t: Double) -> Double { t * t }
    static func out(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }
    static func inOut(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

    /// 0 → 1 → 0 over the phase, eased on the way up and down.
    static func upAndDown(_ phase: Double, _ ease: (Double) -> Double) -> Double {
        phase < 0.5 ? ease(phase * 2) : ease(2 - phase * 2)
    }

    /// Piecewise interpolation through `(phase, value)` points, eased per segment.
    static func keyframes(_ points: [(Double, Double)], at phase: Double, _ ease: (Double) -> Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if phase <= first.0 { return first.1 }
        if phase >= last.0 { return last.1 }
        for index in 1..<points.count where phase <= points[index].0 {
            let (p0, v0) = points[index - 1]
            let (p1, v1) = points[index]
            let local = p1 > p0 ? (phase - p0) / (p1 - p0) : 1
            return v0 + (v1 - v0) * ease(local)
        }
        return last.1
    }
}
