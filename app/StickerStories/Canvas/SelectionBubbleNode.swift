import SpriteKit
import UIKit

/// The floating menu shown next to a selected sticker: layer toggle + delete
/// in a white capsule. It lives at scene level — never as a child of the
/// sticker — so it keeps exactly this size whatever the sticker's scale or
/// rotation. The scene positions it above/below/beside the sticker depending
/// on how close the sticker is to the edges.
final class SelectionBubbleNode: SKNode {
    /// Node names the scene uses to route button touches.
    enum ControlName {
        static let prefix = "sticker-control-"
        static let delete = "sticker-control-delete"
        static let layer = "sticker-control-layer"
    }

    /// Fixed footprint used both for drawing and for placement fitting.
    static let size = CGSize(width: 146, height: 74)

    private(set) weak var target: StickerNode?

    init(target: StickerNode) {
        self.target = target
        super.init()

        let shadow = SKShapeNode(rectOf: Self.size, cornerRadius: Self.size.height / 2)
        shadow.fillColor = UIColor.black.withAlphaComponent(0.16)
        shadow.strokeColor = .clear
        shadow.position = CGPoint(x: 0, y: -4)
        shadow.zPosition = -1
        addChild(shadow)

        let background = SKShapeNode(rectOf: Self.size, cornerRadius: Self.size.height / 2)
        background.fillColor = UIColor.white.withAlphaComponent(0.96)
        background.strokeColor = .white
        background.lineWidth = 1
        addChild(background)

        let layerSymbol = target.canvasLayer == .foreground
            ? "square.3.layers.3d.bottom.filled" : "square.3.layers.3d.top.filled"
        addChild(Self.makeButton(
            named: ControlName.layer, symbol: layerSymbol,
            fill: .systemBlue, at: CGPoint(x: -34, y: 0)))
        addChild(Self.makeButton(
            named: ControlName.delete, symbol: "xmark",
            fill: .systemRed, at: CGPoint(x: 34, y: 0)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func popIn() {
        setScale(0.6)
        alpha = 0
        run(.group([
            .fadeIn(withDuration: 0.12),
            .sequence([
                .scale(to: 1.07, duration: 0.12),
                .scale(to: 1.0, duration: 0.08),
            ]),
        ]))
    }

    // MARK: Buttons

    private static func makeButton(named name: String, symbol: String, fill: UIColor, at position: CGPoint) -> SKNode {
        let radius: CGFloat = 26
        let button = SKShapeNode(circleOfRadius: radius)
        button.name = name
        button.fillColor = fill
        button.strokeColor = .white
        button.lineWidth = 2.5
        button.position = position
        button.zPosition = 1
        if let texture = symbolTexture(symbol, pointSize: 22, color: .white) {
            let glyph = SKSpriteNode(texture: texture)
            glyph.name = name  // touches on the glyph route the same way
            let fit = min((radius * 1.15) / max(texture.size().width, texture.size().height), 1)
            glyph.setScale(fit)
            glyph.zPosition = 1
            button.addChild(glyph)
        }
        return button
    }

    private static func symbolTexture(_ systemName: String, pointSize: CGFloat, color: UIColor) -> SKTexture? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        guard
            let image = UIImage(systemName: systemName, withConfiguration: configuration)?
                .withTintColor(color, renderingMode: .alwaysOriginal)
        else { return nil }
        return SKTexture(image: image)
    }
}
