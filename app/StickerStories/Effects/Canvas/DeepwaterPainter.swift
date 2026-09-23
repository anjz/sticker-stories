import SpriteKit

/// `deepwater`: going deeper. The water darkens to a deep blue — a wash
/// over everything, more toward the edges and the surface, where the light
/// is going — without ever going black: the stickers stay easy to see.
@MainActor
final class DeepwaterPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let edges = SKSpriteNode()
    private let top = SKSpriteNode()
    private static let deep = UIColor(red: 0.02, green: 0.08, blue: 0.22, alpha: 1)

    init() {
        wash.color = Self.deep
        edges.texture = EffectTextures.texture(named: "vignette")
        top.texture = EffectTextures.texture(named: "skyglow")
        top.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the surface
        for sprite in [wash, edges, top] {
            sprite.color = Self.deep
            sprite.colorBlendFactor = 1
            sprite.zPosition = CanvasEffectLayer.overlayZ + 3
            node.addChild(sprite)
        }
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        wash.size = CGSize(width: w * 1.02, height: h * 1.02)
        wash.position = CGPoint(x: world.midX, y: world.midY)
        edges.size = CGSize(width: w * 1.04, height: h * 1.04)
        edges.position = wash.position
        top.size = CGSize(width: w * 1.04, height: h * 0.6)
        top.position = CGPoint(x: world.midX, y: world.maxY + h * 0.01)
    }

    func apply(strength: Double, at time: TimeInterval) {
        wash.alpha = strength * 0.32
        edges.alpha = strength * 0.45
        top.alpha = strength * 0.4
    }
}
