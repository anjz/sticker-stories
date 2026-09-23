import SpriteKit

/// `rainywindow`: a grey day seen from inside. The room turns cool and
/// grey, little beads of water sit on the glass, and drops trickle slowly
/// down it with a slight wiggle. Everything is faint: the child is looking
/// through the window, not at it.
@MainActor
final class RainyWindowPainter: CanvasEffectPainter {
    let node = SKNode()
    private let grey = SKSpriteNode()
    private let beads = DriftField(.init(
        count: 60, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.9, green: 0.94, blue: 1, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 1,
        size: 0.006...0.013,
        alpha: 0.25...0.5,
        margin: .zero, enters: false,
        seed: 0xBEAD))
    private let drops = DriftField(.init(
        count: 34, texture: EffectTextures.texture(named: "trickle"),
        colors: [UIColor(red: 0.9, green: 0.94, blue: 1, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.03...0.06, aspect: 0.33,
        velocity: CGVector(dx: 0, dy: -0.07), depthSpeed: 0.4...1,
        sway: 0.003, swayPeriod: 0.8...1.6,
        alpha: 0.35...0.6,
        enters: false,  // the glass is wet all over already
        seed: 0xD2B5))

    init() {
        grey.color = UIColor(red: 0.48, green: 0.54, blue: 0.64, alpha: 1)
        grey.zPosition = CanvasEffectLayer.overlayZ
        for child in [grey, beads.node, drops.node] { node.addChild(child) }
    }

    func layout(world: CGRect) {
        grey.size = CGSize(width: world.width * 1.02, height: world.height * 1.02)
        grey.position = CGPoint(x: world.midX, y: world.midY)
        beads.layout(world: world)
        drops.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        grey.alpha = strength * 0.3
        beads.apply(strength: strength, at: time)
        drops.apply(strength: strength, at: time)
    }

    func didTurnOff() {
        beads.reset()
        drops.reset()
    }
}
