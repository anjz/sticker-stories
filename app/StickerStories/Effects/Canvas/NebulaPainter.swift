import SpriteKit

/// `nebula`: big soft clouds of coloured light — purple, pink, teal —
/// swelling across the sky behind the scenery, each drifting and breathing
/// on its own slow cycle. Added light, so the stars in the art still show
/// through.
@MainActor
final class NebulaPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Cloud {
        let node: SKSpriteNode
        let base: CGPoint  // fractions of the world
        let size: CGSize  // fractions of the world height
        let period: Double
        let phase: Double
        let weight: Double
    }
    private var clouds: [Cloud] = []
    private var world: CGRect = .zero

    init() {
        let layout: [(CGPoint, CGSize, UIColor, Double, Double, Double)] = [
            (CGPoint(x: 0.18, y: 0.8), CGSize(width: 0.9, height: 0.42), UIColor(red: 0.5, green: 0.2, blue: 0.9, alpha: 1), 17, 0.0, 1.0),
            (CGPoint(x: 0.78, y: 0.86), CGSize(width: 0.85, height: 0.36), UIColor(red: 0.1, green: 0.62, blue: 0.7, alpha: 1), 21, 1.7, 0.9),
            (CGPoint(x: 0.5, y: 0.62), CGSize(width: 0.9, height: 0.32), UIColor(red: 0.85, green: 0.22, blue: 0.6, alpha: 1), 19, 3.1, 0.8),
            (CGPoint(x: 0.9, y: 0.56), CGSize(width: 0.6, height: 0.3), UIColor(red: 0.35, green: 0.25, blue: 0.85, alpha: 1), 23, 4.4, 0.75),
            (CGPoint(x: 0.06, y: 0.52), CGSize(width: 0.6, height: 0.28), UIColor(red: 0.12, green: 0.4, blue: 0.85, alpha: 1), 25, 2.2, 0.7),
        ]
        for (base, size, color, period, phase, weight) in layout {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "fog"))
            sprite.color = color
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.skyZ
            node.addChild(sprite)
            clouds.append(Cloud(node: sprite, base: base, size: size, period: period, phase: phase, weight: weight))
        }
    }

    func layout(world: CGRect) { self.world = world }

    func apply(strength: Double, at time: TimeInterval) {
        let w = world.width, h = world.height
        for cloud in clouds {
            let drift = sin(2 * .pi * time / cloud.period + cloud.phase)
            let breathe = 1 + 0.08 * sin(2 * .pi * time / (cloud.period * 0.7) + cloud.phase * 1.3)
            cloud.node.size = CGSize(width: h * cloud.size.width * breathe, height: h * cloud.size.height * breathe)
            cloud.node.position = CGPoint(
                x: world.minX + w * cloud.base.x + h * 0.05 * drift, y: world.minY + h * cloud.base.y)
            cloud.node.alpha = strength * 0.55 * cloud.weight
        }
    }
}
