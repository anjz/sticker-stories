import CoreImage
import SpriteKit
import StickerStoriesKit
import UIKit

/// A puppet ready to pose (`docs/pack-format.md`, "Puppets"): its rig, an
/// animation's keys, and every part's art and border cut from the atlas
/// once.
struct LoadedPuppet {
    let rig: PuppetRig
    let keys: [PuppetKey]
    let art: [String: SKTexture]
    let borders: [String: SKTexture]

    init(rig: PuppetRig, keys: [PuppetKey], atlas: SKTexture) {
        self.rig = rig
        self.keys = keys
        // Texture rects are unit, origin bottom-left; the atlas's are px, top-left.
        let size = atlas.size()
        func cut(_ r: [Double]) -> SKTexture {
            SKTexture(
                rect: CGRect(
                    x: r[0] / size.width, y: 1 - (r[1] + r[3]) / size.height,
                    width: r[2] / size.width, height: r[3] / size.height),
                in: atlas)
        }
        art = rig.parts.mapValues { cut($0.rect) }
        borders = rig.parts.mapValues { cut($0.border) }
    }

    /// The pose a tween of this animation shows with a face on.
    func pose(_ tween: LiveTween, face: String) -> PuppetPose {
        guard keys.indices.contains(tween.frame) else { return .rest(face: face, rig: rig) }
        let next = keys.indices.contains(tween.next) ? tween.next : tween.frame
        return .between(
            keys[tween.frame], keys[next], progress: tween.progress, face: face, rig: rig, wrapping: next < tween.frame)
    }
}

/// A sticker's puppet as SpriteKit nodes: one node per bone, carrying the
/// art of the slots on it. Laid over the sticker it lies exactly on its
/// drawing at rest, in the sticker's own unscaled space. The die-cut
/// border is every part's border silhouette drawn under all the art (the
/// union of the grown parts is the grown union), and the whole is drawn
/// flat into one layer so that fading it never shows one part through
/// another. A shadow puppet is the borders alone in black, blurred: the
/// sticker's drop shadow, posed with it.
final class PuppetNode: SKEffectNode {
    enum Look {
        case art
        /// A shadow blurred by this many points.
        case shadow(blur: CGFloat)
    }

    /// A flyer's wings as its flight has them now, kept going over an
    /// action it plays up in the air.
    struct Wings {
        let flight: LoadedPuppet
        let tween: LiveTween
        let bones: [String]
    }

    /// An action's face worn over the move that keeps it in the water:
    /// the surfer laughing as he paddles on (`PuppetPose.wearingFace`).
    struct FaceOver {
        let action: LoadedPuppet
        let tween: LiveTween
    }

    private struct SlotNodes {
        let border: SKSpriteNode
        let art: SKSpriteNode?
        var shown: String?
    }

    /// The rig and the keys of the animation playing (`adopt`).
    private(set) var puppet: LoadedPuppet
    /// Whether it has taken over from the sticker's still art: from then
    /// on it stays on show at full strength, between animations too
    /// (`park`), until the story ends.
    var settled = false
    /// Since when it has been idling between animations, if it is.
    private var parkedAt: TimeInterval?
    private var bones: [String: SKNode] = [:]
    private var slots: [String: SlotNodes] = [:]
    /// The sticker effect's tint on the art (`setTint`), kept so a part
    /// that comes on show later (a hand, a face swapped in) is tinted too.
    private var tint: (color: UIColor, amount: CGFloat)?
    /// What the bones and slots show now, and the tween it came from — to
    /// tell a jump (a move's loop cut short as the character arrives) and
    /// ease over it instead of popping.
    private var shownPose: PuppetPose?
    private var shownTween: LiveTween?
    private var jump: (from: PuppetPose, at: TimeInterval)?
    private static let jumpTime: TimeInterval = 0.18
    /// Holds the bones: cuts the puppet off at the waterline while it
    /// floats (`float`), showing it whole otherwise.
    private let crop = SKCropNode()
    private let span: CGSize

