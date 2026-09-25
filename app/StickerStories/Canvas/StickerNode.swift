import SpriteKit
import StickerStoriesKit
import UIKit

/// A sticker instance on the canvas: the sprite and its drop shadow.
/// Selection UI is not drawn here — the scene shows a fixed-size
/// `SelectionBubbleNode` next to the selected sticker instead, so controls
/// never scale or rotate with the sticker.
///
/// The shadow is what sells the sticker as a real object stuck to the art:
/// two copies of a pre-blurred silhouette (`StickerShadowCache`) — a
/// tight, darker contact shadow hugging the edge and a fainter cast shadow
/// a little down-right, both kept small because a sticker lies flat on the
/// paper — lit from the top-left of the *screen*, so
/// the offsets are counter-rotated as the sticker turns and kept in world
/// points as it scales. Lifting a sticker peels it up: the contact shadow
/// nearly vanishes and the cast shadow drops away.
final class StickerNode: SKSpriteNode {
    let instanceID = UUID()
    let stickerID: String
    var canvasLayer: CanvasLayer = .foreground
    /// The sticker's resting scale, set by two-finger pinching. Lift/settle
    /// animations are relative to this so pinched size survives dragging.
    var baseScale: CGFloat = 1

    /// One shadow layer's look, in world points and screen space (y up).
    private struct ShadowPose {
        var offset: CGPoint
        var alpha: CGFloat
        var scale: CGFloat
    }
    private static let restingContact = ShadowPose(offset: CGPoint(x: 1, y: -2), alpha: 0.30, scale: 1.0)
    private static let restingCast = ShadowPose(offset: CGPoint(x: 3, y: -5), alpha: 0.12, scale: 1.02)
    private static let liftedContact = ShadowPose(offset: CGPoint(x: 3, y: -5), alpha: 0.10, scale: 1.0)
    private static let liftedCast = ShadowPose(offset: CGPoint(x: 12, y: -22), alpha: 0.24, scale: 1.1)

    private let contactShadow: SKSpriteNode
    private let castShadow: SKSpriteNode
    /// The still art's shadow, and its blur padding relative to the sprite
    /// (1 = none).
    private let shadowTexture: SKTexture
    private let shadowSizeMultiplier: CGFloat
    /// While a live animation plays (`showLive`), the shadows are sized to
    /// its frames and centred on its sprite instead of on this one.
    private var liveShadowSize: CGSize?
    private var liveShadowAnchor: CGPoint = .zero
    private var contactPose = StickerNode.restingContact
    private var castPose = StickerNode.restingCast
    /// Additive bloom behind the sprite for the `glow` effect; created on
    /// first use from the pack's cached blurred mask.
    private var glowNode: SKSpriteNode?

    private(set) var isSelected = false

    /// A sticker the story brought in because it names it and the child
    /// had not placed it (`CanvasScene.beginPlayMode`): never part of the
    /// child's canvas, and gone when the story ends.
    var isVisitor = false

    /// Which way the sticker faces while a story plays: 1 its art's own
    /// way, -1 mirrored (a visitor or a mover whose move frames travel the
    /// other way, `EntrancePlan.mirrored`, `MotionPlan.facing`), and in
    /// between while it turns round. The art, its faces and its frames all
    /// mirror together.
    var facing: CGFloat = 1

    /// The child's placement while an effect owns this node's transform
    /// (`EffectApplier`); `nil` in edit mode. Snapshots read this so a
    /// mid-effect save never captures a wobble.
    var effectBase: StickerPlacement?

    /// The sprite's own texture while a live animation stands in for it
    /// (`showLive`, `StickerAnimation.swift`); `nil` otherwise.
    var liveStillTexture: SKTexture?
    /// The live animation on show (`StickerAnimation.key`), if any.
    var liveKey: String?

    /// The expression the sticker shows (`showFace`, `StickerExpression.swift`);
    /// `normal` is its own image. Only stories change it, and play end
    /// puts it back.
    var face = ExpressionTrigger.normal

