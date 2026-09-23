import SpriteKit

/// `seasnow`: the still, deep sea. Soft pale specks drift slowly down
/// through the water, swaying a little, over a faint haze. They fade in
/// where they are: at this speed, falling in from the top would take
/// longer than the effect lasts.
@MainActor
final class SeasnowPainter: CanvasEffectPainter {
    let node = SKNode()
    private let haze = SKSpriteNode()
    private let specks = DriftField(.init(
        count: 110, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.92, green: 0.96, blue: 0.9, alpha: 1), UIColor(red: 0.85, green: 0.92, blue: 0.95, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.004...0.011,
        velocity: CGVector(dx: 0.004, dy: -0.035), depthSpeed: 0.4...1,
        sway: 0.012, swayPeriod: 5...9,
        alpha: 0.35...0.8,
        enters: false,
        seed: 0x5EA5))

    init() {
        haze.color = UIColor(red: 0.8, green: 0.9, blue: 0.92, alpha: 1)
        haze.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(haze)
        node.addChild(specks.node)
    }

    func layout(world: CGRect) {
        haze.size = CGSize(width: world.width * 1.02, height: world.height * 1.02)
        haze.position = CGPoint(x: world.midX, y: world.midY)
        specks.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        haze.alpha = strength * 0.08
        specks.apply(strength: strength, at: time)
    }

    func didTurnOff() { specks.reset() }
}
