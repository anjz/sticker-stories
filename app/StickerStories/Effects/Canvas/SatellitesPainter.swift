import SpriteKit

/// `satellites`: a few tiny lights gliding slowly across the sky behind
/// the scenery, far overhead — spacecraft catching the sunlight. Steady,
/// never blinking; each on its own path and pace, the first already on its
/// way when the effect begins.
@MainActor
final class SatellitesPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Light {
        let dot: SKSpriteNode
        let halo: SKSpriteNode
        let from: CGPoint, to: CGPoint  // fractions of the world
        let crossing: Double  // seconds across
        let offset: Double  // seconds into its crossing when the effect begins
        let size: CGFloat  // fraction of the world height
    }
    private var lights: [Light] = []
    private var world: CGRect = .zero
    private var began: TimeInterval?

    init() {
        let paths: [(CGPoint, CGPoint, Double, Double, CGFloat)] = [
            (CGPoint(x: -0.05, y: 0.78), CGPoint(x: 1.05, y: 0.9), 16, 4, 0.01),
            (CGPoint(x: 1.05, y: 0.7), CGPoint(x: -0.05, y: 0.8), 21, 0, 0.008),
            (CGPoint(x: 0.2, y: 1.02), CGPoint(x: 0.85, y: 0.66), 18, -5, 0.009),
        ]
        for (from, to, crossing, offset, size) in paths {
            let halo = SKSpriteNode(texture: EffectTextures.texture(named: "moonglow"))
            let dot = SKSpriteNode(texture: EffectTextures.texture(named: "dot"))
            for sprite in [halo, dot] {
                sprite.color = UIColor(red: 0.95, green: 0.97, blue: 1, alpha: 1)
                sprite.colorBlendFactor = 1
                sprite.blendMode = .add
                sprite.zPosition = CanvasEffectLayer.skyZ
                node.addChild(sprite)
            }
            lights.append(Light(dot: dot, halo: halo, from: from, to: to, crossing: crossing, offset: offset, size: size))
        }
    }

    func layout(world: CGRect) {
        self.world = world
        let h = world.height
        for light in lights {
            light.dot.size = CGSize(width: h * light.size, height: h * light.size)
            light.halo.size = CGSize(width: h * light.size * 5, height: h * light.size * 5)
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        if began == nil || time < began! { began = time }
        let w = world.width, h = world.height
        for light in lights {
            let local = time - began! + light.offset
            // Before its first crossing, and in the pause after each one, it is out of sight.
            let p = local < 0 ? -1 : local.truncatingRemainder(dividingBy: light.crossing * 1.3) / light.crossing
            guard (0...1).contains(p) else {
                light.dot.alpha = 0
                light.halo.alpha = 0
                continue
            }
            let at = CGPoint(
                x: world.minX + w * (light.from.x + (light.to.x - light.from.x) * p),
                y: world.minY + h * (light.from.y + (light.to.y - light.from.y) * p))
            light.dot.position = at
            light.halo.position = at
            light.dot.alpha = strength
            light.halo.alpha = strength * 0.35
        }
    }

    func didTurnOff() { began = nil }
}
