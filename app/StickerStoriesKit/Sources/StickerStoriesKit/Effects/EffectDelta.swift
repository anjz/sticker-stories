import Foundation

/// Where an effect pivots, as a fraction of the sticker's rendered size with
/// a **top-left origin and y down** (`[0.5, 1.0]` is bottom-centre). This is
/// the content-facing convention; SpriteKit's bottom-left/y-up convention is
/// converted to at the rendering boundary (`EffectTransformMath`).
public struct EffectAnchor: Equatable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = EffectAnchor(x: 0.5, y: 0.5)
    public static let bottomCenter = EffectAnchor(x: 0.5, y: 1.0)
}

/// What one or more effects contribute on top of the child's placement at a
/// given time. Effects never assign absolute values (P1); the applier does
/// `placedScale × scaleMul`, `placedRotation + rotationAdd`, and so on.
public struct EffectDelta: Equatable, Sendable {
    /// Compose: multiply.
    public var opacityMul: Double = 1
    /// Compose: multiply.
    public var scaleMul: Double = 1
    /// Degrees, positive clockwise on screen. Compose: add.
    public var rotationAdd: Double = 0
    /// In multiples of the sticker's own rendered width. Compose: add.
    public var offsetXSelf: Double = 0
    /// In multiples of the sticker's own rendered height, positive **down**
    /// (content convention). Compose: add.
    public var offsetYSelf: Double = 0
    /// 0...1 bloom strength. Compose: max.
    public var glow: Double = 0
    /// 0...1 colour wash strength. Compose: max.
    public var tintAmount: Double = 0
    /// Last started wins.
    public var glowColor: RGBA? = nil
    /// Last started wins.
    public var tintColor: RGBA? = nil
    /// Pivot for rotation and scale. Conflicts resolve to the later-started effect.
    public var anchor: EffectAnchor = .center

    public init() {}

    public static let identity = EffectDelta()

    /// True when applying this delta would change nothing visible.
    public func isIdentity(tolerance: Double = 1e-9) -> Bool {
        abs(opacityMul - 1) <= tolerance && abs(scaleMul - 1) <= tolerance
            && abs(rotationAdd) <= tolerance && abs(offsetXSelf) <= tolerance
            && abs(offsetYSelf) <= tolerance && glow <= tolerance && tintAmount <= tolerance
    }

    /// Composes `other` (started later) on top of `self`, per the rules on
    /// each field.
    public func combined(with other: EffectDelta) -> EffectDelta {
        var result = self
        result.opacityMul *= other.opacityMul
        result.scaleMul *= other.scaleMul
        result.rotationAdd += other.rotationAdd
        result.offsetXSelf += other.offsetXSelf
        result.offsetYSelf += other.offsetYSelf
        result.glow = max(glow, other.glow)
        result.tintAmount = max(tintAmount, other.tintAmount)
        if other.glowColor != nil { result.glowColor = other.glowColor }
        if other.tintColor != nil { result.tintColor = other.tintColor }
        result.anchor = other.anchor
        return result
    }

    /// Blends this delta toward identity: `amount` 0 = unchanged, 1 = identity.
    /// Used to ease a stopped effect back to the child's placement.
    public func blendedTowardIdentity(_ amount: Double) -> EffectDelta {
        let keep = 1 - amount.clamped(to: 0...1)
        var result = self
        result.opacityMul = 1 + (opacityMul - 1) * keep
        result.scaleMul = 1 + (scaleMul - 1) * keep
        result.rotationAdd = rotationAdd * keep
        result.offsetXSelf = offsetXSelf * keep
        result.offsetYSelf = offsetYSelf * keep
        result.glow = glow * keep
        result.tintAmount = tintAmount * keep
        return result
    }
}
