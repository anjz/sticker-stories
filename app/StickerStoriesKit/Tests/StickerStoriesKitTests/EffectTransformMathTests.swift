import Foundation
import Testing

@testable import StickerStoriesKit

struct EffectTransformMathTests {
    private let placed = StickerPlacement(x: 300, y: 200, rotation: 20 * .pi / 180, scale: 1.7)
    private let w = 100.0, h = 120.0

    // Criterion 1 (applier half): identity composes to exactly the placement.
    @Test func identityLeavesPlacementExactlyAlone() {
        let composed = EffectTransformMath.compose(placed, with: .identity, unscaledWidth: w, unscaledHeight: h)
        #expect(composed.placement == placed)
        #expect(composed.scale == 1.7 && composed.rotation == placed.rotation)
    }

    // The anchor flip: content [0.5, 1.0] is bottom-centre → SpriteKit (0, −h/2).
    @Test func anchorConversionFlipsY() {
        let p = EffectTransformMath.pivot(for: .bottomCenter, width: w, height: h)
        #expect(p.x == 0 && p.y == -60)
        let c = EffectTransformMath.pivot(for: .center, width: w, height: h)
        #expect(c.x == 0 && c.y == 0)
        let sparkle = EffectTransformMath.pivot(for: EffectAnchor(x: 0.5, y: 0.35), width: w, height: h)
        #expect(sparkle.y > 0)  // above the centre
    }

    /// World position of a node-local point under a placement.
    private func world(_ local: (x: Double, y: Double), _ p: StickerPlacement) -> (Double, Double) {
        let c = cos(p.rotation), s = sin(p.rotation)
        return (p.x + (local.x * c - local.y * s) * p.scale, p.y + (local.x * s + local.y * c) * p.scale)
    }

    // A wobble pivots about the base: the bottom-centre point must not move.
    @Test func wobbleKeepsBottomCentreFixed() {
        var delta = EffectDelta()
        delta.rotationAdd = 8
        delta.anchor = .bottomCenter
        let composed = EffectTransformMath.compose(placed, with: delta, unscaledWidth: w, unscaledHeight: h)
        let pivot = EffectTransformMath.pivot(for: .bottomCenter, width: w, height: h)
        let before = world(pivot, placed)
        let after = world(pivot, composed.placement)
        #expect(abs(before.0 - after.0) < 1e-9 && abs(before.1 - after.1) < 1e-9)
        #expect(composed.x != placed.x || composed.y != placed.y)  // the centre did move
    }

    // A spin pivots about the centre: the node position must not move.
    @Test func spinKeepsCentreFixed() {
        var delta = EffectDelta()
        delta.rotationAdd = 90
        let composed = EffectTransformMath.compose(placed, with: delta, unscaledWidth: w, unscaledHeight: h)
        #expect(composed.x == placed.x && composed.y == placed.y)
    }

    // Content degrees are clockwise on screen; zRotation is counterclockwise.
    @Test func clockwiseDegreesBecomeNegativeRadians() {
        var delta = EffectDelta()
        delta.rotationAdd = 90
        let composed = EffectTransformMath.compose(placed, with: delta, unscaledWidth: w, unscaledHeight: h)
        #expect(abs(composed.rotation - (placed.rotation - .pi / 2)) < 1e-12)
    }

    // Scale about the base keeps the feet planted.
    @Test func scaleAboutBottomKeepsFeetPlanted() {
        var delta = EffectDelta()
        delta.scaleMul = 1.3
        delta.anchor = .bottomCenter
        let composed = EffectTransformMath.compose(placed, with: delta, unscaledWidth: w, unscaledHeight: h)
        let pivot = EffectTransformMath.pivot(for: .bottomCenter, width: w, height: h)
        let before = world(pivot, placed)
        let after = world(pivot, composed.placement)
        #expect(abs(before.0 - after.0) < 1e-9 && abs(before.1 - after.1) < 1e-9)
        #expect(abs(composed.scale - 1.7 * 1.3) < 1e-12)
    }

    // Offsets are in rendered sizes (including the child's scale), screen-space, y down.
    @Test func offsetsUseRenderedSizeAndFlipY() {
        var delta = EffectDelta()
        delta.offsetYSelf = -0.5  // "up" in content terms
        delta.offsetXSelf = 0.1
        let composed = EffectTransformMath.compose(placed, with: delta, unscaledWidth: w, unscaledHeight: h)
        #expect(abs(composed.y - (placed.y + 0.5 * h * 1.7)) < 1e-9)
        #expect(abs(composed.x - (placed.x + 0.1 * w * 1.7)) < 1e-9)
    }

    @Test func opacityMultiplies() {
        var delta = EffectDelta()
        delta.opacityMul = 0.25
        let composed = EffectTransformMath.compose(
            StickerPlacement(x: 0, y: 0, rotation: 0, scale: 1, alpha: 0.8), with: delta, unscaledWidth: w, unscaledHeight: h)
        #expect(abs(composed.alpha - 0.2) < 1e-12)
    }
}
