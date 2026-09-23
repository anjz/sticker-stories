import SpriteKit

/// `current`: a gentle current sweeping through the water from the left.
/// Pale wisps show the moving water, and pale specks and little green bits
/// of weed are carried along on it, each bobbing on its own wave; all of
/// them come in from the left edge when the current starts.
@MainActor
final class CurrentPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wisps = DriftField(.init(
        count: 18, texture: EffectTextures.texture(named: "wisp"),
        colors: [UIColor(red: 0.8, green: 0.98, blue: 1, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 1,
        size: 0.012...0.022, aspect: 16,
        velocity: CGVector(dx: 0.55, dy: 0), depthSpeed: 0.6...1,
        wander: 0.02, wanderPeriod: 2.2...4,
        alpha: 0.3...0.55,
        region: CGRect(x: 0, y: 0.1, width: 1, height: 0.8),
        margin: CGVector(dx: 0.3, dy: 0),
        seed: 0xC022))
    private let specks = DriftField(.init(
        count: 40, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 0.9, green: 1, blue: 0.95, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 1,
        size: 0.005...0.011,
        velocity: CGVector(dx: 0.42, dy: 0), depthSpeed: 0.45...1,
        wander: 0.03, wanderPeriod: 1.6...3,
        alpha: 0.5...0.85,
        seed: 0x5BE2))
    private let weed = DriftField(.init(
        count: 14, texture: EffectTextures.texture(named: "leaf"),
        colors: [UIColor(red: 0.36, green: 0.66, blue: 0.34, alpha: 1), UIColor(red: 0.5, green: 0.72, blue: 0.3, alpha: 1)],
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.016...0.03, aspect: 0.69,
        velocity: CGVector(dx: 0.36, dy: 0), depthSpeed: 0.55...1,
        wander: 0.04, wanderPeriod: 2...3.5,
        spin: 0.8...2, flutter: 1.2...2.2,
        alpha: 0.85...1,
        region: CGRect(x: 0, y: 0.05, width: 1, height: 0.7),
        seed: 0x3EED))

    init() {
        for field in [wisps, specks, weed] { node.addChild(field.node) }
    }

    func layout(world: CGRect) {
        for field in [wisps, specks, weed] { field.layout(world: world) }
    }

    func apply(strength: Double, at time: TimeInterval) {
        for field in [wisps, specks, weed] { field.apply(strength: strength, at: time) }
    }

    func didTurnOff() {
        for field in [wisps, specks, weed] { field.reset() }
    }
}
