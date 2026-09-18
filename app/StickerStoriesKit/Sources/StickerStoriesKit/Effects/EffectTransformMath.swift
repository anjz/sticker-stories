import Foundation

/// The child's placement of one sticker, in SpriteKit terms (points, radians
/// counterclockwise, y up). The base that effects are deltas on (P1).
public struct StickerPlacement: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Radians, counterclockwise (SpriteKit `zRotation`).
    public var rotation: Double
    public var scale: Double
    public var alpha: Double

    public init(x: Double, y: Double, rotation: Double, scale: Double, alpha: Double = 1) {
        self.x = x
        self.y = y
        self.rotation = rotation
        self.scale = scale
        self.alpha = alpha
    }
}

/// A placement with an effect delta folded in — what the applier writes.
public struct ComposedPlacement: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var rotation: Double
    public var scale: Double
    public var alpha: Double
    public var tintAmount: Double
    public var tintColor: RGBA?
    public var glow: Double
    public var glowColor: RGBA?

    public var placement: StickerPlacement {
        StickerPlacement(x: x, y: y, rotation: rotation, scale: scale, alpha: alpha)
    }
}

/// The boundary between the content conventions (degrees clockwise, y down,
/// top-left anchors, self-relative offsets) and SpriteKit's. Pure maths,
/// unit-tested, because getting the anchor flip wrong turns a wobble into a
/// spin.
public enum EffectTransformMath {
    /// The anchor as a node-local offset from the sprite's centre, in y-up
    /// unscaled points. `[0.5, 1.0]` (bottom-centre) → `(0, -h/2)`.
    public static func pivot(for anchor: EffectAnchor, width: Double, height: Double) -> (x: Double, y: Double) {
        ((anchor.x - 0.5) * width, (0.5 - anchor.y) * height)
    }

    /// Applies `delta` to `placement` without touching the sprite's own
    /// `anchorPoint`: rotation and scale happen about the anchor by moving
    /// the node so that the pivot's world position stays fixed; offsets are
    /// in multiples of the rendered size (which includes the child's scale)
    /// and in screen space.
    public static func compose(
        _ placement: StickerPlacement, with delta: EffectDelta,
        unscaledWidth: Double, unscaledHeight: Double
    ) -> ComposedPlacement {
        let scale = placement.scale * delta.scaleMul
        // Content degrees are clockwise on screen; zRotation is counterclockwise.
        let rotation = placement.rotation - delta.rotationAdd * .pi / 180

        let pivot = pivot(for: delta.anchor, width: unscaledWidth, height: unscaledHeight)
        let before = rotated(pivot, by: placement.rotation, scale: placement.scale)
        let after = rotated(pivot, by: rotation, scale: scale)

        let renderedWidth = unscaledWidth * placement.scale
        let renderedHeight = unscaledHeight * placement.scale
        let x = placement.x + (before.x - after.x) + delta.offsetXSelf * renderedWidth
        let y = placement.y + (before.y - after.y) - delta.offsetYSelf * renderedHeight  // content y is down

        return ComposedPlacement(
            x: x, y: y, rotation: rotation, scale: scale,
            alpha: placement.alpha * delta.opacityMul,
            tintAmount: delta.tintAmount, tintColor: delta.tintColor,
            glow: delta.glow, glowColor: delta.glowColor)
    }

    private static func rotated(_ p: (x: Double, y: Double), by angle: Double, scale: Double) -> (x: Double, y: Double) {
        let c = cos(angle), s = sin(angle)
        return ((p.x * c - p.y * s) * scale, (p.x * s + p.y * c) * scale)
    }
}
