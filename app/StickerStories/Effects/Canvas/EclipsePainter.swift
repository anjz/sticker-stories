import SpriteKit

/// `eclipse`: the Earth passes in front of the Sun. Seen from the Moon the
/// light goes a deep, dim copper-red — every sunrise and sunset on Earth
/// at once, shining through its air — darkest toward the edges, and comes
/// back when the effect clears. Dim, never dark: the stickers stay easy to
/// see.
@MainActor
final class EclipsePainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let edges = SKSpriteNode()
    private let copper = SKSpriteNode()

    init() {
        wash.color = UIColor(red: 0.2, green: 0.05, blue: 0.03, alpha: 1)
        edges.texture = EffectTextures.texture(named: "vignette")
        edges.color = UIColor(red: 0.12, green: 0.03, blue: 0.02, alpha: 1)
        copper.color = UIColor(red: 1, green: 0.38, blue: 0.14, alpha: 1)
        copper.blendMode = .add
        for (sprite, z) in [(wash, 3), (edges, 3), (copper, 4)] as [(SKSpriteNode, CGFloat)] {
            sprite.colorBlendFactor = 1
            sprite.zPosition = CanvasEffectLayer.overlayZ + z
            node.addChild(sprite)
        }
    }

    func layout(world: CGRect) {
        let size = CGSize(width: world.width * 1.04, height: world.height * 1.04)
        for sprite in [wash, edges, copper] {
            sprite.size = size
            sprite.position = CGPoint(x: world.midX, y: world.midY)
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        wash.alpha = strength * 0.55
        edges.alpha = strength * 0.4
        copper.alpha = strength * 0.1
    }
}
