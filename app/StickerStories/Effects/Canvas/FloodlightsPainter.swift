import SpriteKit

/// `floodlights`: the base's floodlights switch on — two broad white beams
/// slanting down from lamps at the top corners, each ending in a pool of
/// light on the ground that brightens whatever stands in it. Steady light,
/// never a flicker; loveliest over `nightfall`, whose darkness it sits
/// above.
@MainActor
final class FloodlightsPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Lamp {
        let beam: SKSpriteNode
        let pool: SKSpriteNode
        let head: SKSpriteNode
        let origin: CGPoint  // fractions of the world
        let target: CGPoint  // where the beam lands, fractions of the world
    }
    private var lamps: [Lamp] = []
    private static let light = UIColor(red: 0.93, green: 0.96, blue: 1, alpha: 1)

    init() {
        let layout: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0.03, y: 1.02), CGPoint(x: 0.34, y: 0.27)),
            (CGPoint(x: 0.97, y: 1.02), CGPoint(x: 0.66, y: 0.27)),
        ]
        for (origin, target) in layout {
            let beam = SKSpriteNode(texture: EffectTextures.texture(named: "ray"))
            beam.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the lamp
            let pool = SKSpriteNode(texture: EffectTextures.texture(named: "moonglow"))
            let head = SKSpriteNode(texture: EffectTextures.texture(named: "moonglow"))
            for (sprite, z) in [(beam, 4), (pool, 5), (head, 6)] as [(SKSpriteNode, CGFloat)] {
                sprite.color = Self.light
                sprite.colorBlendFactor = 1
                sprite.blendMode = .add
                sprite.zPosition = CanvasEffectLayer.overlayZ + z
                node.addChild(sprite)
            }
            lamps.append(Lamp(beam: beam, pool: pool, head: head, origin: origin, target: target))
        }
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        for lamp in lamps {
            let from = CGPoint(x: world.minX + w * lamp.origin.x, y: world.minY + h * lamp.origin.y)
            let to = CGPoint(x: world.minX + w * lamp.target.x, y: world.minY + h * lamp.target.y)
            let dx = to.x - from.x, dy = to.y - from.y
            lamp.beam.position = from
            lamp.beam.size = CGSize(width: h * 0.34, height: hypot(dx, dy) * 1.05)
            lamp.beam.zRotation = atan2(dx, -dy)  // from straight down toward the target
            lamp.pool.size = CGSize(width: h * 0.62, height: h * 0.18)
            lamp.pool.position = to
            lamp.head.size = CGSize(width: h * 0.16, height: h * 0.16)
            lamp.head.position = from
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        for lamp in lamps {
            lamp.beam.alpha = strength * 0.28
            lamp.pool.alpha = strength * 0.4
            lamp.head.alpha = strength * 0.8
        }
    }
}