    /// - Parameter size: the sticker's unscaled size, which the rig's
    ///   square spans.
    init(_ puppet: LoadedPuppet, size: CGSize, look: Look) {
        self.puppet = puppet
        span = size
        super.init()
        let rig = puppet.rig
        let root = SKNode()
        // The rig's top-left at the sticker's top-left, its px to points.
        root.position = CGPoint(x: -size.width / 2, y: size.height / 2)
        root.setScale(size.width / rig.size)
        addChild(crop)
        crop.addChild(root)
        var rest: [String: CGPoint] = [:]
        for bone in rig.bones {
            let node = SKNode()
            let parent = bone.parent.flatMap { bones[$0] } ?? root
            let origin = bone.parent.flatMap { rest[$0] } ?? .zero
            node.position = CGPoint(x: bone.x - origin.x, y: -(bone.y - origin.y))
            node.userData = ["rest": node.position]
            parent.addChild(node)
            bones[bone.id] = node
            rest[bone.id] = CGPoint(x: bone.x, y: bone.y)
        }
        let isShadow: Bool
        switch look {
        case .art:
            isShadow = false
        case .shadow(let blur):
            isShadow = true
            let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            self.filter = filter
        }
        // Back to front; the borders all under the art. With sibling order
        // ignored, only z orders them.
        let count = CGFloat(max(rig.slots.count, 1))
        for (index, slot) in rig.slots.enumerated() {
            guard let bone = bones[slot.bone] else { continue }
            let border = SKSpriteNode()
            border.zPosition = CGFloat(index) / count * 0.01
            if isShadow {
                border.color = .black
                border.colorBlendFactor = 1
            }
            bone.addChild(border)
            var art: SKSpriteNode?
            if !isShadow {
                let sprite = SKSpriteNode()
                sprite.zPosition = 0.02 + CGFloat(index) / count * 0.01
                bone.addChild(sprite)
                art = sprite
            }
            slots[slot.id] = SlotNodes(border: border, art: art)
        }
        shouldEnableEffects = true
        shouldRasterize = false
        show(.rest(face: ExpressionTrigger.normal, rig: rig))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Poses the puppet as a tween of its animation shows with a face on.
    /// A tween that does not carry on from the last one (it is neither on
    /// the same key nor on the key that was next) eases over from the pose
    /// that was on show.
    /// `wings`: a flight beating on over it (`PuppetPose.flying`).
    /// `faceOver`: an action's face over it (`PuppetPose.wearingFace`).
    func show(
        _ tween: LiveTween, face: String, wings: Wings? = nil, faceOver: FaceOver? = nil, now: TimeInterval = CACurrentMediaTime()
    ) {
        var target = puppet.pose(tween, face: face)
        if let wings {
            target = target.flying(wings.bones, as: wings.flight.pose(wings.tween, face: face), rig: puppet.rig)
        }
        if let faceOver {
            target = target.wearingFace(of: faceOver.action.pose(faceOver.tween, face: face), rig: puppet.rig)
        }
        if let shown = shownPose,
            parkedAt != nil || shownTween.map({ tween.frame != $0.frame && tween.frame != $0.next }) ?? false
        {
            jump = (shown, now)
        }
        parkedAt = nil
        shownTween = tween
        show(target, easingAt: now)
    }

    /// Another animation of the same rig takes over: its keys, carrying on
    /// from the pose on show.
    func adopt(_ next: LoadedPuppet) {
        puppet = next
        shownTween = nil
        if let shown = shownPose { jump = (shown, CACurrentMediaTime()) }
    }

    /// Holds the puppet at rest between animations, alive
    /// (`PuppetPose.idle`), easing over from the pose it was in.
    func park(face: String, now: TimeInterval = CACurrentMediaTime()) {
        if parkedAt == nil {
            parkedAt = now
            shownTween = nil
            if let shown = shownPose { jump = (shown, now) }
        }
        show(.idle(at: now - (parkedAt ?? now), face: face, rig: puppet.rig), easingAt: now)
    }

    private func show(_ target: PuppetPose, easingAt now: TimeInterval) {
        var pose = target
        if let jump {
            let t = (now - jump.at) / Self.jumpTime
            if t >= 1 {
                self.jump = nil
            } else {
                pose = jump.from.mixed(with: target, t * t * (3 - 2 * t))
            }
        }
        show(pose)
    }

    func show(_ pose: PuppetPose) {
        shownPose = pose
        for bone in puppet.rig.bones {
            guard let node = bones[bone.id], let p = pose.bones[bone.id],
                let rest = node.userData?["rest"] as? CGPoint
            else { continue }
            node.position = CGPoint(x: rest.x + p.x, y: rest.y - p.y)
            node.zRotation = -p.r * .pi / 180
            node.xScale = p.sx
            node.yScale = p.sy
        }
        for slot in puppet.rig.slots {
            guard var nodes = slots[slot.id] else { continue }
            let name = pose.slots[slot.id] ?? slot.default
            guard name != nodes.shown else { continue }
            nodes.shown = name
            slots[slot.id] = nodes
            guard let attachment = slot.attachments[name], let part = puppet.rig.parts[attachment.part],
                let bone = puppet.rig.bones.first(where: { $0.id == slot.bone })
            else {
                nodes.border.isHidden = true
                nodes.art?.isHidden = true
                continue
            }
            let centre = CGPoint(
                x: attachment.x + attachment.w / 2 - bone.x, y: -(attachment.y + attachment.h / 2 - bone.y))
            let kx = attachment.w / part.rect[2], ky = attachment.h / part.rect[3]
            for (sprite, texture, size) in [
                (nodes.border, puppet.borders[attachment.part], CGSize(width: part.border[2] * kx, height: part.border[3] * ky)),
                (nodes.art, puppet.art[attachment.part], CGSize(width: attachment.w, height: attachment.h)),
            ] {
                guard let sprite else { continue }
                sprite.isHidden = false
                sprite.texture = texture
                sprite.size = size
                sprite.position = centre
                sprite.zRotation = -attachment.rotate * .pi / 180
                sprite.xScale = attachment.flip ? -1 : 1
            }
            if let art = nodes.art {
                art.userData = ["shade": attachment.shade]
                paint(art)
            }
        }
    }

    /// Afloat: everything below `waterline` (in the sticker's unscaled
    /// space) is under the water and hidden, and the puppet sinks by
    /// `sink` so that its waterline lies where its feet were. A `sink` of
    /// 0 shows it whole where it stands.
    func float(waterline: CGFloat, sink: CGFloat) {
        guard sink > 0.5 else {
            crop.maskNode = nil
            crop.position = .zero
            return
        }
        let mask = crop.maskNode as? SKSpriteNode ?? {
            // Wide and tall enough for wings spread and a jump.
            let m = SKSpriteNode(color: .white, size: CGSize(width: span.width * 4, height: span.height * 4))
            m.anchorPoint = CGPoint(x: 0.5, y: 0)
            crop.maskNode = m
            return m
        }()
        mask.position = CGPoint(x: 0, y: waterline)
        crop.position = CGPoint(x: 0, y: -sink)
    }

    /// Tints the art (a sticker effect's tint), keeping a part's shade.
    /// It stays on every part, those that come on show later included,
    /// until it is set again.
    func setTint(_ color: UIColor?, amount: CGFloat) {
        tint = color.flatMap { amount > 0 ? ($0, amount) : nil }
        for nodes in slots.values {
            if let art = nodes.art { paint(art) }
        }
    }

    /// A part's art in the tint, or else in its own shade.
    private func paint(_ art: SKSpriteNode) {
        if let tint {
            art.showTint(tint.color, amount: tint.amount)
        } else {
            art.clearTint(color: .black, factor: CGFloat(art.userData?["shade"] as? Double ?? 0))
        }
    }
}

extension StickerNode {
    /// The puppet takes over from the still art the way frames do
    /// (`showLive`): it fades in over the still art, which then dissolves
    /// away beneath it, and the drop shadow becomes the puppet's own.
    func beginPuppet(_ puppet: LoadedPuppet, key: String) {
        guard let stillTexture = texture else { return }
        let base = unscaledSize
        let node = PuppetNode(puppet, size: base, look: .art)
        node.name = Self.liveNodeName
        node.zPosition = 0.5  // over the sprite's own art, under nothing else of the node's
        node.alpha = 0
        addChild(node)
        let still = SKSpriteNode(texture: stillTexture, size: base)
        still.name = Self.liveStillName
        still.zPosition = 0.4
        addChild(still)
        still.color = color
        still.colorBlendFactor = colorBlendFactor
        if colorBlendFactor > 0 { node.setTint(color, amount: colorBlendFactor) }
        texture = nil
        color = .clear
        colorBlendFactor = 0
        liveStillTexture = stillTexture
        liveKey = key
        // The shadow's blur matches the still sticker's (`StickerShadowCache`).
        let blur = StickerShadowCache.blurFraction * max(base.width, base.height) * abs(xScale)
        beginPuppetShadow(
            PuppetNode(puppet, size: base, look: .shadow(blur: blur)),
            PuppetNode(puppet, size: base, look: .shadow(blur: blur)))
    }

