import SpriteKit

/// `sunset`: the top of the sky turns rose-violet, a peach-orange glow
/// lies along the horizon behind the scenery, and a light warm tint and a
/// little added glow go over everything. Washes in colour rather than
/// multiplied light: a multiplied orange over a blue sky only turns it grey.
/// The art paints no sun, so neither does this.
@MainActor
final class SunsetPainter: CanvasEffectPainter {
    let node = SKNode()
    private let warmth = SKSpriteNode()
    private let skyTop = SKSpriteNode()
    private let horizon = SKSpriteNode()

    init() {
        warmth.color = UIColor(red: 1.0, green: 0.55, blue: 0.3, alpha: 1)
        warmth.zPosition = CanvasEffectLayer.overlayZ
        skyTop.texture = EffectTextures.texture(named: "skyglow")
        skyTop.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the top edge
        skyTop.color = UIColor(red: 0.66, green: 0.36, blue: 0.62, alpha: 1)
        skyTop.colorBlendFactor = 1
        skyTop.zPosition = CanvasEffectLayer.overlayZ + 1
        horizon.texture = EffectTextures.texture(named: "band")
        horizon.color = UIColor(red: 1.0, green: 0.62, blue: 0.4, alpha: 1)
        horizon.colorBlendFactor = 1
        horizon.zPosition = CanvasEffectLayer.skyZ
        for sprite in [warmth, skyTop, horizon] { node.addChild(sprite) }
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        warmth.size = CGSize(width: w * 1.02, height: h * 1.02)
        warmth.position = CGPoint(x: world.midX, y: world.midY)
        skyTop.size = CGSize(width: w * 1.04, height: h * 0.6)
        skyTop.position = CGPoint(x: world.midX, y: world.maxY + h * 0.01)
        // Scenes keep their horizon in the middle band (docs/pack-format.md).
        horizon.size = CGSize(width: w * 1.04, height: h * 0.7)
        horizon.position = CGPoint(x: world.midX, y: world.minY + h * 0.55)
    }

    func apply(strength: Double, at time: TimeInterval) {
        warmth.alpha = strength * 0.2
        skyTop.alpha = strength * 0.75
        horizon.alpha = strength * (0.62 + 0.04 * sin(2 * .pi * time / 8))
    }
}
