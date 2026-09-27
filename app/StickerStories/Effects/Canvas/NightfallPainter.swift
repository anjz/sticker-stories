import SpriteKit

/// `nightfall`: the long night on a world with no air. The scene darkens
/// to a deep blue-grey — never black, the stickers stay easy to see — and
/// many more stars come out one by one in the sky behind the scenery.
/// They shine steadily: with no air around them, stars don't twinkle.
@MainActor
final class NightfallPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let edges = SKSpriteNode()
    private struct Star {
        let node: SKSpriteNode
        let place: CGPoint  // fractions of the world
        let size: CGFloat  // fraction of the world height
        let threshold: Double  // the strength at which it comes out
    }
    private var stars: [Star] = []
    private static let night = UIColor(red: 0.03, green: 0.05, blue: 0.14, alpha: 1)

    init() {
        wash.color = Self.night
        edges.texture = EffectTextures.texture(named: "vignette")
        for sprite in [wash, edges] {
            sprite.color = Self.night
            sprite.colorBlendFactor = 1
            sprite.zPosition = CanvasEffectLayer.overlayZ + 3
            node.addChild(sprite)
        }
        var random = SeededRandom(seed: 0x9F1A)
        for _ in 0..<56 {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "dot"))
            sprite.color = .white
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.skyZ
            node.addChild(sprite)
            stars.append(Star(
                node: sprite,
                place: CGPoint(x: random.next(in: 0...1), y: random.next(in: 0.62...0.99)),
                size: random.next(in: 0.006...0.014),
                threshold: random.next(in: 0...0.7)))
        }
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        wash.size = CGSize(width: w * 1.02, height: h * 1.02)
        wash.position = CGPoint(x: world.midX, y: world.midY)
        edges.size = CGSize(width: w * 1.04, height: h * 1.04)
        edges.position = wash.position
        for star in stars {
            star.node.size = CGSize(width: h * star.size, height: h * star.size)
            star.node.position = CGPoint(x: world.minX + w * star.place.x, y: world.minY + h * star.place.y)
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        wash.alpha = strength * 0.5
        edges.alpha = strength * 0.35
        for star in stars {
            star.node.alpha = min(1, max(0, (strength - star.threshold) / 0.15))
        }
    }
}
