import SpriteKit

/// `clouds`: a few big soft clouds drifting slowly to the right across the
/// sky, behind the foreground art and the stickers, and a light grey wash
/// as they cover the sun. They fade in where they are rather than sailing
/// in from the edge: at this speed that would take a whole story.
@MainActor
final class CloudsPainter: CanvasEffectPainter {
    let node = SKNode()
    private let dim = SKSpriteNode()
    private let clouds = DriftField(.init(
        count: 7, texture: EffectTextures.texture(named: "cloud"),
        colors: [.white],
        zPosition: CanvasEffectLayer.skyZ,
        size: 0.1...0.21, aspect: 2,
        velocity: CGVector(dx: 0.018, dy: 0), depthSpeed: 0.5...1,
        wander: 0.006, wanderPeriod: 9...14,
        alpha: 0.85...0.97,
        region: CGRect(x: 0, y: 0.58, width: 1, height: 0.3),
        margin: CGVector(dx: 0.3, dy: 0), enters: false,
        seed: 0xC10D))

    init() {
        dim.color = UIColor(red: 0.42, green: 0.46, blue: 0.54, alpha: 1)
        dim.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(dim)
        node.addChild(clouds.node)
    }

    func layout(world: CGRect) {
        dim.size = CGSize(width: world.width * 1.02, height: world.height * 1.02)
        dim.position = CGPoint(x: world.midX, y: world.midY)
        clouds.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        dim.alpha = strength * 0.14
        clouds.apply(strength: strength, at: time)
    }

    func didTurnOff() { clouds.reset() }
}
