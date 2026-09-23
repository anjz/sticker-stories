import SpriteKit

/// `glowplankton`: tiny blue-green lights drifting through the water, each
/// on its own slow wander, twinkling. Added light above `deepwater`'s
/// darkness, so they glow in the dark it makes; in bright water they are
/// faint.
@MainActor
final class GlowplanktonPainter: CanvasEffectPainter {
    let node = SKNode()
    private let lights = DriftField(.init(
        count: 70, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.35, green: 1, blue: 0.9, alpha: 1), UIColor(red: 0.45, green: 0.8, blue: 1, alpha: 1)],
        blendMode: .add,
        zPosition: CanvasEffectLayer.overlayZ + 5,
        size: 0.008...0.022,
        velocity: CGVector(dx: 0.008, dy: 0.004),
        sway: 0.03, swayPeriod: 7...13,
        wander: 0.025, wanderPeriod: 6...11,
        alpha: 0.6...1,
        twinkle: 0.8, twinklePeriod: 1.6...3.4,
        enters: false,
        seed: 0x61A5))

    init() { node.addChild(lights.node) }

    func layout(world: CGRect) { lights.layout(world: world) }

    func apply(strength: Double, at time: TimeInterval) { lights.apply(strength: strength, at: time) }

    func didTurnOff() { lights.reset() }
}
