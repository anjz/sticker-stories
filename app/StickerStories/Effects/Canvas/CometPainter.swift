import SpriteKit

/// `comet`: a single comet gliding slowly across the sky behind the
/// scenery on a gentle arc, its long glowing tail streaming behind it. It
/// comes in from the left when the effect begins and, if the effect lasts,
/// comes round again after a pause.
@MainActor
final class CometPainter: CanvasEffectPainter {
    let node = SKNode()
    private let tail = SKSpriteNode()
    private let halo = SKSpriteNode()
    private let head = SKSpriteNode()
    private var world: CGRect = .zero
    private var began: TimeInterval?
    /// Seconds to cross, and between one crossing's start and the next.
    private static let crossing = 12.0
    private static let period = 16.0

    init() {
        tail.texture = EffectTextures.texture(named: "cometTail")
        tail.anchorPoint = CGPoint(x: 1, y: 0.5)  // the tail hangs back from the head
        halo.texture = EffectTextures.texture(named: "moonglow")
        head.texture = EffectTextures.texture(named: "dot")
        let colors = [
            UIColor(red: 0.7, green: 0.9, blue: 1, alpha: 1), UIColor(red: 0.8, green: 0.95, blue: 1, alpha: 1),
            UIColor.white,
        ]
        for (sprite, color) in zip([tail, halo, head], colors) {
            sprite.color = color
            sprite.colorBlendFactor = 1
            sprite.blendMode = .add
            sprite.zPosition = CanvasEffectLayer.skyZ
            node.addChild(sprite)
        }
    }

    func layout(world: CGRect) {
        self.world = world
        let h = world.height
        tail.size = CGSize(width: h * 0.5, height: h * 0.08)
        halo.size = CGSize(width: h * 0.14, height: h * 0.14)
        head.size = CGSize(width: h * 0.028, height: h * 0.028)
    }

    func apply(strength: Double, at time: TimeInterval) {
        if began == nil || time < began! { began = time }
        let local = (time - began!).truncatingRemainder(dividingBy: Self.period)
        let p = local / Self.crossing
        guard p <= 1 else {
            for sprite in [tail, halo, head] { sprite.alpha = 0 }
            return
        }
        let w = world.width, h = world.height
        // Left to right across the upper sky, rising a little then dipping.
        func point(_ p: Double) -> CGPoint {
            CGPoint(x: world.minX - h * 0.1 + (w + h * 0.6) * p, y: world.minY + h * (0.74 + 0.1 * sin(.pi * p)))
        }
        let at = point(p), ahead = point(p + 0.01)
        let angle = atan2(ahead.y - at.y, ahead.x - at.x)
        tail.position = at
        tail.zRotation = angle
        halo.position = at
        head.position = at
        tail.alpha = strength * 0.85
        halo.alpha = strength * 0.7
        head.alpha = strength
    }

    func didTurnOff() { began = nil }
}
