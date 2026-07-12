import SpriteKit
import StickerStoriesKit
import UIKit

/// A sticker instance on the canvas: the sprite and its soft drop shadow.
/// Selection UI is not drawn here — the scene shows a fixed-size
/// `SelectionBubbleNode` next to the selected sticker instead, so controls
/// never scale or rotate with the sticker.
final class StickerNode: SKSpriteNode {
    let instanceID = UUID()
    let stickerID: String
    var canvasLayer: CanvasLayer = .foreground
    /// The sticker's resting scale, set by two-finger pinching. Lift/settle
    /// animations are relative to this so pinched size survives dragging.
    var baseScale: CGFloat = 1

    private let shadow: SKSpriteNode

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

    func setSelected(_ selected: Bool) {
        isSelected = selected
    }

    /// A slightly larger, further-offset shadow while the sticker is lifted.
    func setLifted(_ lifted: Bool) {
        shadow.position = lifted ? CGPoint(x: 0, y: -12) : CGPoint(x: 0, y: -5)
        shadow.alpha = lifted ? 0.30 : 0.22
    }
}
