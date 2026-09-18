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
        case .shake, .hop, .spin, .float, .sway, .blink:
            return nil
        case .pulse, .wobble:
            result.intensity = min(result.intensity, 0.3)
        case .fadeIn, .fadeOut, .glow, .tint:
            break  // carry story meaning; run at full
        case .sparkle, .puff, .hearts:
            result.intensity = min(result.intensity, 0.4)
        }
        if calmMode { result.intensity *= calmIntensityMultiplier }
        return result
    }
}
