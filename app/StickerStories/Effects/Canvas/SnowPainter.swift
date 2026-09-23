import SpriteKit

/// `snow`: soft flakes drifting down over everything at three depths, and
/// a cool, bright wash — snow light.
@MainActor
final class SnowPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let flakes = DriftField(.init(
        count: 170, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(white: 1, alpha: 1), UIColor(red: 0.94, green: 0.97, blue: 1, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.01...0.032,
        velocity: CGVector(dx: -0.012, dy: -0.13), depthSpeed: 0.35...1,
        sway: 0.018, swayPeriod: 3...7,
        alpha: 0.7...1,
        seed: 0x5E0F))

    init() {
        wash.color = UIColor(red: 0.86, green: 0.91, blue: 1.0, alpha: 1)
        wash.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(wash)
        node.addChild(flakes.node)
    }

    func layout(world: CGRect) {
        wash.size = CGSize(width: world.width * 1.02, height: world.height * 1.02)
        wash.position = CGPoint(x: world.midX, y: world.midY)
        flakes.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        wash.alpha = strength * 0.2
        flakes.apply(strength: strength, at: time)
    }

    func didTurnOff() { flakes.reset() }
}