    func showPuppet(
        state: LiveFrameState, tween: LiveTween?, wings: PuppetNode.Wings? = nil, faceOver: PuppetNode.FaceOver? = nil
    ) -> Int? {
        guard let node = puppetNode else { return nil }
        let tween = tween ?? LiveTween(frame: state.frame, next: state.frame, progress: 0)
        node.show(tween, face: face, wings: wings, faceOver: faceOver)
        for shadow in puppetShadows { shadow.show(tween, face: face, wings: wings) }
        // It dissolves in over the still art once; after that the
        // animations' own fades are hand-overs it no longer needs.
        if !node.settled, state.liveAlpha >= 1, state.stillAlpha <= 0 { node.settled = true }
        node.alpha = node.settled ? 1 : CGFloat(state.liveAlpha)
        childNode(withName: Self.liveStillName)?.alpha = node.settled ? 0 : CGFloat(state.stillAlpha)
        defer { liveFrame = state.frame }
        return state.frame != liveFrame ? state.frame : nil
    }

    /// Afloat in water (`StageWorld.afloat`): `depth` of its drawing's
    /// height (`drawing`, fractions of the image, origin bottom-left), from
    /// its feet, is under the water. The puppet and its shadows are cut off
    /// at the waterline and sunk by as much, so the waterline lies where
    /// its feet were, and ripples ring it there. 0 shows it whole again.
    /// Only a puppet floats: the still art stands where it is.
    func float(_ depth: Double, drawing: CGRect) {
        let base = unscaledSize
        let feet = CGPoint(x: (drawing.midX - 0.5) * base.width, y: (drawing.minY - 0.5) * base.height)
        let sink = puppetNode == nil ? 0 : CGFloat(depth) * drawing.height * base.height
        puppetNode?.float(waterline: feet.y + sink, sink: sink)
        for shadow in puppetShadows { shadow.float(waterline: feet.y + sink, sink: sink) }
        let ripple = childNode(withName: Self.rippleName)
        guard sink > 0.5 else {
            ripple?.removeFromParent()
            return
        }
        let rings = ripple ?? Self.makeRipple(width: drawing.width * base.width)
        if ripple == nil { addChild(rings) }
        rings.position = feet
        // Fully ringed once it is a little way in.
        rings.alpha = min(sink / max(0.06 * drawing.height * base.height, 1), 1)
    }

