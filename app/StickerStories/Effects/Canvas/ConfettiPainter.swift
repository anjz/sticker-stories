import SpriteKit

/// `confetti`: a shower of paper confetti in bright party colours falling
/// in from the top over the whole scene, each piece spinning, swaying and
/// flipping over as it drifts down.
@MainActor
final class ConfettiPainter: CanvasEffectPainter {
    let node = SKNode()
    private let confetti = DriftField(.init(
        count: 140, texture: EffectTextures.texture(named: "confetti"),
        colors: [
            UIColor(red: 1.0, green: 0.36, blue: 0.42, alpha: 1), UIColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 1),
            UIColor(red: 0.3, green: 0.75, blue: 0.95, alpha: 1), UIColor(red: 0.45, green: 0.85, blue: 0.45, alpha: 1),
            UIColor(red: 0.72, green: 0.5, blue: 0.95, alpha: 1), UIColor(red: 1.0, green: 0.56, blue: 0.24, alpha: 1),
        ],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.016...0.028, aspect: 0.57,
        velocity: CGVector(dx: 0, dy: -0.22), depthSpeed: 0.55...1,
        sway: 0.03, swayPeriod: 1.5...3,
        spin: 1.5...4, flutter: 0.6...1.4,
        alpha: 0.9...1,
        seed: 0xC0FE))

    init() { node.addChild(confetti.node) }

    func layout(world: CGRect) { confetti.layout(world: world) }

    func apply(strength: Double, at time: TimeInterval) { confetti.apply(strength: strength, at: time) }

    func didTurnOff() { confetti.reset() }
}
