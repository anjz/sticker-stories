import SpriteKit

/// `bubbles`: round bubbles rising in from the bottom of the scene, big
/// near ones faster than small far ones, each wobbling side to side as it
/// goes up. The same bubbles suit a bath, a party and the sea floor.
@MainActor
final class BubblesPainter: CanvasEffectPainter {
    let node = SKNode()
    private let bubbles = DriftField(.init(
        count: 44, texture: EffectTextures.texture(named: "bubble"),
        colors: [.white, UIColor(red: 0.88, green: 0.95, blue: 1, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.02...0.065,
        velocity: CGVector(dx: 0, dy: 0.13), depthSpeed: 0.45...1,
        sway: 0.014, swayPeriod: 1.4...2.8,
        alpha: 0.7...0.95,
        seed: 0xB0BB))

    init() { node.addChild(bubbles.node) }

    func layout(world: CGRect) { bubbles.layout(world: world) }

    func apply(strength: Double, at time: TimeInterval) { bubbles.apply(strength: strength, at: time) }

    func didTurnOff() { bubbles.reset() }
}
