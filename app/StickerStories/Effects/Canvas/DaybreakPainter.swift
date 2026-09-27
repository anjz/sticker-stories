import SpriteKit

/// `daybreak`: the sun comes back to a world with no air — no golden dawn,
/// just light. A broad band of stark white sunlight sweeps across the
/// scene from the left, leaving everything a little brighter, and a soft
/// glare sits in the top-left corner, as if the Sun has just cleared the
/// edge of the picture. The art paints no sun of its own
/// (docs/pack-format.md). It is what ends a `nightfall`.
@MainActor
final class DaybreakPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let sweep = SKSpriteNode()
    private let glare = SKSpriteNode()
    private let glareCore = SKSpriteNode()
    private var world: CGRect = .zero
    private var began: TimeInterval?
    /// Seconds the band takes to cross the scene.
    private static let crossing = 4.5
    private static let light = UIColor(red: 1, green: 0.98, blue: 0.93, alpha: 1)

    init() {
        sweep.texture = EffectTextures.texture(named: "fog")
        glare.texture = EffectTextures.texture(named: "moonglow")
        glareCore.texture = EffectTextures.texture(named: "moonglow")
        for (sprite, z) in [(wash, 0), (sweep, 1), (glare, 2), (glareCore, 2)] as [(SKSpriteNode, CGFloat)] {
            sprite.color = Self.light
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.overlayZ + z
            node.addChild(sprite)
        }
    }

    func layout(world: CGRect) {
        self.world = world
        let w = world.width, h = world.height
        wash.size = CGSize(width: w * 1.02, height: h * 1.02)
        wash.position = CGPoint(x: world.midX, y: world.midY)
        sweep.size = CGSize(width: w * 0.55, height: h * 1.5)
        glare.size = CGSize(width: h * 0.9, height: h * 0.9)
        glare.position = CGPoint(x: world.minX + w * 0.02, y: world.maxY - h * 0.04)
        glareCore.size = CGSize(width: h * 0.3, height: h * 0.3)
        glareCore.position = glare.position
    }

    func apply(strength: Double, at time: TimeInterval) {
        if began == nil || time < began! { began = time }
        let p = (time - began!) / Self.crossing
        let w = world.width
        sweep.position = CGPoint(x: world.minX - w * 0.35 + w * 1.7 * p, y: world.midY)
        sweep.alpha = p < 1 ? strength * 0.3 * sin(.pi * p) : 0
        wash.alpha = strength * 0.1
        glare.alpha = strength * 0.45
        glareCore.alpha = strength * 0.5
    }

    func didTurnOff() { began = nil }
}
