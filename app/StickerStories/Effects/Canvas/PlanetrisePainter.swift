import SpriteKit

/// `planetrise`: a big banded planet with a glowing atmosphere rises from
/// behind the scenery and lights the scene softly from below. How high it
/// rises follows the strength, so the envelope's ramps are the rising and
/// the setting, and a lower intensity is a planet only peeking over the
/// horizon.
@MainActor
final class PlanetrisePainter: CanvasEffectPainter {
    let node = SKNode()
    private let planet = SKSpriteNode()
    private let rim = SKSpriteNode()
    private let light = SKSpriteNode()
    private var world: CGRect = .zero
    /// The planet's width, as a fraction of the world height.
    private static let diameter = 1.1

    init() {
        planet.texture = EffectTextures.texture(named: "planet")
        planet.zPosition = CanvasEffectLayer.skyZ
        rim.texture = EffectTextures.texture(named: "rim")
        rim.color = UIColor(red: 0.6, green: 0.88, blue: 1, alpha: 1)
        rim.colorBlendFactor = 1
        rim.blendMode = .add
        rim.zPosition = CanvasEffectLayer.skyZ
        light.texture = EffectTextures.texture(named: "skyglow")
        light.anchorPoint = CGPoint(x: 0.5, y: 1)
        light.zRotation = .pi  // light from the bottom edge
        light.color = UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)
        light.colorBlendFactor = 1
        light.blendMode = .add
        light.zPosition = CanvasEffectLayer.overlayZ + 1
        for sprite in [planet, rim, light] { node.addChild(sprite) }
    }

    func layout(world: CGRect) {
        self.world = world
        let h = world.height
        // The disc fills 80 % of both textures.
        let side = h * Self.diameter / 0.8
        planet.size = CGSize(width: side, height: side)
        rim.size = planet.size
        light.size = CGSize(width: world.width * 1.04, height: h * 0.7)
        light.position = CGPoint(x: world.midX, y: world.minY - h * 0.01)
    }

    func apply(strength: Double, at time: TimeInterval) {
        let h = world.height
        let radius = h * Self.diameter / 2
        // From just hidden below the bottom edge to its top at 38 % height.
        let risen = h * 0.4 * strength
        let center = CGPoint(x: world.minX + world.width * 0.6, y: world.minY - radius - h * 0.02 + risen)
        planet.position = center
        planet.zRotation = 0.08 * sin(2 * .pi * time / 40)
        rim.position = center
        rim.alpha = strength * (0.6 + 0.06 * sin(2 * .pi * time / 7))
        light.alpha = strength * 0.14
    }
}
