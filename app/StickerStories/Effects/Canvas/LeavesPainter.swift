import SpriteKit

/// `leaves`: autumn leaves in warm colours falling in from the top,
/// drifting to the right, swaying, turning and flipping over as they go.
@MainActor
final class LeavesPainter: CanvasEffectPainter {
    let node = SKNode()
    private let leaves = DriftField(.init(
        count: 42, texture: EffectTextures.texture(named: "leaf"),
        colors: [
            UIColor(red: 0.93, green: 0.52, blue: 0.16, alpha: 1), UIColor(red: 0.84, green: 0.3, blue: 0.18, alpha: 1),
            UIColor(red: 0.95, green: 0.74, blue: 0.22, alpha: 1), UIColor(red: 0.62, green: 0.38, blue: 0.2, alpha: 1),
        ],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.028...0.05, aspect: 0.69,
        velocity: CGVector(dx: 0.05, dy: -0.14), depthSpeed: 0.55...1,
        sway: 0.05, swayPeriod: 2.5...4.5,
        spin: 0.6...1.8, flutter: 1.2...2.4,
        alpha: 0.85...1,
        seed: 0x1EAF))

    init() { node.addChild(leaves.node) }

    func layout(world: CGRect) { leaves.layout(world: world) }

    func apply(strength: Double, at time: TimeInterval) { leaves.apply(strength: strength, at: time) }

    func didTurnOff() { leaves.reset() }
}
