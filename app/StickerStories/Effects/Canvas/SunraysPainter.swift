import SpriteKit

/// `sunrays`: sunlight through the water. A bright glow along the surface
/// (the top edge) and shafts of cool light slanting down from it, swaying
/// slowly and breathing as the water above them moves — more than
/// `sunshine`'s shafts ever do.
@MainActor
final class SunraysPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Shaft {
        let node: SKSpriteNode
        let x: CGFloat  // fraction of the world width, along the surface
        let angle: CGFloat  // radians, clockwise from straight down
        let width: CGFloat  // fraction of the world height
        let period: Double
        let phase: Double
    }
    private var shafts: [Shaft] = []
    private let surface = SKSpriteNode()
    private var world: CGRect = .zero

    init() {
        surface.texture = EffectTextures.texture(named: "skyglow")
        surface.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the top edge
        surface.color = UIColor(red: 0.7, green: 0.95, blue: 1, alpha: 1)
        surface.colorBlendFactor = 1
        surface.blendMode = .add
        surface.zPosition = CanvasEffectLayer.overlayZ + 1
        node.addChild(surface)
        let layout: [(CGFloat, CGFloat, CGFloat, Double, Double)] = [
            (0.08, 14, 0.13, 6.5, 0.0), (0.24, 10, 0.2, 8.0, 1.1), (0.4, 12, 0.11, 5.5, 2.3),
            (0.56, 9, 0.22, 7.2, 3.6), (0.72, 13, 0.14, 6.0, 0.6), (0.9, 10, 0.18, 8.6, 4.4),
        ]
        for (x, degrees, width, period, phase) in layout {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "ray"))
            sprite.anchorPoint = CGPoint(x: 0.5, y: 1)
            sprite.color = UIColor(red: 0.78, green: 0.96, blue: 1, alpha: 1)
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.overlayZ + 1
            node.addChild(sprite)
            shafts.append(Shaft(node: sprite, x: x, angle: degrees * .pi / 180, width: width, period: period, phase: phase))
        }
    }

    func layout(world: CGRect) {
        self.world = world
        let w = world.width, h = world.height
        surface.size = CGSize(width: w * 1.04, height: h * 0.4)
        surface.position = CGPoint(x: world.midX, y: world.maxY + h * 0.01)
        for shaft in shafts {
            shaft.node.position = CGPoint(x: world.minX + w * shaft.x, y: world.maxY + h * 0.02)
            shaft.node.size = CGSize(width: h * shaft.width, height: h * 1.2)
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        surface.alpha = strength * (0.24 + 0.04 * sin(2 * .pi * time / 4.5))
        for shaft in shafts {
            let sway = sin(2 * .pi * time / shaft.period + shaft.phase)
            shaft.node.zRotation = -(shaft.angle + 4 * .pi / 180 * sway)  // clockwise from straight down
            shaft.node.alpha = strength * (0.32 + 0.12 * sin(2 * .pi * time / (shaft.period * 0.6) + shaft.phase))
        }
    }
}
