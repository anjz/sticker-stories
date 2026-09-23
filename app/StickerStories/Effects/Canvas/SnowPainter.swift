import SpriteKit

/// `snow`: soft flakes drifting down over everything at three depths, a
/// white snow sky over the top quarter of the scene (behind the foreground
/// art, so it replaces the blue rather than veiling the treetops; flakes
/// out of a bright blue sky look wrong), and a cool, bright wash — snow
/// light.
@MainActor
final class SnowPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let sky = SKSpriteNode()
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
        sky.texture = EffectTextures.texture(named: "overcast")
        sky.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the top edge
        sky.color = UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
        sky.colorBlendFactor = 1
        sky.zPosition = CanvasEffectLayer.skyZ
        node.addChild(sky)
        wash.color = UIColor(red: 0.86, green: 0.91, blue: 1.0, alpha: 1)
        wash.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(wash)
        node.addChild(flakes.node)
    }

    func layout(world: CGRect) {
        wash.size = CGSize(width: world.width * 1.02, height: world.height * 1.02)
        wash.position = CGPoint(x: world.midX, y: world.midY)
        // Solid over the top quarter, faded out by just past the middle.
        sky.size = CGSize(width: world.width * 1.04, height: world.height * 0.55)
        sky.position = CGPoint(x: world.midX, y: world.maxY + world.height * 0.01)
        flakes.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        wash.alpha = strength * 0.2
        // The sky turns white even for a moderate fall (0.6 → full); only a
        // light dusting leaves some blue.
        sky.alpha = min(0.95, strength * 1.6)
        flakes.apply(strength: strength, at: time)
    }

    func didTurnOff() { flakes.reset() }
}
