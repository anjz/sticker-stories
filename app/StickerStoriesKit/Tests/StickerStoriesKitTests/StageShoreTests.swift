import Foundation
import Testing

@testable import StickerStoriesKit

/// A beach: sand in front, the sea behind it running on past the art's
/// left edge (not its right), and a rock pool on the right running on past
/// the art's right edge, as Beach's does on the wide art.
func shoreWorld() -> StageWorld {
    let space = SceneSpace(
        horizon: 0.5, ground: 0, back: 8, stand: .init(near: 1.1, far: 6), floor: 0.03,
        layers: [.init(id: "front", depth: 1)],
        places: [
            "sand": .init(ground: [
                .init(-0.5, 0.05), .init(1.5, 0.05), .init(1.5, 0.42), .init(0.9, 0.42), .init(0.7, 0.3), .init(-0.5, 0.3),
            ]),
            "sea": .init(ground: [.init(-0.5, 0.3), .init(0.7, 0.3), .init(0.9, 0.42), .init(-0.5, 0.42)], water: true),
            "pool": .init(
                ground: [.init(0.85, 0.08), .init(1.3, 0.08), .init(1.3, 0.28), .init(0.85, 0.28)], water: true, shallow: true),
        ],
        sizes: ["fox": 0.3, "turtle": 0.15, "ball": 0.1, "seal": 0.25, "fish": 0.1, "boat": 0.6, "bottle": 0.08])
    return StageWorld(space: space, aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1000, height: 750))
}

