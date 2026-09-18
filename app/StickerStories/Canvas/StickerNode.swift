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
    /// Additive bloom behind the sprite for the `glow` effect; created on
    /// first use from the pack's cached blurred mask.
    private var glowNode: SKSpriteNode?

    private(set) var isSelected = false

    /// The child's placement while an effect owns this node's transform
    /// (`EffectApplier`); `nil` in edit mode. Snapshots read this so a
    /// mid-effect save never captures a wobble.
    var effectBase: StickerPlacement?

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

    // MARK: Effects (play mode only)

    /// The placement effects are deltas on: the saved base while an effect
    /// runs, otherwise the live node values.
    var placement: StickerPlacement {
        effectBase ?? StickerPlacement(
            x: position.x, y: position.y, rotation: zRotation, scale: baseScale, alpha: alpha)
    }

    func applyEffect(_ composed: ComposedPlacement, glowMask: () -> GlowMaskCache.Mask?) {
        position = CGPoint(x: composed.x, y: composed.y)
        zRotation = CGFloat(composed.rotation)
        setScale(CGFloat(composed.scale))
        alpha = CGFloat(composed.alpha)
        if composed.tintAmount > 0, let tint = composed.tintColor {
            color = UIColor(tint)
            colorBlendFactor = CGFloat(composed.tintAmount)
        } else {
            colorBlendFactor = 0
        }
        setGlow(composed.glow, color: composed.glowColor, mask: glowMask)
    }

    private func setGlow(_ amount: Double, color glowColor: RGBA?, mask: () -> GlowMaskCache.Mask?) {
        guard amount > 0 else {
            glowNode?.isHidden = true
            return
        }
        if glowNode == nil {
            guard let mask = mask() else { return }
            let glow = SKSpriteNode(texture: mask.texture)
            glow.size = CGSize(
                width: size.width * mask.sizeMultiplier * 1.05,
                height: size.height * mask.sizeMultiplier * 1.05)
            glow.zPosition = -0.5  // behind the sprite, in front of the shadow
            glow.blendMode = .add
            glow.colorBlendFactor = 1
            addChild(glow)
            glowNode = glow
        }
        glowNode?.color = UIColor(glowColor ?? .white)
        glowNode?.alpha = CGFloat(amount)
        glowNode?.isHidden = false
    }

    /// Puts the node back exactly where the child left it (P4).
    func restoreFromEffects() {
        guard let base = effectBase else { return }
        position = CGPoint(x: base.x, y: base.y)
        zRotation = CGFloat(base.rotation)
        setScale(CGFloat(base.scale))
        alpha = CGFloat(base.alpha)
        color = .clear
        colorBlendFactor = 0
        glowNode?.isHidden = true
        effectBase = nil
    }
}

extension UIColor {
    convenience init(_ rgba: RGBA) {
        self.init(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
