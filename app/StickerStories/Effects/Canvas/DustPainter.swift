import SpriteKit

/// `dust`: a spray of grey moon dust — kicked up by a landing, racing
/// wheels or digging — billowing up across the lower scene and falling
/// back. How high the puffs reach follows the strength, so the envelope's
/// quick ramp-in is the dust flying up and its longer ramp-out the dust
/// coming down; with no air to hold it, grains rain straight back down.
@MainActor
final class DustPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Puff {
        let node: SKSpriteNode
        let x: CGFloat  // fraction of the world width
        let lift: CGFloat  // how high it rides, 0 (on the ground) … 1 (the cloud's top)
        let size: CGSize  // fractions of the world height
        let period: Double
        let phase: Double
    }
    private var puffs: [Puff] = []
    private let murk = SKSpriteNode()
    private let grains = DriftField(.init(
        count: 70, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.5, green: 0.5, blue: 0.53, alpha: 1), UIColor(red: 0.38, green: 0.38, blue: 0.42, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.004...0.009,
        velocity: CGVector(dx: 0.01, dy: -0.06), depthSpeed: 0.6...1,
        sway: 0.01, swayPeriod: 2...4,
        alpha: 0.6...0.95,
        region: CGRect(x: 0, y: 0, width: 1, height: 0.4),
        enters: false,
        seed: 0xD057A))
    private var world: CGRect = .zero
    private static let dust = UIColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1)

    init() {
        murk.color = Self.dust
        murk.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(murk)
        let layout: [(CGFloat, CGFloat, CGSize, Double, Double)] = [
            (0.08, 0.2, CGSize(width: 0.6, height: 0.3), 4.0, 0.0), (0.3, 0.45, CGSize(width: 0.7, height: 0.34), 4.6, 1.4),
            (0.52, 0.15, CGSize(width: 0.65, height: 0.3), 4.2, 2.7), (0.74, 0.5, CGSize(width: 0.62, height: 0.32), 5.0, 3.9),
            (0.95, 0.2, CGSize(width: 0.58, height: 0.28), 4.4, 0.9), (0.42, 0.85, CGSize(width: 0.5, height: 0.24), 5.4, 4.6),
            (0.66, 1.0, CGSize(width: 0.46, height: 0.22), 5.8, 2.1),
        ]
        for (x, lift, size, period, phase) in layout {
            // Shaded billows rather than soft fog: grey on the grey ground,
            // the dust needs its own light and shadow to read.
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "cloud"))
            sprite.color = Self.dust
            sprite.colorBlendFactor = 0.75
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
        // The cloud's top: from the ground to 40 % of the height.
        let top = 0.4 * strength
        for puff in puffs {
            let billow = 1 + 0.08 * sin(2 * .pi * time / puff.period + puff.phase)
            puff.node.size = CGSize(width: h * puff.size.width * billow, height: h * puff.size.height * billow)
            puff.node.position = CGPoint(
                x: world.minX + w * puff.x + h * 0.03 * sin(2 * .pi * time / (puff.period * 1.4) + puff.phase),
                y: world.minY + h * (0.02 + top * puff.lift))
            puff.node.alpha = strength * (0.9 - 0.35 * puff.lift)
        }
        murk.alpha = strength * 0.1
        grains.apply(strength: strength, at: time)
    }

    func didTurnOff() { grains.reset() }
}