@Suite struct StageShoreTests {
    let world = shoreWorld()
    let screen = StageScreen(visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750))
    let fox = UUID(), turtle = UUID(), ball = UUID(), seal = UUID(), fish = UUID(), boat = UUID(), bottle = UUID()

    let trot = [StageMove(id: "trot", cycle: 0.8, stride: 0.6, facing: .right)]
    let turtleMoves = [
        StageMove(id: "crawl", cycle: 0.8, stride: 0.35, facing: .right),
        StageMove(id: "swim", cycle: 0.8, stride: 0.7, on: ["sea"], stays: true, waterline: 0.4, facing: .right),
    ]
    let swim = [StageMove(id: "swim", cycle: 0.8, stride: 0.7, on: ["sea"], stays: true, waterline: 0.4, facing: .left)]

    func actor(
        _ id: UUID, _ sticker: String, at feet: SceneSpace.Point? = nil, on: [String] = ["sand"], moves: [StageMove]
    ) -> StageActor {
        StageActor(
            id: id, stickerID: sticker, size: world.space.sizes[sticker] ?? 0.2, ratio: 1,
            stage: StickerStage(entrance: .hop, on: on), moves: moves, placed: feet)
    }

    func plan(
        _ actors: [StageActor], entrances: [EntranceTrigger] = [], goes: [GoTrigger] = [], seed: UInt64 = 7
    ) -> [UUID: StagePlan] {
        var random = SeededGenerator(state: seed)
        return StageDirector.plan(
            world: world, screen: screen, actors: actors, entrances: entrances, goes: goes, policy: .standard, random: &random)
    }

    /// The places along a leg's path, a hair off the waterline aside.
    func waters(along leg: StageLeg) -> [String?] {
        (0...60).compactMap { k -> String?? in
            let g = StagePlan.along(leg.path, Double(k) / 60).ground
            guard !world.grounds.contains(where: { $0.water && $0.polygon.distance(to: g) < 0.01 }) else { return nil }
            return .some(world.water(at: g))
        }
    }

    @Test func aWalkerNeverComesInThroughWaterRunningPastTheArtsEdge() throws {
        for seed in UInt64(1)...12 {
            let plans = plan([actor(fox, "fox", moves: trot)], entrances: [EntranceTrigger(at: 0, stickerID: "fox")], seed: seed)
            let leg = try #require(plans[fox]?.legs.first)
            #expect(waters(along: leg).allSatisfy { $0 == nil }, "seed \(seed)")
        }
    }

    @Test func aSwimmerComesInThroughItsWater() throws {
        for seed in UInt64(1)...12 {
            let plans = plan(
                [actor(turtle, "turtle", moves: turtleMoves)], entrances: [EntranceTrigger(at: 0, stickerID: "turtle", by: "swim")],
                seed: seed)
            let leg = try #require(plans[turtle]?.legs.first)
            #expect(leg.move == "swim" && waters(along: leg).allSatisfy { $0 == "sea" }, "seed \(seed)")
        }
    }

    @Test func intoTheSeaItTurnsOnTheSandAndSwimsStraightIn() throws {
        // Right of where the shore bends back: it walks left and up to the
        // nearest of the water's edge, then swims right, out to the fish.
        let plans = plan(
            [actor(turtle, "turtle", at: .init(0.97, 0.3), moves: turtleMoves),
             actor(fish, "fish", at: .init(0.86, 0.41), on: ["sea"], moves: swim)],
            goes: [GoTrigger(at: 1, stickerID: "turtle", kind: .to, target: "fish", by: "swim")])
        let legs = try #require(plans[turtle]?.legs)
        let walk = try #require(legs.first), swimming = try #require(legs.last)
        #expect(legs.count == 2 && walk.move == "crawl" && swimming.move == "swim")
        #expect(waters(along: walk).allSatisfy { $0 == nil } && waters(along: swimming).allSatisfy { $0 == "sea" })
        // Beside the fish, in the sea with it.
        let there = try #require(swimming.path.last).ground
        #expect(swimming.support == .beside(fish) && world.water(at: there) == "sea")
        // It sets off in the water the way it goes, never a step back
        // along the bank, having turned that way on the sand.
        let a = world.screen(swimming.path[0]).x, b = world.screen(swimming.path[1]).x
        let end = world.screen(try #require(swimming.path.last)).x
        #expect((b - a) * (end - a) >= 0)
        let first = swimming.ways.first?.facing ?? swimming.facingTo
        #expect(swimming.facingFrom == first && walk.facingTo == first)
    }

    @Test func aWalkerBySomeoneFarOutAtSeaStopsOnTheSand() throws {
        let plans = plan(
            [actor(ball, "ball", at: .init(0.5, 0.15), moves: trot),
             actor(seal, "seal", at: .init(0.3, 0.4), on: ["sea"], moves: swim)],
            goes: [GoTrigger(at: 1, stickerID: "ball", kind: .to, target: "seal")])
        let leg = try #require(plans[ball]?.legs.last)
        let end = try #require(leg.path.last).ground
        #expect(leg.support == .beside(seal))
        #expect(world.water(at: end) == nil && world.canStand(at: end, belongsIn: ["sand"]))
        #expect(waters(along: leg).allSatisfy { $0 == nil })
    }

    // MARK: Water-bound: every move a water move (a fish, a boat, a bottle)

    /// A fish that swims in both the rock pool and the sea.
    let fishSwim = [StageMove(id: "swim", cycle: 0.8, stride: 0.7, on: ["pool", "sea"], waterline: 0.3, facing: .right)]
    let sail = [StageMove(id: "sail", cycle: 0.8, stride: 0.6, on: ["sea"], waterline: 0.12, facing: .left)]
    let bob = [StageMove(id: "bob", cycle: 0.8, stride: 0.35, on: ["sea"], waterline: 0.35, facing: .right)]

    @Test func aWaterBoundStickerOnTheSandFadesIntoItsWaterAsTheStoryStarts() throws {
        // The child's boat on the sand, right in front of the seal out at sea.
        let plans = plan([
            actor(boat, "boat", at: .init(0.3, 0.15), on: ["sea"], moves: sail),
            actor(seal, "seal", at: .init(0.3, 0.33), on: ["sea"], moves: swim),
        ])
        let settle = try #require(plans[boat]?.legs.first)
        let there = try #require(settle.path.last)
        #expect(settle.kind == .settle && settle.gait == .fade && world.water(at: there.ground) == "sea")
        // Seen, and not hiding the seal either.
        let sealAt = try #require(plans[seal]).sample(at: 5).position
        let mine = world.drawing(at: there, size: 0.6, ratio: 1), theirs = world.drawing(at: sealAt, size: 0.25, ratio: 1)
        let front = there.z < sealAt.z
        #expect(StageWorld.hidden(front ? theirs : mine, behind: [front ? mine : theirs]) < 0.1)
    }

    @Test func aWaterBoundStickerFadesAcrossWhereItsWaterDoesNotReach() throws {
        // The fish in the rock pool, off to the sea and home again.
        let plans = plan(
            [actor(fish, "fish", at: .init(0.95, 0.18), on: ["pool"], moves: fishSwim)],
            goes: [GoTrigger(at: 1, stickerID: "fish", kind: .to, target: "sea"),
                   GoTrigger(at: 10, stickerID: "fish", kind: .to, target: "pool")])
        let legs = try #require(plans[fish]?.legs)
        #expect(legs.count == 2 && legs.allSatisfy { $0.gait == .fade })
        #expect(world.water(at: try #require(legs[0].path.last).ground) == "sea")
        #expect(world.water(at: try #require(legs[1].path.last).ground) == "pool")
        // Within the sea it swims.
        let swims = plan(
            [actor(fish, "fish", at: .init(0.2, 0.35), on: ["sea"], moves: fishSwim)],
            goes: [GoTrigger(at: 1, stickerID: "fish", kind: .to, target: "sea", another: true)])
        let leg = try #require(swims[fish]?.legs.last)
        #expect(leg.gait == .walk && leg.move == "swim" && waters(along: leg).allSatisfy { $0 == "sea" })
    }

    @Test func aWaterBoundStickerSentAshoreStopsAtTheWaterline() throws {
        let plans = plan(
            [actor(bottle, "bottle", on: ["sea"], moves: bob)],
            entrances: [EntranceTrigger(at: 0, stickerID: "bottle")],
            goes: [GoTrigger(at: 0, stickerID: "bottle", kind: .to, target: "sand"),
                   GoTrigger(at: 10, stickerID: "bottle", kind: .away)])
        let legs = try #require(plans[bottle]?.legs)
        let landed = try #require(legs.first?.path.last).ground
        let sand = try #require(world.grounds.first { $0.place == "sand" })
        #expect(legs.first?.move == "bob" && world.water(at: landed) == "sea" && sand.polygon.distance(to: landed) < 0.2)
        // In and off through the sea, never over the sand.
        for leg in legs { #expect(waters(along: leg).allSatisfy { $0 == "sea" }) }
    }
}
