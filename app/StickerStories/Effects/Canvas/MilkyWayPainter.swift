import SpriteKit

/// `milkyway`: our galaxy seen edge-on — a pale, soft band of light
/// leaning gently across the upper sky behind the scenery, thick with tiny
/// steady stars along it. It stays high, clear of the horizon, so it never
/// shows over the ground.
@MainActor
final class MilkyWayPainter: CanvasEffectPainter {
    let node = SKNode()
    /// The band's own frame: centred on it, x along it.
    private let band = SKNode()
    private let glow = SKSpriteNode()
    private let core = SKSpriteNode()
    private struct Star {
        let node: SKSpriteNode
        let along: CGFloat, across: CGFloat  // fractions of the band's length and width
        let size: CGFloat  // fraction of the world height
        let brightness: Double
    }
    private var stars: [Star] = []
    private static let tint = UIColor(red: 0.86, green: 0.84, blue: 0.96, alpha: 1)

    init() {
        band.zRotation = -0.1  // leaning down to the right
        node.addChild(band)
        for (sprite, texture) in [(glow, "fog"), (core, "fog")] {
            sprite.texture = EffectTextures.texture(named: texture)
            sprite.color = Self.tint
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.skyZ
            band.addChild(sprite)
        }
        var random = SeededRandom(seed: 0x3117)
        for _ in 0..<110 {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "dot"))
            sprite.color = .white
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.skyZ
            band.addChild(sprite)
            // Most of them near the band's middle line.
            let across = (random.next(in: -1...1) + random.next(in: -1...1)) / 2
            stars.append(Star(
                node: sprite, along: random.next(in: -0.5...0.5), across: across * 0.5,
                size: random.next(in: 0.003...0.008), brightness: random.next(in: 0.35...1)))
        }
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        band.position = CGPoint(x: world.minX + w * 0.5, y: world.minY + h * 0.83)
        let length = w * 1.3, width = h * 0.17
        glow.size = CGSize(width: length, height: width)
        core.size = CGSize(width: length * 0.8, height: width * 0.4)
        for star in stars {
            star.node.size = CGSize(width: h * star.size, height: h * star.size)
            star.node.position = CGPoint(x: length * star.along, y: width * star.across)
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        glow.alpha = strength * 0.3
        core.alpha = strength * 0.2
        for star in stars { star.node.alpha = strength * star.brightness }
    }
}
