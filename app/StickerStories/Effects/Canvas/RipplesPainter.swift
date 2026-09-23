import SpriteKit

/// `ripples`: sunlight rippling on the sea floor. Two phases of a caustic
/// net crossfade into each other while sliding gently against each other,
/// so the net of light shimmers and shifts without any texture being
/// redrawn; strongest near the bottom, where the light lands.
@MainActor
final class RipplesPainter: CanvasEffectPainter {
    let node = SKNode()
    private let first = SKSpriteNode()
    private let second = SKSpriteNode()
    private var world: CGRect = .zero

    init() {
        for (sprite, name) in [(first, "causticsA"), (second, "causticsB")] {
            sprite.texture = EffectTextures.texture(named: name)
            sprite.color = UIColor(red: 0.82, green: 1, blue: 1, alpha: 1)
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.overlayZ + 1
            node.addChild(sprite)
        }
    }

    func layout(world: CGRect) {
        self.world = world
        for sprite in [first, second] {
            sprite.size = CGSize(width: world.width * 1.12, height: world.height * 1.04)
        }
    }

    func apply(strength: Double, at time: TimeInterval) {
        let w = world.width, h = world.height
        let blend = 0.5 + 0.5 * sin(2 * .pi * time / 3.2)
        let slide = sin(2 * .pi * time / 7)
        first.position = CGPoint(x: world.midX + w * 0.025 * slide, y: world.midY + h * 0.006 * cos(2 * .pi * time / 5))
        second.position = CGPoint(x: world.midX - w * 0.025 * slide, y: world.midY - h * 0.006 * cos(2 * .pi * time / 6))
        first.alpha = strength * 0.34 * blend
        second.alpha = strength * 0.34 * (1 - blend)
    }
}
