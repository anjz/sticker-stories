import SpriteKit

/// `glints`: the ground sparkling softly here and there, as the light
/// catches tiny beads of glass in the dust. Each glint swells and fades on
/// its own slow pulse (never a flash), over the ground and the scenery but
/// under the stickers standing in front.
@MainActor
final class GlintsPainter: CanvasEffectPainter {
    let node = SKNode()
    private let glints = DriftField(.init(
        count: 44, texture: EffectTextures.texture(named: "star"),
        colors: [.white, UIColor(red: 1, green: 0.95, blue: 0.8, alpha: 1), UIColor(red: 0.85, green: 0.93, blue: 1, alpha: 1)],
        blendMode: .add,
        zPosition: CanvasEffectLayer.groundZ,
        size: 0.009...0.02,
        alpha: 0.6...1,
        twinkle: 1, twinklePeriod: 1.6...3.2,
        region: CGRect(x: 0.02, y: 0.06, width: 0.96, height: 0.4),
        margin: .zero, enters: false,
        seed: 0x61B7))

    init() { node.addChild(glints.node) }

    func layout(world: CGRect) { glints.layout(world: world) }

    func apply(strength: Double, at time: TimeInterval) { glints.apply(strength: strength, at: time) }

    func didTurnOff() { glints.reset() }
}