    private static let rippleName = "afloat-ripple"

    /// Ripples round a sticker afloat, `width` across: a ring where it
    /// meets the water and two more spreading out from it in turn, each
    /// in two halves — the far one behind the puppet, the near one in
    /// front, so the ring goes round it.
    private static func makeRipple(width: CGFloat) -> SKNode {
        let node = SKNode()
        node.name = rippleName
        let (back, front) = rippleHalves
        let size = CGSize(width: width * 1.15, height: width * 1.15 * 0.24)
        func ring(alpha: CGFloat) -> SKNode {
            let ring = SKNode()
            for (texture, z, y) in [(back, 0.45, size.height / 4), (front, 0.55, -size.height / 4)] {
                let half = SKSpriteNode(texture: texture, size: CGSize(width: size.width, height: size.height / 2))
                half.position = CGPoint(x: 0, y: y)
                half.zPosition = z
                half.alpha = alpha
                ring.addChild(half)
            }
            return ring
        }
        node.addChild(ring(alpha: 0.75))
        for delay in [0.0, 0.9] {
            let spreading = ring(alpha: 0.6)
            spreading.alpha = 0
            spreading.run(.sequence([
                .wait(forDuration: delay),
                .repeatForever(.sequence([
                    .group([.scale(to: 1, duration: 0), .fadeAlpha(to: 1, duration: 0)]),
                    .group([.scale(to: 1.45, duration: 1.8), .fadeOut(withDuration: 1.8)]),
                ])),
            ]))
            node.addChild(spreading)
        }
        return node
    }

