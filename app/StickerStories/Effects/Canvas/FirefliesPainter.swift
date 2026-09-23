import SpriteKit

/// `fireflies`: tiny warm lights hovering in the lower part of the scene,
/// each wandering on its own slow loop and pulsing gently. Added light over
/// everything — `night`'s darkness included, so they glow in the dark it
/// makes; in daylight they are faint, as fireflies are.
@MainActor
final class FirefliesPainter: CanvasEffectPainter {
    let node = SKNode()
    private let glows = DriftField(.init(
        count: 36, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.9, green: 1.0, blue: 0.45, alpha: 1), UIColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 1)],
        blendMode: .add,
        zPosition: CanvasEffectLayer.overlayZ + 5,
        size: 0.018...0.036,
        sway: 0.035, swayPeriod: 6...11,
        wander: 0.03, wanderPeriod: 5...9,
        alpha: 0.7...1,
        twinkle: 0.75, twinklePeriod: 1.8...3.6,
        region: CGRect(x: 0.02, y: 0.06, width: 0.96, height: 0.52),
        seed: 0xF1EF))

    init() { node.addChild(glows.node) }

    func layout(world: CGRect) { glows.layout(world: world) }

    func apply(strength: Double, at time: TimeInterval) { glows.apply(strength: strength, at: time) }

    func didTurnOff() { glows.reset() }
}