    /// - Parameter shadow: the pack's blurred silhouette for this sticker;
    ///   without one the sprite's own texture stands in (hard-edged).
    init(stickerID: String, texture: SKTexture, size: CGSize, shadow: StickerShadowCache.Shadow? = nil) {
        self.stickerID = stickerID
        shadowTexture = shadow?.texture ?? texture
        shadowSizeMultiplier = shadow?.sizeMultiplier ?? 1
        contactShadow = SKSpriteNode(texture: shadowTexture)
        castShadow = SKSpriteNode(texture: shadowTexture)
        super.init(texture: texture, color: .clear, size: size)

        for (layer, z) in [(contactShadow, -1.0), (castShadow, -1.1)] {
            layer.color = .black
            layer.colorBlendFactor = 1.0
            layer.zPosition = z
            addChild(layer)
        }
        layoutShadows()
        applyShadowPoses(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setSelected(_ selected: Bool) {
        isSelected = selected
    }

    /// Peels the sticker up: the contact shadow fades, the cast shadow drops
    /// further away and softens.
    func setLifted(_ lifted: Bool) {
        contactPose = lifted ? Self.liftedContact : Self.restingContact
        castPose = lifted ? Self.liftedCast : Self.restingCast
        applyShadowPoses(animated: true)
    }

    // The light comes from the top-left of the screen whatever the sticker
    // does, so the offsets are re-expressed in the node's own space every
    // time it turns or scales (effects drive both per frame).
    override var zRotation: CGFloat {
        didSet { applyShadowPoses(animated: false) }
    }
    override var xScale: CGFloat {
        didSet { applyShadowPoses(animated: false) }
    }
    override var yScale: CGFloat {
        didSet { applyShadowPoses(animated: false) }
    }

    /// Places each shadow layer for its pose: the world offset rotated into
    /// local space and divided by the scale so the gap under the sticker
    /// stays the same size on screen.
    private func applyShadowPoses(animated: Bool) {
        let c = cos(-zRotation), s = sin(-zRotation)
        // Signed: a mirrored sticker's own x runs the other way.
        let scaleX = xScale != 0 ? xScale : 1
        let scaleY = yScale != 0 ? yScale : 1
        for (layer, pose) in [(contactShadow, contactPose), (castShadow, castPose)] {
            let local = CGPoint(
                x: liveShadowAnchor.x + (pose.offset.x * c - pose.offset.y * s) / scaleX,
                y: liveShadowAnchor.y + (pose.offset.x * s + pose.offset.y * c) / scaleY)
            if animated {
                layer.removeAllActions()
                layer.run(.group([
                    .move(to: local, duration: 0.12),
                    .fadeAlpha(to: pose.alpha, duration: 0.12),
                    .scale(to: pose.scale, duration: 0.12),
                ]))
            } else if !layer.hasActions() {
                layer.position = local
                layer.alpha = pose.alpha
                layer.setScale(pose.scale)
            }
        }
    }

    private func layoutShadows() {
        let base = unscaledSize
        let size = liveShadowSize
            ?? CGSize(width: base.width * shadowSizeMultiplier, height: base.height * shadowSizeMultiplier)
        contactShadow.size = size
        castShadow.size = size
    }

    /// Hands the shadows to a live animation: sized to its frames and
    /// centred on its sprite (`anchor`, in this node's unscaled space);
    /// `setLiveShadow(_:)` then swaps the silhouette per frame.
    func beginLiveShadow(size: CGSize, anchor: CGPoint) {
        liveShadowSize = size
        liveShadowAnchor = anchor
        layoutShadows()
        applyShadowPoses(animated: false)
    }

    func setLiveShadow(_ texture: SKTexture) {
        contactShadow.texture = texture
        castShadow.texture = texture
    }

    /// The still art's own shadow again.
    func endLiveShadow() {
        liveShadowSize = nil
        liveShadowAnchor = .zero
        contactShadow.texture = shadowTexture
        castShadow.texture = shadowTexture
        layoutShadows()
        applyShadowPoses(animated: false)
    }

    /// `size` includes this node's own scale; children inherit that scale,
    /// so anything sized to match the sprite must use the unscaled size or
    /// a pinched sticker's shadow grows by the scale twice.
    var unscaledSize: CGSize {
        CGSize(
            width: abs(xScale != 0 ? size.width / xScale : size.width),
            height: abs(yScale != 0 ? size.height / yScale : size.height))
    }

    /// The world rescaled uniformly (window shape changed): keep the same
    /// spot on the art at the same relative size.
    func rescale(by ratio: CGFloat) {
        position = CGPoint(x: position.x * ratio, y: position.y * ratio)
        size = CGSize(width: size.width * ratio, height: size.height * ratio)
        layoutShadows()
        if let glowNode {
            glowNode.size = CGSize(width: glowNode.size.width * ratio, height: glowNode.size.height * ratio)
        }
        if var base = effectBase {
            base.x *= Double(ratio)
            base.y *= Double(ratio)
            effectBase = base
        }
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
        xScale *= facing
        alpha = CGFloat(composed.alpha)
        setTint(composed.tintAmount > 0 ? composed.tintColor : nil, amount: CGFloat(composed.tintAmount))
        setGlow(composed.glow, color: composed.glowColor, mask: glowMask)
    }

    /// Tints the art on show. While a live animation plays, the sprite has
    /// no texture of its own (its art moves to a child, `showLive`), and a
    /// texture-less sprite draws its `color` as a solid rectangle — so the
    /// sprite stays clear and the tint goes onto the frames and the still
    /// art underneath instead. With no tint, every colour goes back to
    /// clear, never left over from an earlier tint.
    private func setTint(_ tint: RGBA?, amount: CGFloat) {
        let live = liveSprites
        let targets: [SKSpriteNode] = texture == nil ? live : [self]
        for sprite in [self] + live {
            if let tint, targets.contains(sprite) {
                sprite.color = UIColor(tint)
                sprite.colorBlendFactor = amount
            } else {
                sprite.color = .clear
                sprite.colorBlendFactor = 0
            }
        }
    }

    private func setGlow(_ amount: Double, color glowColor: RGBA?, mask: () -> GlowMaskCache.Mask?) {
        guard amount > 0 else {
            glowNode?.isHidden = true
            return
        }
        if glowNode == nil {
            guard let mask = mask() else { return }
            let glow = SKSpriteNode(texture: mask.texture)
            let base = unscaledSize
            glow.size = CGSize(
                width: base.width * mask.sizeMultiplier * 1.05,
                height: base.height * mask.sizeMultiplier * 1.05)
            glow.zPosition = -0.5  // behind the sprite, in front of the shadows
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
