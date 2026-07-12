import SpriteKit
import StickerStoriesKit
import UIKit

/// A sticker instance on the canvas: the sprite, its soft drop shadow, and
/// (when selected) a white outline with the two control buttons —
/// send-to-back/bring-to-front and delete.
final class StickerNode: SKSpriteNode {
    /// Node names the scene uses to route button touches.
    enum ControlName {
        static let prefix = "sticker-control-"
        static let delete = "sticker-control-delete"
        static let layer = "sticker-control-layer"
    }

    let instanceID = UUID()
    let stickerID: String
    var canvasLayer: CanvasLayer = .foreground
    /// The sticker's resting scale, set by two-finger pinching. Lift/settle
    /// animations are relative to this so pinched size survives dragging.
    var baseScale: CGFloat = 1

    private let shadow: SKSpriteNode
    private var selectionOverlay: SKNode?
    private var controlButtons: [SKNode] = []

    private(set) var isSelected = false

    init(stickerID: String, texture: SKTexture, size: CGSize) {
        self.stickerID = stickerID
        shadow = SKSpriteNode(texture: texture)
        super.init(texture: texture, color: .clear, size: size)

        shadow.size = size
        shadow.color = .black
        shadow.colorBlendFactor = 1.0
        shadow.alpha = 0.22
        shadow.position = CGPoint(x: 0, y: -5)
        shadow.zPosition = -1
        addChild(shadow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Selection

    func setSelected(_ selected: Bool) {
        isSelected = selected
        selectionOverlay?.removeFromParent()
        selectionOverlay = nil
        controlButtons = []
        guard selected else { return }

        let overlay = SKNode()
        overlay.zPosition = 10

        let padding: CGFloat = 14
        let rect = CGRect(
            x: -size.width / 2 - padding, y: -size.height / 2 - padding,
            width: size.width + 2 * padding, height: size.height + 2 * padding)

        let outline = SKShapeNode(rect: rect, cornerRadius: 16)
        outline.strokeColor = .white
        outline.lineWidth = 4
        outline.fillColor = .clear
        outline.alpha = 0.95
        overlay.addChild(outline)

        let layerSymbol = canvasLayer == .foreground ? "square.3.layers.3d.bottom.filled" : "square.3.layers.3d.top.filled"
        controlButtons = [
            Self.makeControlButton(
                named: ControlName.layer, symbol: layerSymbol,
                fill: .systemBlue, at: CGPoint(x: rect.minX, y: rect.maxY)),
            Self.makeControlButton(
                named: ControlName.delete, symbol: "xmark",
                fill: .systemRed, at: CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for button in controlButtons {
            overlay.addChild(button)
        }

        addChild(overlay)
        selectionOverlay = overlay
        keepControlsUpright()
    }

    /// Control buttons ride on the (possibly rotated) sticker, but their
    /// glyphs should always read upright.
    func keepControlsUpright() {
        for button in controlButtons {
            button.zRotation = -zRotation
        }
    }

    /// Refreshes the layer button glyph after a send-to-back/bring-to-front.
    func refreshSelectionOverlay() {
        if isSelected { setSelected(true) }
    }

    // MARK: Shadow

    /// A slightly larger, further-offset shadow while the sticker is lifted.
    func setLifted(_ lifted: Bool) {
        shadow.position = lifted ? CGPoint(x: 0, y: -12) : CGPoint(x: 0, y: -5)
        shadow.alpha = lifted ? 0.30 : 0.22
    }

    // MARK: Controls

    private static func makeControlButton(named name: String, symbol: String, fill: UIColor, at position: CGPoint) -> SKNode {
        let radius: CGFloat = 30
        let button = SKShapeNode(circleOfRadius: radius)
        button.name = name
        button.fillColor = fill
        button.strokeColor = .white
        button.lineWidth = 3
        button.position = position
        button.zPosition = 1
        if let texture = symbolTexture(symbol, pointSize: 25, color: .white) {
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
