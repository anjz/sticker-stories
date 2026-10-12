import SpriteKit
import StickerStoriesKit

/// A story played in a pack with a space (`SceneSpace`): every sticker is
/// at a depth, drawn in front of what is further away — the trees, the
/// reeds, the foreground and the other stickers sorted together — and as
/// big as its depth makes it, scaled about its feet.
///
/// - On the ground a sticker's depth is where its feet are along its way
///   (the hops' arcs and a flight's bob left out, so a jump never pops it
///   in front of anyone); up a tree or in the sky, the depth of that place
///   (`SceneSpace.elevated`); beside, on or under another sticker, just in
///   front of it (`MotionLeg.Rest`). Between two of those it goes as the
///   screen does (`SceneSpace.mix`).
/// - Every sticker is the size its depth makes it (`SceneSpace.sizes`): a
///   visitor comes in at the size of where it lands; one the child placed
///   eases from the size the child gave it to that over the story's first
///   moment (`settle`), whatever it was pinched to.
/// - At the same depth the one that got there last is in front.
/// - A sticker the child put in front of everything stays there until it
///   first moves.
@MainActor
final class DepthStage {
    let space: SceneSpace
    let wide: Bool
    /// The base art's frame in world points: what positions are fractions of.
    let world: CGSize
    /// Where each sticker's drawing sits in its image (fractions, origin
    /// bottom-left).
    private let drawing: (String) -> CGRect
    /// Each sticker's depth at its own spot (where the child put it, or
    /// where it came in).
    private(set) var home: [UUID: Double] = [:]
    /// Each sticker's depth last frame.
    private var now: [UUID: Double] = [:]
    /// The child's front-layer stickers, in front of everything until they
    /// first move, in their own order.
    private var inFront: [UUID: CGFloat] = [:]

    init(space: SceneSpace, wide: Bool, world: CGSize, drawing: @escaping (String) -> CGRect) {
        self.space = space
        self.wide = wide
        self.world = world
        self.drawing = drawing
    }

    /// Takes every sticker's depth at its own spot as play starts.
    func begin(_ nodes: [StickerNode]) {
        for node in nodes {
            home[node.instanceID] = space.depth(atFeet: feet(of: node, at: .home), wide: wide)
            if !node.isVisitor, node.canvasLayer == .foreground { inFront[node.instanceID] = node.zPosition }
        }
    }

    /// The scale a visitor comes in at: the size of where it lands, from
    /// the size it is drawn at while the child edits (`SceneSpace.editSize`).
    func visitorScale(_ node: StickerNode) -> Double {
        guard let size = space.sizes[node.stickerID], let edit = space.editSize(of: node.stickerID),
            let z = home[node.instanceID]
        else { return 1 }
        return space.drawnHeight(size: size, atDepth: z) / edit.height
    }

    /// Where a sticker's feet are on the art when its moves have it at
    /// `spot` (relative to its placement, `MotionSpot`).
    func feet(of node: StickerNode, at spot: MotionSpot) -> SceneSpace.Point {
        let base = node.effectBase ?? node.placement
        let unit = node.unscaledSize
        let box = drawing(node.stickerID)
        let x = base.x + spot.x * unit.width * base.scale
        let y = base.y - spot.y * unit.height * base.scale
            + (box.minY - 0.5) * unit.height * base.scale * spot.scale
        return .init(x / max(world.width, 1), y / max(world.height, 1))
    }

    /// The sticker's depth at `time`, along its moves.
    func depth(of node: StickerNode, plan: MotionPlan?, at time: TimeInterval) -> Double {
        let id = node.instanceID
        let fallback = home[id] ?? space.stand.near
        var z = fallback
        if let plan, let (index, along) = plan.progress(at: time) {
            let leg = plan.legs[index]
            let from = rest(index > 0 ? plan.legs[index - 1].rest : .home, at: leg.from, of: node) ?? fallback
            let to = rest(leg.rest, at: leg.to, of: node) ?? from
            z = along >= 1 ? to : SceneSpace.mix(from, to, along: along)
        }
        now[id] = z
        return z
    }

    /// The depth a sticker has resting at `spot`, or nil off the canvas.
    private func rest(_ rest: MotionLeg.Rest, at spot: MotionSpot, of node: StickerNode) -> Double? {
        switch rest {
        case .home:
            return home[node.instanceID]
        case .off:
            return nil
        case .with(let other):
            return (now[other] ?? home[other]).map { max($0 - SceneSpace.inFront, 0.05) }
        case .place(let name):
            let point = feet(of: node, at: spot)
            let place = space.places[name]
            return place?.lines != nil || place?.air != nil
                ? space.elevated(at: point, wide: wide) : space.depth(atFeet: point, wide: wide)
        case .ground:
            return space.depth(atFeet: feet(of: node, at: spot), wide: wide)
        }
    }

    /// How much bigger than its placement a sticker is at depth `z`: its
    /// size there over the size its placement draws it at (the edit size
    /// times its scale) — eased in over `settle` for one the child placed.
    func growth(of node: StickerNode, at z: Double, time: TimeInterval) -> Double {
        guard let size = space.sizes[node.stickerID], let edit = space.editSize(of: node.stickerID) else { return 1 }
        let base = node.effectBase ?? node.placement
        let k = space.drawnHeight(size: size, atDepth: z) / (edit.height * max(base.scale, 1e-3))
        guard !node.isVisitor else { return k }
        let p = min(max(time / Self.settle, 0), 1)
        return 1 + (k - 1) * p * p * (3 - 2 * p)
    }

    /// How long the child's stickers take to come to their size at the
    /// story's start.
    static let settle: TimeInterval = 1.2

    /// `delta` with the sticker grown by `k` about its feet.
    func grow(_ delta: EffectDelta, by k: Double, stickerID: String) -> EffectDelta {
        var delta = delta
        // Feet and the scale's pivot, as fractions of the height up from the
        // centre: growing about the pivot moves the feet by their distance
        // from it; the offset (y down, in rendered heights) puts them back.
        let feet = drawing(stickerID).minY - 0.5
        let pivot = 0.5 - delta.anchor.y
        delta.offsetYSelf += (feet - pivot) * delta.scaleMul * (k - 1)
        delta.scaleMul *= k
        return delta
    }

    /// Where a depth is in the scene's z order: nearer is higher, between
    /// the snow on the ground and the overlays (`CanvasEffectLayer`).
    func zPosition(forDepth z: Double) -> CGFloat {
        Self.nearZ - (Self.nearZ - Self.farZ) * CGFloat(min(max(z, 0), space.back) / space.back)
    }

    /// A sticker's z: by its depth, the one that got there later in front,
    /// a child's front-layer sticker in front of everything until it moves.
    func zPosition(of node: StickerNode, depth z: Double, plan: MotionPlan?, arrivedAt: TimeInterval, at time: TimeInterval) -> CGFloat {
        if let order = inFront[node.instanceID] {
            if plan?.progress(at: time) == nil { return zPosition(forDepth: 0) + 1 + order / 100 }
            inFront[node.instanceID] = nil
        }
        return zPosition(forDepth: z) + CGFloat(arrivedAt) * 1e-4
    }

    static let farZ: CGFloat = 260
    static let nearZ: CGFloat = 480
}
