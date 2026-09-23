import SpriteKit

/// `shootingstars`: now and then a streak of light crosses the sky behind
/// the scenery, head first, and fades. A handful of slots each fire on
/// their own period from a fresh random point every time (seeded per
/// cycle, so a replay looks the same); strength decides how many slots are
/// on, from a single star now and then to a meteor shower.
@MainActor
final class ShootingStarsPainter: CanvasEffectPainter {
    let node = SKNode()
    private struct Slot {
        let streak: SKSpriteNode
        let head: SKSpriteNode
        let period: Double
        let offset: Double
        let leftward: Bool
    }
    private var slots: [Slot] = []
    private var world: CGRect = .zero
    /// Seconds a star takes to cross.
    private static let flight = 0.9

    init() {
        var random = SeededRandom(seed: 0x57A2)
        for index in 0..<8 {
            let streak = SKSpriteNode(texture: EffectTextures.texture(named: "streak"))
            streak.anchorPoint = CGPoint(x: 1, y: 0.5)  // hangs back from the head
            let head = SKSpriteNode(texture: EffectTextures.texture(named: "dot"))
            for sprite in [streak, head] {
                sprite.color = UIColor(red: 0.92, green: 0.96, blue: 1, alpha: 1)
                sprite.colorBlendFactor = 1
                sprite.blendMode = .add
                sprite.zPosition = CanvasEffectLayer.skyZ
                sprite.alpha = 0
                node.addChild(sprite)
            }
            slots.append(Slot(
                streak: streak, head: head, period: random.next(in: 2.6...6), offset: random.next() * 6,
                leftward: index % 2 == 0))
        }
    }

    func layout(world: CGRect) {
        self.world = world
        for slot in slots { slot.head.size = CGSize(width: world.height * 0.02, height: world.height * 0.02) }
    }

    func apply(strength: Double, at time: TimeInterval) {
        let w = world.width, h = world.height
        let on = strength * Double(slots.count)
        for (index, slot) in slots.enumerated() {
            let share = min(1, max(0, on - Double(index)))
            let local = time + slot.offset
            let cycle = (local / slot.period).rounded(.down)
            let p = (local - cycle * slot.period) / Self.flight
            guard share > 0, p < 1 else {
                slot.streak.alpha = 0
                slot.head.alpha = 0
                continue
            }
            // Where this cycle's star starts and which way it falls.
            var random = SeededRandom(seed: UInt64(index + 1) &* 0x9E37 &+ UInt64(bitPattern: Int64(cycle)))
            let start = CGPoint(
                x: world.minX + w * random.next(in: 0.15...0.85), y: world.minY + h * random.next(in: 0.62...0.92))
            let angle = (slot.leftward ? Double.pi + 0.45 : -0.45) + random.next(in: -0.15...0.15)
            let travel = h * 0.42
            let eased = 1 - (1 - p) * (1 - p)
            let headAt = CGPoint(x: start.x + cos(angle) * travel * eased, y: start.y + sin(angle) * travel * eased)
            let fade = sin(.pi * p)
            slot.streak.position = headAt
            slot.streak.zRotation = angle
            slot.streak.size = CGSize(width: h * (0.08 + 0.2 * fade), height: h * 0.012)
            slot.streak.alpha = share * fade
            slot.head.position = headAt
            slot.head.alpha = share * fade
        }
    }
}
