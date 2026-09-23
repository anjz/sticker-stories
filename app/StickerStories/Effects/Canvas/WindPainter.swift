import SpriteKit

/// `wind`: pale wisps of air sweeping across the scene from the left, each
/// riding a slow wave, with small specks tumbling along faster and lower.
/// Both come in from the left edge when the wind gets up.
@MainActor
final class WindPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wisps = DriftField(.init(
        count: 24, texture: EffectTextures.texture(named: "wisp"),
        colors: [.white],
        zPosition: CanvasEffectLayer.overlayZ + 1,
        size: 0.014...0.026, aspect: 18,
        velocity: CGVector(dx: 0.95, dy: 0), depthSpeed: 0.6...1,
        wander: 0.012, wanderPeriod: 1.6...3,
        alpha: 0.5...0.8,
        region: CGRect(x: 0, y: 0.12, width: 1, height: 0.8),
        margin: CGVector(dx: 0.3, dy: 0),
        seed: 0x3170))
    private let specks = DriftField(.init(
        count: 30, texture: EffectTextures.texture(named: "dot"),
        colors: [
            UIColor(red: 0.62, green: 0.5, blue: 0.3, alpha: 1), UIColor(red: 0.5, green: 0.62, blue: 0.3, alpha: 1),
            UIColor(red: 0.8, green: 0.68, blue: 0.42, alpha: 1),
        ],
        zPosition: CanvasEffectLayer.overlayZ + 1,
        size: 0.006...0.013, aspect: 1.6,
        velocity: CGVector(dx: 0.75, dy: 0), depthSpeed: 0.5...1,
        wander: 0.035, wanderPeriod: 0.9...1.8,
        spin: 4...9,
        alpha: 0.7...0.95,
        region: CGRect(x: 0, y: 0.08, width: 1, height: 0.6),
        seed: 0x5BEC))

    init() {
        node.addChild(wisps.node)
        node.addChild(specks.node)
    }

    func layout(world: CGRect) {
        wisps.layout(world: world)
        specks.layout(world: world)
    }

    func apply(strength: Double, at time: TimeInterval) {
        wisps.apply(strength: strength, at: time)
        specks.apply(strength: strength, at: time)
    }

    func didTurnOff() {
        wisps.reset()
        specks.reset()
    }
}