    /// A ripple ring's far and near halves.
    private static let rippleHalves: (back: SKTexture, front: SKTexture) = {
        let size = CGSize(width: 256, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            cg.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
            cg.setLineWidth(5)
            cg.strokeEllipse(in: rect)
            cg.setStrokeColor(UIColor(red: 0.2, green: 0.45, blue: 0.55, alpha: 0.35).cgColor)
            cg.setLineWidth(3)
            cg.strokeEllipse(in: rect.insetBy(dx: 5, dy: 4))
        }
        let texture = SKTexture(image: image)
        // Texture rects have their origin at the bottom-left: the far half is the top.
        return (
            SKTexture(rect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), in: texture),
            SKTexture(rect: CGRect(x: 0, y: 0, width: 1, height: 0.5), in: texture)
        )
    }()

    /// The puppet on show, if any (an animation playing or parked).
    var puppetNode: PuppetNode? { childNode(withName: Self.liveNodeName) as? PuppetNode }

    /// Whether `showLive` can hand this animation to the puppet already on
    /// show (the same rig) rather than starting over from the still art.
    func continuePuppet(_ loaded: LoadedLiveAnimation) -> Bool {
        guard let puppet = loaded.puppet, let node = puppetNode, node.puppet.rig.atlas == puppet.rig.atlas else {
            return false
        }
        node.adopt(puppet)
        for shadow in puppetShadows { shadow.adopt(puppet) }
        liveKey = loaded.animation.key
        liveFrame = nil
        return true
    }

    /// No animation now: a puppet that has taken over stays, idling, until
    /// the story ends; anything else hands back to the still art.
    func parkLive() {
        guard let node = puppetNode, node.settled else { return stopLive() }
        liveKey = nil
        liveFrame = nil
        node.park(face: face)
        for shadow in puppetShadows { shadow.park(face: face) }
    }

    /// Ends a puppet on show, if one is: the still art is back underneath
    /// at once and the puppet fades off it.
    func stopPuppet() -> Bool {
        guard let node = puppetNode else { return false }
        node.name = nil
        node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        if let still = childNode(withName: Self.liveStillName) as? SKSpriteNode {
            still.removeFromParent()
            if still.colorBlendFactor > 0 {
                color = still.color
                colorBlendFactor = still.colorBlendFactor
            }
        }
        if let liveStillTexture { texture = liveStillTexture }
        liveStillTexture = nil
        endPuppetShadow()
        return true
    }
}
