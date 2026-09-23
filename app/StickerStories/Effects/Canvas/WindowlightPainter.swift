import SpriteKit

/// `windowlight`: morning sun through a window somewhere off the top left —
/// three soft parallel shafts (the panes) slanting down across the room,
/// with dust motes turning slowly inside the beam, and a faint warm lift
/// over everything. The motes live in the beam's own rotated frame, so they
/// never drift out of the light.
@MainActor
final class WindowlightPainter: CanvasEffectPainter {
    let node = SKNode()
    private let wash = SKSpriteNode()
    private let beam = SKNode()
    private var panes: [SKSpriteNode] = []
    /// Pane offsets across the beam, as fractions of the world height.
    private static let paneOffsets: [CGFloat] = [-0.15, 0, 0.15]
    private let motes = DriftField(.init(
        count: 46, texture: EffectTextures.texture(named: "dot"),
        colors: [UIColor(red: 1.0, green: 0.95, blue: 0.8, alpha: 1)],
        blendMode: .add,
        zPosition: CanvasEffectLayer.overlayZ + 2,
        size: 0.005...0.011,
        velocity: CGVector(dx: 0, dy: 0.006),
        sway: 0.02, swayPeriod: 7...13,
        wander: 0.02, wanderPeriod: 6...11,
        alpha: 0.45...0.9,
        twinkle: 0.6, twinklePeriod: 2.5...5,
        margin: CGVector(dx: 0, dy: 0.02), enters: false,
        seed: 0xD057))

    init() {
        wash.color = UIColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 1)
        wash.blendMode = .add
        wash.zPosition = CanvasEffectLayer.overlayZ
        node.addChild(wash)
        beam.zRotation = 0.62  // leaning down to the right
        node.addChild(beam)
        for _ in Self.paneOffsets {
            let pane = SKSpriteNode(texture: EffectTextures.texture(named: "ray"))
            pane.anchorPoint = CGPoint(x: 0.5, y: 1)
            pane.color = UIColor(red: 1.0, green: 0.9, blue: 0.68, alpha: 1)
            pane.colorBlendFactor = 1
            pane.blendMode = .add
            pane.zPosition = CanvasEffectLayer.overlayZ + 1
            beam.addChild(pane)
            panes.append(pane)
        }
        beam.addChild(motes.node)
    }

    func layout(world: CGRect) {
        let w = world.width, h = world.height
        wash.size = CGSize(width: w * 1.02, height: h * 1.02)
        wash.position = CGPoint(x: world.midX, y: world.midY)
        beam.position = CGPoint(x: world.minX + w * 0.16, y: world.maxY + h * 0.04)
        let length = h * 1.8
        for (pane, offset) in zip(panes, Self.paneOffsets) {
            pane.size = CGSize(width: h * 0.16, height: length)
            pane.position = CGPoint(x: h * offset, y: 0)
        }
        // The beam's frame: across its width, down its brighter first half.
        motes.layout(world: CGRect(x: -h * 0.22, y: -length * 0.55, width: h * 0.44, height: length * 0.52))
    }

    func apply(strength: Double, at time: TimeInterval) {
        wash.alpha = strength * 0.07
        for (index, pane) in panes.enumerated() {
            let breathe = sin(2 * .pi * time / 9 + Double(index) * 1.3)
            pane.alpha = strength * (0.34 + 0.05 * breathe)
        }
        motes.apply(strength: strength, at: time)
    }

    func didTurnOff() { motes.reset() }
}
