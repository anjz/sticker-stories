import SpriteKit
import StickerStoriesKit

/// A story played in a pack with a space (`docs/stage3d.md`): the
/// director plans every sticker's part in space (`StageDirector`), and each
/// frame this projects where each one is onto the screen — its feet's
/// point, its drawn size, its place in the order of depths — as the
/// placement its effects compose on.
@MainActor
final class StoryStage {
    let world: StageWorld
    let plans: [UUID: StagePlan]
    /// Each sticker's ways about (`StageMove`): how deep it floats.
    private let moves: [String: [StageMove]]
    /// Where each sticker's drawing sits in its image (fractions, origin
    /// bottom-left).
    private let drawing: (String) -> CGRect
    /// The child's placements, put back exactly when the story ends; each
    /// eases from its own to the stage's over the settle.
    private(set) var childPlacements: [UUID: StickerPlacement] = [:]

    init(
        world: StageWorld, plans: [UUID: StagePlan], moves: [String: [StageMove]], nodes: [StickerNode],
        drawing: @escaping (String) -> CGRect
    ) {
        self.world = world
        self.plans = plans
        self.moves = moves
        self.drawing = drawing
        for node in nodes where !node.isVisitor { childPlacements[node.instanceID] = node.placement }
    }

    /// The director's cast for these stickers (`StageActor`).
    static func actors(
        _ nodes: [StickerNode], space: SceneSpace, world: StageWorld, stages: [String: StickerStage],
        moves: [String: [StageMove]], fronts: [String: Double], statures: [String: StickerSize] = [:],
        drawing: (String) -> CGRect
    ) -> [StageActor] {
        nodes.map { node in
            let box = drawing(node.stickerID)
            let unit = node.unscaledSize
            let ratio = Double(box.width * unit.width) / max(Double(box.height * unit.height), 1e-6)
            var feet: SceneSpace.Point?
            if !node.isVisitor {
                let p = node.placement
                let x = p.x + (Double(box.midX) - 0.5) * Double(unit.width) * p.scale
                let y = p.y + (Double(box.minY) - 0.5) * Double(unit.height) * p.scale
                feet = .init(x / max(world.frame.width, 1), y / max(world.frame.height, 1))
            }
            return StageActor(
                id: node.instanceID, stickerID: node.stickerID, size: space.sizes[node.stickerID] ?? 0.2, ratio: ratio,
                stage: stages[node.stickerID] ?? .default, moves: moves[node.stickerID] ?? [],
                front: fronts[node.stickerID] ?? 0.4, placed: feet, facing: Double(node.facing),
                stature: statures[node.stickerID])
        }
    }

    /// Where a sticker is drawn at `time`: the placement its effects compose
    /// on, how visible it is, which way it faces, its z, and how deep it
    /// floats (`StageWorld.afloat`).
    func frame(of node: StickerNode, at time: TimeInterval) -> (
        base: StickerPlacement, opacity: Double, facing: Double, z: CGFloat, afloat: Double
    )? {
        guard let plan = plans[node.instanceID] else { return nil }
        let s = plan.sample(at: time)
        let box = drawing(node.stickerID)
        let unit = node.unscaledSize
        let feet = world.screen(s.position)
        let height = world.drawnHeight(size: plan.size, atDepth: s.position.z) * s.growth
        let scale = height / max(Double(box.height * unit.height), 1e-6)
        let mirror = s.facing < 0 ? -1.0 : 1.0
        var base = StickerPlacement(
            x: feet.x - (Double(box.midX) - 0.5) * Double(unit.width) * scale * mirror,
            y: feet.y + (0.5 - Double(box.minY)) * Double(unit.height) * scale,
            rotation: 0, scale: scale)
        // The child's stickers ease from where and how big the child had
        // them to the stage's, over the settle.
        if let child = childPlacements[node.instanceID], time < StageDirector.settle {
            let p = max(time, 0) / StageDirector.settle
            let k = p * p * (3 - 2 * p)
            base = StickerPlacement(
                x: child.x + (base.x - child.x) * k, y: child.y + (base.y - child.y) * k,
                rotation: child.rotation * (1 - k), scale: child.scale + (base.scale - child.scale) * k)
        }
        // Sinking in over its first half-height into the water.
        let afloat = world.afloat(at: s.position, moves: moves[node.stickerID] ?? [], ramp: plan.size * 0.5)
        return (base, s.opacity, s.facing, zPosition(forDepth: plan.drawnAt ?? s.position.z) + CGFloat(s.arrivedAt) * 1e-4, afloat)
    }

    /// Whether a sticker is out in open water at `time`: where a `surf-wave` cued
    /// then rises (`SurfWave.rises`).
    func inWater(_ node: StickerNode, at time: TimeInterval) -> Bool {
        guard let plan = plans[node.instanceID] else { return false }
        return SurfWave.rises(at: plan.sample(at: time).position, in: world)
    }

    /// The beach a `wash` cued on a sticker at `time` runs over
    /// (`Wash.beach`), its shore sampled across `range` (art `u`); nil
    /// without open water above it.
    func washBeach(_ node: StickerNode, at time: TimeInterval, across range: ClosedRange<Double>) -> Wash.Beach? {
        guard let plan = plans[node.instanceID] else { return nil }
        return Wash.beach(to: plan.sample(at: time).position, in: world, across: range, columns: 180)
    }

    /// The water a sticker is in at `time`, its feet down in it (afloat,
    /// or on a shallow bottom); nil on land or up in the air.
    func water(of node: StickerNode, at time: TimeInterval) -> String? {
        guard let p = plans[node.instanceID]?.sample(at: time).position, p.y < 0.01 else { return nil }
        return world.water(at: p.ground)
    }

    /// Where a depth is in the scene's z order: nearer is higher, between
    /// the snow on the ground and the overlays (`CanvasEffectLayer`).
    func zPosition(forDepth z: Double) -> CGFloat {
        let back = world.space.back
        return Self.nearZ - (Self.nearZ - Self.farZ) * CGFloat(min(max(z, 0), back) / back)
    }

    /// The move whose frames a sticker plays now, if any.
    func travel(of id: UUID, at time: TimeInterval) -> StageTravel? {
        plans[id]?.travel(at: time)
    }

    static let farZ: CGFloat = 260
    static let nearZ: CGFloat = 480
}
