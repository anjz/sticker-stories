import SpriteKit

/// `sandcloud`: a cloud of sand swirling up from the sea floor and slowly
/// settling. Soft sandy puffs billow up from the bottom edge — how high
/// they reach follows the strength, so the envelope's ramps are the sand
/// swirling up and settling again — with grains whirling through the lower
/// water and a faint sandy murk over everything.
@MainActor
final class SandcloudPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Puff {
        let node: SKSpriteNode
        let x: CGFloat  // fraction of the world width
        let lift: CGFloat  // how high it rides, 0 (on the floor) … 1 (the cloud's top)
        let size: CGSize  // fractions of the world height
        let period: Double
        let phase: Double
    }
    private var puffs: [Puff] = []
    private let murk = SKSpriteNode()
    private let grains = DriftField(.init(
        count: 60, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.88, green: 0.78, blue: 0.56, alpha: 1), UIColor(red: 0.72, green: 0.62, blue: 0.44, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.004...0.009,
        velocity: CGVector(dx: 0.02, dy: 0.01),
        sway: 0.05, swayPeriod: 2...4,
        wander: 0.04, wanderPeriod: 2.5...5,
        alpha: 0.6...0.95,
        region: CGRect(x: 0, y: 0, width: 1, height: 0.45),
        enters: false,
        seed: 0x5A2D))
    private var world: CGRect = .zero
    private static let sand = UIColor(red: 0.84, green: 0.75, blue: 0.56, alpha: 1)

    init() {
        murk.color = Self.sand
        murk.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(murk)
        let layout: [(CGFloat, CGFloat, CGSize, Double, Double)] = [
            (0.05, 0.1, CGSize(width: 0.7, height: 0.34), 5.0, 0.0), (0.3, 0.3, CGSize(width: 0.8, height: 0.4), 6.2, 1.4),
            (0.55, 0.15, CGSize(width: 0.75, height: 0.36), 5.6, 2.7), (0.8, 0.35, CGSize(width: 0.7, height: 0.38), 6.8, 3.9),
            (0.98, 0.1, CGSize(width: 0.65, height: 0.32), 5.2, 0.9), (0.2, 0.7, CGSize(width: 0.6, height: 0.3), 7.4, 4.6),
            (0.62, 0.8, CGSize(width: 0.62, height: 0.28), 6.4, 2.1), (0.42, 1.0, CGSize(width: 0.5, height: 0.24), 7.9, 5.3),
        ]
        for (x, lift, size, period, phase) in layout {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "fog"))
            sprite.color = Self.sand
            sprite.colorBlendFactor = 1
            sprite.zPosition = CanvasEffectLayer.overlayZ + 1
            node.addChild(sprite)
            puffs.append(Puff(node: sprite, x: x, lift: lift, size: size, period: period, phase: phase))
        }
        node.addChild(grains.node)
    }

    func layout(world: CGRect) {
        self.world = world
        murk.size = CGSize(width: world.width * 1.02, height: world.height * 1.02)
        murk.position = CGPoint(x: world.midX, y: world.midY)
        grains.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        let w = world.width, h = world.height
        // The cloud's top: from the floor to 45 % of the height.
        let top = 0.45 * strength
        for puff in puffs {
            let swirl = sin(2 * .pi * time / puff.period + puff.phase)
            let billow = 1 + 0.1 * sin(2 * .pi * time / (puff.period * 0.8) + puff.phase * 1.3)
            puff.node.size = CGSize(width: h * puff.size.width * billow, height: h * puff.size.height * billow)
            puff.node.position = CGPoint(
                x: world.minX + w * puff.x + h * 0.05 * swirl,
                y: world.minY + h * (0.02 + top * puff.lift) + h * 0.02 * cos(2 * .pi * time / puff.period + puff.phase))
            puff.node.alpha = strength * (0.75 - 0.3 * puff.lift)
        }
        murk.alpha = strength * 0.14
        grains.apply(strength: strength, at: time)
    }

    func didTurnOff() { grains.reset() }
}
