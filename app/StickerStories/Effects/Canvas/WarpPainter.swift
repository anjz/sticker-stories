import SpriteKit

/// `warp`: zooming through space. Stars stretch into streaks rushing out
/// from the centre of the scene — each accelerating and lengthening as it
/// flies outward, its tail pointing back at the vanishing point — around a
/// faint glow where they come from. In the sky, behind the stickers and the
/// foreground art, so the cast rides through it; Reduce Motion drops it.
@MainActor
final class WarpPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Streak {
        let node: SKSpriteNode
        let angle: Double
        let rate: Double  // trips per second
        let phase: Double
    }
    private var streaks: [Streak] = []
    private let core = SKSpriteNode()
    private var world: CGRect = .zero

    init() {
        var random = SeededRandom(seed: 0x3A2F)
        for _ in 0..<90 {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "streak"))
            sprite.anchorPoint = CGPoint(x: 1, y: 0.5)  // the head leads, the tail trails inward
            sprite.color = UIColor(red: 0.85, green: 0.92, blue: 1, alpha: 1)
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.skyZ
            node.addChild(sprite)
            streaks.append(Streak(
                node: sprite, angle: random.next() * 2 * .pi, rate: random.next(in: 0.55...1.1), phase: random.next()))
        }
        core.texture = EffectTextures.texture(named: "moonglow")
        core.color = UIColor(red: 0.75, green: 0.85, blue: 1, alpha: 1)
        core.colorBlendFactor = 1
        core.blendMode = .add
        core.zPosition = CanvasEffectLayer.skyZ
        node.addChild(core)
    }

    func layout(world: CGRect) {
        self.world = world
        core.size = CGSize(width: world.height * 0.5, height: world.height * 0.5)
        core.position = CGPoint(x: world.midX, y: world.midY)
    }

    func apply(strength: Double, at time: TimeInterval) {
        let center = CGPoint(x: world.midX, y: world.midY)
        let reach = 0.5 * (world.width * world.width + world.height * world.height).squareRoot()
        let h = world.height
        let visible = strength * Double(streaks.count)
        for (index, streak) in streaks.enumerated() {
            let share = min(1, max(0, visible - Double(index)))
            let r = (streak.phase + time * streak.rate).truncatingRemainder(dividingBy: 1)
            let distance = reach * (0.04 + 1.05 * r * r)
            streak.node.position = CGPoint(
                x: center.x + cos(streak.angle) * distance, y: center.y + sin(streak.angle) * distance)
            streak.node.zRotation = streak.angle
            streak.node.size = CGSize(width: h * (0.02 + 0.34 * r * r), height: h * (0.004 + 0.006 * r))
            let fadeIn = min(1, r / 0.15)
            streak.node.alpha = share * fadeIn * (0.55 + 0.45 * r)
        }
        core.alpha = strength * 0.3
    }
}
