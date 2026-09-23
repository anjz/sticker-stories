import SpriteKit

/// `firelight`: a cosy evening by the fire. The edges of the room dim to a
/// warm brown, a light warm tint goes over everything, and an orange glow
/// rises from the bottom edge, flickering slowly on three sines of a few
/// percent each (periods 0.8 to 2.1 s), so never a strobe.
@MainActor
final class FirelightPainter: CanvasEffectPainter {
    let node = SKNode()
    private let dim = SKSpriteNode()
    private let tint = SKSpriteNode()
    private let glow = SKSpriteNode()

    init() {
        dim.texture = EffectTextures.texture(named: "vignette")
        dim.color = UIColor(red: 0.16, green: 0.07, blue: 0.03, alpha: 1)
        dim.colorBlendFactor = 1
        dim.zPosition = CanvasEffectLayer.overlayZ + 3
        tint.color = UIColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 1)
        tint.zPosition = CanvasEffectLayer.overlayZ
        glow.texture = EffectTextures.texture(named: "skyglow")
        glow.anchorPoint = CGPoint(x: 0.5, y: 1)
        glow.zRotation = .pi  // the sky glow turned over: light from the bottom edge
        glow.color = UIColor(red: 1.0, green: 0.52, blue: 0.18, alpha: 1)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.zPosition = CanvasEffectLayer.overlayZ + 4
        for sprite in [dim, tint, glow] { node.addChild(sprite) }
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        dim.size = CGSize(width: w * 1.04, height: h * 1.04)
        dim.position = CGPoint(x: world.midX, y: world.midY)
        tint.size = CGSize(width: w * 1.02, height: h * 1.02)
        tint.position = dim.position
        glow.size = CGSize(width: w * 1.04, height: h * 0.8)
        glow.position = CGPoint(x: world.midX, y: world.minY - h * 0.01)
    }

    func apply(strength: Double, at time: TimeInterval) {
        let flicker = 0.05 * sin(2 * .pi * time / 1.3) + 0.04 * sin(2 * .pi * time / 2.1 + 1)
            + 0.03 * sin(2 * .pi * time / 0.83 + 2)
        dim.alpha = strength * 0.55
        tint.alpha = strength * 0.1
        glow.alpha = strength * (0.5 + flicker)
    }
}
