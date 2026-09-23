import Foundation

/// Reduce Motion and the parent-facing calm mode, applied as a transform
/// over an effect's options when it starts — never as branches inside the
/// evaluator.
public struct EffectPolicy: Equatable, Sendable {
    /// Mirrors the system Reduce Motion setting.
    public var reduceMotion: Bool
    /// Parent setting: same policy as Reduce Motion plus a global damping.
    public var calmMode: Bool
    /// Multiplies every intensity when calm mode is on.
    public var calmIntensityMultiplier: Double

    public init(reduceMotion: Bool = false, calmMode: Bool = false, calmIntensityMultiplier: Double = 0.6) {
        self.reduceMotion = reduceMotion
        self.calmMode = calmMode
        self.calmIntensityMultiplier = calmIntensityMultiplier
    }

    public static let standard = EffectPolicy()

    public var isCalm: Bool { reduceMotion || calmMode }

    /// The options to actually run with, or `nil` to drop the effect.
    public func adjusted(_ name: EffectName, _ options: EffectOptions) -> EffectOptions? {
        guard isCalm else { return options }
        var result = options
        switch name {
        case .shake, .hop, .spin, .float:
            return nil
        case .pulse, .wobble:
            result.intensity = min(result.intensity, 0.3)
        case .fadeIn, .fadeOut, .glow, .tint:
            break  // carry story meaning; run at full
        case .sparkle, .hearts:
            result.intensity = min(result.intensity, 0.4)
        }
        if calmMode { result.intensity *= calmIntensityMultiplier }
        return result
    }

    /// The canvas-effect options to actually run with, or `nil` to drop the
    /// effect. The ones that fall or drift (rain, snow, confetti…) are
    /// damped, `warp` — the whole sky rushing past — is dropped, and the
    /// slow washes of light carry story meaning and run in full.
    public func adjusted(_ name: CanvasEffectName, _ options: CanvasEffectOptions) -> CanvasEffectOptions? {
        guard isCalm else { return options }
        var result = options
        switch name {
        case .rain, .snow, .wind, .fireflies, .leaves, .rainywindow, .confetti, .bubbles, .shootingstars:
            result.intensity = min(result.intensity, 0.4)
        case .warp:
            return nil
        case .fog, .sunshine, .rainbow, .night, .sunset, .clouds, .dimlight, .windowlight, .firelight,
            .nebula:
            break
        }
        if calmMode { result.intensity *= calmIntensityMultiplier }
        return result
    }
}
