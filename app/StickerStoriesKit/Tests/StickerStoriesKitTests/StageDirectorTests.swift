import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import StickerStoriesKit

@Suite struct StageDirectorTests {
    let world = testWorld()
    let screen = StageScreen(visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750))
    let fox = UUID(), rabbit = UUID(), duck = UUID(), bee = UUID(), flower = UUID(), bird = UUID(), woodpecker = UUID()

    func actor(
        _ id: UUID, _ sticker: String, at feet: SceneSpace.Point? = nil,
        stage: StickerStage = StickerStage(entrance: .hop, on: ["meadow"]), moves: [StageMove] = []
    ) -> StageActor {
        StageActor(
            id: id, stickerID: sticker, size: testSpace().sizes[sticker] ?? 0.2, ratio: 1, stage: stage, moves: moves,
            placed: feet)
    }

    let trot = [StageMove(id: "trot", cycle: 0.8, stride: 0.6, facing: .right)]
    let flight = [StageMove(id: "fly", cycle: 0.5, stride: 1.2, flies: true, facing: .right)]
    let hovering = [StageMove(id: "fly", cycle: 0.5, stride: 1.2, flies: true, hovers: true, facing: .right)]

    func plan(_ actors: [StageActor], entrances: [EntranceTrigger] = [], goes: [GoTrigger] = []) -> [UUID: StagePlan] {
        var random = SeededGenerator(state: 7)
        return StageDirector.plan(
            world: world, screen: screen, actors: actors, entrances: entrances, goes: goes, policy: .standard,
            random: &random)
    }

    @Test func aChildsStickerInWaterItDoesNotBelongInSettlesOnLand() throws {
        let plans = plan([
            actor(fox, "fox", at: .init(0.55, 0.25), moves: trot),
            actor(duck, "duck", at: .init(0.55, 0.25), stage: StickerStage(entrance: .hop, on: ["pond"])),
        ])
        let foxPlan = try #require(plans[fox])
        let settle = try #require(foxPlan.legs.first)
        #expect(settle.kind == .settle)
        // At its walking pace, never less than the settle.
        #expect(settle.duration >= StageDirector.settle && settle.move == "trot")
        let settled = foxPlan.sample(at: settle.end).position.ground
        #expect(world.water(at: settled) == nil && world.canStand(at: settled, belongsIn: []))
        // The duck belongs in the pond: it stays.
        #expect(try #require(plans[duck]).legs.isEmpty)
    }

    @Test func walksFacingItsWayUnlessTheStorySaysBackwards() throws {
        // The fox's art faces right; the flower is to its left.
        let cast = [actor(fox, "fox", at: .init(0.8, 0.25), moves: trot), actor(flower, "flower", at: .init(0.2, 0.25))]
        let goes = [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "flower")]
        let walk = try #require(plan(cast, goes: goes)[fox])
        let leg = try #require(walk.legs.last)
        #expect(leg.facingTo == -1)
        // It turns on the spot first, then walks.
        #expect(walk.sample(at: leg.at + StagePlan.turn * 0.9).position == walk.sample(at: leg.at).position)
        #expect(walk.sample(at: leg.end).facing == -1)
        var backwards = goes[0]
        backwards.backwards = true
        let back = try #require(plan(cast, goes: [backwards])[fox])
        let backLeg = try #require(back.legs.last)
        #expect(backLeg.facingTo == 1)
        #expect(back.sample(at: backLeg.end).facing == 1)
    }

    @Test func goingToSomeoneAcrossThePondWalksRoundItAndStandsBesideThem() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.3, 0.25), moves: trot), actor(rabbit, "flower", at: .init(0.85, 0.25))],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "flower")])
        let leg = try #require(plans[fox]?.legs.last)
        #expect(leg.path.count > 2)  // round the pond
        for k in 0...50 {
            let p = StagePlan.along(leg.path, Double(k) / 50)
            #expect(world.water(at: p.ground) == nil)
        }
        let end = try #require(leg.path.last)
        let flowerAt = world.groundPoint(.init(0.85, 0.25))
        #expect(abs(end.z - (flowerAt.z - StageDirector.inFront)) < 0.05)  // at its depth, just in front
        #expect(leg.support == .beside(rabbit))
    }

    @Test func aBeeGoesOnTheFlowerAndABirdOntoTheBranch() throws {
        let plans = plan(
            [actor(bee, "bee", at: .init(0.3, 0.6), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: flight),
             actor(flower, "flower", at: .init(0.3, 0.15), stage: StickerStage(entrance: .grow, on: ["meadow"])),
             actor(bird, "bird", at: .init(0.6, 0.15), stage: StickerStage(entrance: .fly, on: ["branches"]), moves: flight)],
            goes: [GoTrigger(at: 1, stickerID: "bee", kind: .on, target: "flower"),
                   GoTrigger(at: 1, stickerID: "bird", kind: .to, target: "branches")])
        let beeEnd = try #require(plans[bee]?.sample(at: 10))
        let flowerAt = world.groundPoint(.init(0.3, 0.15))
        #expect(beeEnd.support == .on(flower) && beeEnd.position.y > 0.1 && beeEnd.position.z < flowerAt.z)
        let birdEnd = try #require(plans[bird]?.sample(at: 10))
        #expect(birdEnd.support == .perch("branches") && abs(birdEnd.position.z - (2 - StageDirector.inFront)) < 1e-9)
        #expect(plans[bird]?.legs.last?.gait == .fly)
    }

    @Test func aVisitorComesInFromTheSideOntoLandOnScreen() throws {
        let plans = plan([actor(fox, "fox", moves: trot)], entrances: [EntranceTrigger(at: 2, stickerID: "fox")])
        let p = try #require(plans[fox])
        #expect(p.sample(at: 1).opacity == 0)
        let leg = try #require(p.legs.first)
        #expect(leg.kind == .entrance && leg.at == 2)
        let start = try #require(leg.path.first), end = try #require(leg.path.last)
        let u = world.project(start).u
        #expect(u < 0 || u > 1)  // off the art at a side
        #expect(world.canStand(at: end.ground, belongsIn: []))
        let r = world.drawing(at: end, size: 0.3, ratio: 1)
        #expect(r.minX >= 0 && r.maxX <= 1000 && r.minY >= 0 && r.maxY <= 750)
    }

    @Test func awayAndBack() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.3, 0.15), moves: trot)],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .away), GoTrigger(at: 10, stickerID: "fox", kind: .back)])
        let p = try #require(plans[fox])
        #expect(p.sample(at: 9).opacity == 0)
        let home = world.groundPoint(.init(0.3, 0.15))
        let back = p.sample(at: 30)
        #expect(back.opacity == 1 && (back.position.ground - home).length < 1e-6)
    }

    /// A sticker the story does not use, standing where the cast will
    /// walk, steps aside as the story starts; one out of the way stays.
    @Test func extrasInTheWayStepAside() throws {
        let bear = UUID(), deer = UUID()
        var random = SeededGenerator(state: 3)
        let plans = StageDirector.plan(
            world: world, screen: screen,
            actors: [actor(fox, "fox", at: .init(0.2, 0.12), moves: trot),
                     actor(rabbit, "rabbit", at: .init(0.8, 0.12), moves: trot),
                     actor(bear, "bear", at: .init(0.5, 0.12), moves: trot),
                     actor(deer, "fox", at: .init(0.9, 0.38), moves: trot)],
            entrances: [], goes: [GoTrigger(at: 2, stickerID: "fox", kind: .to, target: "rabbit")],
            policy: .standard, cast: ["fox", "rabbit"], random: &random)
        let moved = try #require(plans[bear])
        #expect(moved.legs.first?.kind == .settle && moved.legs.first?.at == 0)
        let start = world.groundPoint(.init(0.5, 0.12))
        #expect((moved.sample(at: 30).position.ground - start).length > 0.3)
        // The far "fox" is the same sticker as the cast's: it is cast too.
        #expect(plans[deer]?.legs.allSatisfy { $0.kind != .settle } ?? true)
    }

    /// Stepping aside, never behind a tree.
    @Test func extrasStepAsideIntoView() throws {
        let bear = UUID()
        let w = covered(world)
        for seed in 1...6 {
            var random = SeededGenerator(state: UInt64(seed))
            let plans = StageDirector.plan(
                world: w, screen: screen,
                actors: [actor(fox, "fox", at: .init(0.2, 0.12), moves: trot),
                         actor(rabbit, "rabbit", at: .init(0.8, 0.12), moves: trot),
                         actor(bear, "bear", at: .init(0.5, 0.12), moves: trot)],
                entrances: [], goes: [GoTrigger(at: 2, stickerID: "fox", kind: .to, target: "rabbit")],
                policy: .standard, cast: ["fox", "rabbit"], random: &random)
            let p = try #require(plans[bear]).sample(at: 30).position
            var r = w.drawing(at: p, size: 0.5, ratio: 1)
            r.maxY += (r.maxY - r.minY) * 0.5
            #expect(w.hidden(r, atDepth: p.z) < 0.05)
        }
    }

    /// A walker's steps keep pace with the ground: its leg takes as long
    /// as its steps take to cover the way, at a rate near the drawn one.
    @Test func walkersNeverGlide() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.15, 0.15), moves: trot), actor(rabbit, "rabbit", at: .init(0.45, 0.25))],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let leg = try #require(plans[fox]?.legs.last)
        #expect(leg.gait == .walk && leg.move == "trot")
        #expect(StageDirector.rates.contains(leg.rate))
        let length = zip(leg.path, leg.path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
        let speed = 0.6 * (testSpace().sizes["fox"] ?? 0.2) / 0.8  // stride × width ÷ cycle
        #expect(abs(leg.duration * leg.rate * speed - length) < 1e-6)
        // A long way never keeps the story waiting: it hurries.
        let far = plan([actor(fox, "fox", at: .init(0.06, 0.07), moves: trot), actor(rabbit, "rabbit", at: .init(0.94, 0.38))],
                       goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let long = try #require(far[fox]?.legs.last)
        #expect(long.duration <= StageDirector.maxTravel + 1e-9 && long.rate > 1)
    }

    /// An action cued while its sticker is on its way waits until it gets
    /// there; one cued when it is still plays then — unless someone is on
    /// the way to it (the rabbit waits for the fox).
    @Test func actionsWaitForTheMoveToEnd() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.15, 0.15), moves: trot), actor(rabbit, "rabbit", at: .init(0.8, 0.4))],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let leg = try #require(plans[fox]?.legs.last)
        let live = StageDirector.delayed(
            [LiveAnimationTrigger(at: 1.5, stickerID: "fox", animationID: "jump"),
             LiveAnimationTrigger(at: 0.5, stickerID: "fox", animationID: "nod"),
             LiveAnimationTrigger(at: 1.5, stickerID: "rabbit", animationID: "nod")],
            plans: plans, stickers: [fox: "fox", rabbit: "rabbit"], places: [])
        #expect(live.map(\.at) == [leg.end, 0.5, min(leg.end, 1.5 + StageDirector.reactionWait)])
    }

    /// A flyer resting in the air keeps its wings going: one that flies to
    /// the sky, and one the child put there.
    @Test func flyersInTheAirKeepFlying() throws {
        let plans = plan(
            [actor(bee, "bee", at: .init(0.5, 0.7), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: hovering),
             actor(bird, "bird", at: .init(0.3, 0.15), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: hovering)],
            goes: [GoTrigger(at: 1, stickerID: "bird", kind: .to, target: "sky")])
        let hover = try #require(plans[bee]?.travel(at: 5))
        #expect(hover.move == "fly" && hover.stays)
        let flight = try #require(plans[bird]?.travel(at: 30))
        #expect(flight.move == "fly" && flight.stays && !flight.isMoving(at: 30))
        // Bobbing gently where it is.
        let a = try #require(plans[bird]?.sample(at: 30)), b = try #require(plans[bird]?.sample(at: 30.4))
        #expect(a.position.y != b.position.y && abs(a.position.y - b.position.y) < 0.05)
        #expect(a.position.x == b.position.x && a.position.z == b.position.z)
    }

    /// One that cannot hover never stops in the air: it flies a loop round
    /// its spot, turning at each end, on screen, until it goes on — from
    /// wherever it is on the loop, without a jump.
    @Test func flyersThatCannotHoverCircle() throws {
        let plans = plan(
            [actor(bird, "bird", at: .init(0.3, 0.15), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: flight),
             actor(fox, "fox", at: .init(0.7, 0.2), moves: trot)],
            goes: [GoTrigger(at: 1, stickerID: "bird", kind: .to, target: "sky"),
                   GoTrigger(at: 21.3, stickerID: "bird", kind: .to, target: "fox")])
        let bird = try #require(plans[self.bird])
        let up = try #require(bird.legs.first { $0.at == 1 })
        let loop = try #require(up.circling)
        #expect(up.stays && loop.across > 0 && loop.toward > 0)
        let lap = stride(from: up.end + 2, to: up.end + 7, by: 0.1).map { bird.sample(at: $0) }
        let xs = lap.map(\.position.x), zs = lap.map(\.position.z)
        #expect(xs.max()! - xs.min()! > loop.across && zs.max()! - zs.min()! > loop.toward / 2)
        // Out its way, back the other.
        #expect(lap.contains { $0.facing > 0.9 } && lap.contains { $0.facing < -0.9 })
        for sample in lap {
            let r = world.drawing(at: sample.position, size: testSpace().sizes["bird"] ?? 0.2, ratio: 1)
            #expect(r.minX >= 0 && r.maxX <= 1000 && r.minY >= 0 && r.maxY <= 750)
        }
        // On to the fox from where it was on its loop.
        let next = try #require(bird.legs.first { $0.at == 21.3 })
        let before = bird.sample(at: next.at - 0.01), after = bird.sample(at: next.at + 0.01)
        #expect((before.position - after.position).length < 0.02)
        #expect(abs(before.facing - after.facing) < 0.2)
        #expect((bird.sample(at: next.end).position - next.path.last!).length < 1e-6)
    }

    /// The world with a plane at depth 2 painted over the art's right
    /// third (a tree): what stands behind it there is hidden.
    func covered(_ w: StageWorld) -> StageWorld {
        var w = w
        var cells = [Bool](repeating: false, count: 30 * 30)
        for r in 0..<30 { for c in 20..<30 { cells[r * 30 + c] = true } }
        w.covers = [.init(depth: 2, grid: OpaqueGrid(columns: 30, rows: 30, cells: cells), area: StageRect(minX: 0, minY: 0, maxX: 1, maxY: 1))]
        return w
    }

    @Test func planesInFrontHideWhatIsBehindThem() {
        let w = covered(world)
        let behind = w.groundPoint(.init(0.85, 0.3)).onGround, before = w.groundPoint(.init(0.85, 0.15)).onGround
        #expect(w.hidden(w.drawing(at: behind, size: 0.2, ratio: 0.5), atDepth: behind.z) == 1)
        #expect(w.hidden(w.drawing(at: before, size: 0.2, ratio: 0.5), atDepth: before.z) == 0)
    }

    /// Where the director chooses, a tiny visitor comes to the front, and
    /// nobody lands behind the tree.
    @Test func smallOnesComeToTheFrontAndNobodyLandsBehindATree() throws {
        let w = covered(world)
        let meadow = StickerStage(entrance: .hop, on: ["meadow"])
        for seed in 1...8 {
            var random = SeededGenerator(state: UInt64(seed))
            let plans = StageDirector.plan(
                world: w, screen: screen,
                actors: [StageActor(id: bee, stickerID: "bee", size: 0.06, ratio: 1, stage: meadow, stature: .tiny),
                         StageActor(id: bird, stickerID: "bird", size: 0.1, ratio: 1, stage: meadow, stature: .small),
                         StageActor(id: fox, stickerID: "fox", size: 0.3, ratio: 1, stage: meadow, stature: .big)],
                entrances: [EntranceTrigger(at: 1, stickerID: "bee"), EntranceTrigger(at: 1, stickerID: "bird"),
                            EntranceTrigger(at: 1, stickerID: "fox")],
                goes: [], policy: .standard, random: &random)
            let near = w.space.stand.near, far = w.space.stand.far
            for (id, size) in [(bee, 0.06), (bird, 0.1), (fox, 0.3)] {
                let p = try #require(plans[id]).sample(at: 30).position
                #expect(w.hidden(w.drawing(at: p, size: size, ratio: 1), atDepth: p.z) < 0.2)
                if id != fox { #expect(p.z < near + (far - near) * 0.3) }
            }
        }
    }

    /// A child's sticker its depth puts behind the tree steps out to where
    /// it shows.
    @Test func aChildsStickerBehindATreeStepsOut() throws {
        var random = SeededGenerator(state: 7)
        let w = covered(world)
        let plans = StageDirector.plan(
            world: w, screen: screen, actors: [actor(fox, "fox", at: .init(0.85, 0.3), moves: trot)], entrances: [],
            goes: [], policy: .standard, random: &random)
        let leg = try #require(plans[fox]?.legs.first)
        #expect(leg.kind == .settle)
        let p = try #require(plans[fox]).sample(at: leg.end).position
        #expect(w.hidden(w.drawing(at: p, size: 0.3, ratio: 1), atDepth: p.z) < 0.15)
    }

    /// Something that never moves (the flower) stays where the child put
    /// it behind the tree, drawn in front of the tree, as the child saw it.
    @Test func somethingThatNeverMovesBehindATreeStaysDrawnInFrontOfIt() throws {
        var random = SeededGenerator(state: 7)
        let w = covered(world)
        let feet = SceneSpace.Point(0.85, 0.3)
        let flower = StageActor(
            id: fox, stickerID: "fox", size: 0.3, ratio: 1, stage: StickerStage(entrance: .grow, on: ["meadow"]), placed: feet)
        let plan = try #require(StageDirector.plan(
            world: w, screen: screen, actors: [flower], entrances: [], goes: [], policy: .standard, random: &random)[fox])
        #expect(plan.legs.isEmpty)
        let p = plan.sample(at: 10).position
        #expect((p - w.groundPoint(feet).onGround).length < 1e-9)
        let drawnAt = try #require(plan.drawnAt)
        #expect(drawnAt < 2 && w.hidden(w.drawing(at: p, size: 0.3, ratio: 1), atDepth: drawnAt) == 0)
    }

    @Test func theWoodpeckerFacesTheBark() throws {
        let plans = plan(
            [actor(woodpecker, "woodpecker", at: .init(0.5, 0.15), stage: StickerStage(entrance: .fly, on: ["trunks"]),
                   moves: [StageMove(id: "fly", cycle: 0.5, stride: 1, flies: true, facing: .right)])],
            goes: [GoTrigger(at: 1, stickerID: "woodpecker", kind: .to, target: "trunks")])
        let end = try #require(plans[woodpecker]?.sample(at: 10))
        #expect(end.support == .perch("trunks"))
        // Facing left (its moves face right: mirrored), its centre right of the bark.
        #expect(end.facing == -1)
        let bark = world.point(.init(0.15, 0.5), atDepth: 2)
        #expect(end.position.x > bark.x)
    }
}

extension StageDirectorTests {
    @Test func theWoodpeckerClingsToTheBarkItStaysOn() throws {
        let moves = [
            StageMove(id: "fly", cycle: 0.5, stride: 1, flies: true, facing: .right),
            StageMove(id: "cling", cycle: 0.8, stride: 0, on: ["trunks"], stays: true, facing: .right),
        ]
        let plans = plan(
            [actor(woodpecker, "woodpecker", at: .init(0.5, 0.15), stage: StickerStage(entrance: .fly, on: ["meadow"]), moves: moves)],
            goes: [
                GoTrigger(at: 1, stickerID: "woodpecker", kind: .to, target: "trunks"),
                GoTrigger(at: 9, stickerID: "woodpecker", kind: .away),
            ])
        let legs = try #require(plans[woodpecker]?.legs)
        let flight = try #require(legs.first { $0.move == "fly" })
        let cling = try #require(legs.first { $0.move == "cling" })
        // As it gets to the bark it takes to clinging, where it is, and stays.
        #expect(cling.at == flight.end && cling.stays && cling.support == .perch("trunks"))
        #expect(cling.path.first == cling.path.last && cling.path.last == flight.path.last)
        // It flies off by its usual way.
        #expect(legs.last?.move == "fly" && (legs.last?.at ?? 0) >= 9)
        // Its own flight to a branch does not cling.
        let branch = plan(
            [actor(woodpecker, "woodpecker", at: .init(0.5, 0.15), stage: StickerStage(entrance: .fly, on: ["meadow"]), moves: moves)],
            goes: [GoTrigger(at: 1, stickerID: "woodpecker", kind: .to, target: "meadow")])
        #expect(branch[woodpecker]?.legs.contains { $0.move == "cling" } != true)
    }

    @Test func aDucklingAfloatSwimsToTheBankBeforeItWaddlesOff() throws {
        let moves = [
            StageMove(id: "waddle", cycle: 0.8, stride: 0.5, facing: .right),
            StageMove(id: "swim", cycle: 0.8, stride: 0.5, on: ["pond"], waterline: 0.25, facing: .right),
        ]
        let plans = plan(
            [actor(duck, "duckling", moves: moves), actor(fox, "fox", at: .init(0.15, 0.25), moves: trot)],
            entrances: [EntranceTrigger(at: 0, stickerID: "duckling", by: "swim")],
            goes: [GoTrigger(at: 8, stickerID: "duckling", kind: .to, target: "fox")])
        let legs = try #require(plans[duck]?.legs)
        let afloat = try #require(legs.first)
        let landed = try #require(afloat.path.last)
        #expect(afloat.move == "swim" && world.water(at: landed.ground) != nil)
        // Out of the water swimming, then on foot to the fox.
        let out = legs.filter { $0.at >= 8 }
        #expect(out.count == 2 && out[0].move == "swim" && out[1].move == "waddle")
        for k in 0...20 {
            #expect(world.water(at: StagePlan.along(out[1].path, Double(k) / 20).ground) == nil, "k \(k)")
        }
    }

    @Test func whoeverSomeoneIsComingToReactsWhenTheyGetThere() throws {
        let cast = [actor(fox, "fox", at: .init(0.15, 0.25), moves: trot), actor(flower, "flower", at: .init(0.5, 0.25))]
        let plans = plan(cast, goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "flower")])
        let leg = try #require(plans[fox]?.legs.last)
        let stickers = [fox: "fox", flower: "flower"]
        // The flower's cue while the fox is on its way waits for it…
        let waited = StageDirector.reaction(at: leg.at + 0.2, of: "flower", plans: plans, stickers: stickers)
        #expect(waited == min(leg.end, leg.at + 0.2 + StageDirector.reactionWait))
        // …not one before it sets off or after it is there, nor anyone else's.
        #expect(StageDirector.reaction(at: leg.at - 0.5, of: "flower", plans: plans, stickers: stickers) == leg.at - 0.5)
        #expect(StageDirector.reaction(at: leg.end + 0.1, of: "flower", plans: plans, stickers: stickers) == leg.end + 0.1)
        #expect(StageDirector.reaction(at: leg.at + 0.2, of: "fox", plans: plans, stickers: stickers) == leg.at + 0.2)
        let live = StageDirector.delayed(
            [LiveAnimationTrigger(at: leg.at + 0.2, stickerID: "flower", animationID: "sway")], plans: plans, stickers: stickers,
            places: [])
        #expect(live.first?.at == waited)
    }

    @Test func aVisitorComesInNearWhomTheStoryPutsItWith() throws {
        let cast = [actor(fox, "fox", moves: trot), actor(flower, "flower", at: .init(0.75, 0.3))]
        let flowerAt = world.groundPoint(.init(0.75, 0.3)).onGround
        // Sent to the flower as it comes in: straight to its side.
        let straight = plan(
            cast, entrances: [EntranceTrigger(at: 0, stickerID: "fox")],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "flower")])
        let legs = try #require(straight[fox]?.legs)
        #expect(legs.count == 1 && legs[0].kind == .entrance && legs[0].support == .beside(flower))
        // Sent a little later: it comes in near, a step or two away.
        let later = plan(
            cast, entrances: [EntranceTrigger(at: 0, stickerID: "fox")],
            goes: [GoTrigger(at: 8, stickerID: "fox", kind: .to, target: "flower")])
        let entrance = try #require(later[fox]?.legs.first)
        let home = try #require(entrance.path.last)
        let fox = cast[0], them = cast[1]
        #expect((home - flowerAt).length < (fox.width + them.width) * 1.2)
    }
}

/// Plans every story of each real pack with a space on an empty canvas and
/// on a crowded one, and checks the stage keeps its rules all the way through.
@Suite struct PackStagingTests {
    /// A pack to stage: the stickers the child has also placed on the
    /// crowded canvas, and how many goes to someone its stories make.
    struct Staged: Sendable, CustomStringConvertible {
        let id: String
        let extras: [String]
        let goesToSomeone: Int
        /// Also staged on a phone in landscape (the wide art, its safe
        /// area). Forest is not yet: its woodpecker's trunks on the wide art
        /// lie under the phone's side margins.
        var phone = false
        var description: String { id }
    }

    static let packs = [
        Staged(id: "forest", extras: ["bear", "deer", "mushroom", "hedgehog"], goesToSomeone: 150),
        Staged(id: "beach", extras: ["umbrella", "castle", "dog", "sailboat"], goesToSomeone: 50, phone: true),
    ]

    struct Pack {
        let manifest: PackManifest
        let dir: URL
        var moves: [String: [StageMove]] = [:]
        var places: [LiveAnimationKey: [String]] = [:]
        var ratios: [String: Double] = [:]
        /// Each action's timing, as it plays.
        var actionFrames: [LiveAnimationKey: LiveFrames] = [:]
        /// The way each action faces on screen (`faces`), if it says.
        var actionFaces: [LiveAnimationKey: StageMove.Facing] = [:]
        /// Each sticker's painted shape and its drawing's box in its image
        /// (fractions, origin bottom-left).
        var shapes: [String: (grid: OpaqueGrid, box: CGRect)] = [:]
    }

    static func load(_ id: String) throws -> Pack? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("packs/\(id)")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        var pack = Pack(manifest: try JSONDecoder().decode(PackManifest.self, from: data), dir: dir)
        for sticker in pack.manifest.stickers {
            for path in sticker.animations {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(path)),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let id = json["id"] as? String ?? ""
                if (json["kind"] as? String) == "move" {
                    let loop = json["loop"] != nil
                    // Its frames after the loop, bringing it to rest.
                    let holds = ((json["puppet"] as? [String: Any])?["keys"] as? [[String: Any]])?.compactMap { $0["hold"] as? Double }
                        ?? json["hold"] as? [Double] ?? []
                    let last = (json["loop"] as? [String: Any])?["to"] as? Int
                    let tail = last.map { holds.dropFirst($0 + 1).reduce(0, +) } ?? 0
                    pack.moves[sticker.id, default: []].append(StageMove(
                        id: id, cycle: loop ? 0.8 : nil, stride: json["stride"] as? Double ?? 0,
                        hops: json["hops"] as? Bool ?? false, flies: json["flies"] as? Bool ?? false,
                        hovers: json["hovers"] as? Bool ?? false, on: json["on"] as? [String] ?? [], stays: json["stays"] as? Bool ?? false,
                        waterline: json["waterline"] as? Double ?? 0, facing: (json["facing"] as? String).flatMap(StageMove.Facing.init(rawValue:)), seconds: loop ? 0 : 1,
                        away: json["away"] as? String, tail: tail))
                }
                if (json["kind"] as? String ?? "action") == "action" {
                    let puppet = json["puppet"] as? [String: Any]
                    let holds = (puppet?["keys"] as? [[String: Any]])?.compactMap { $0["hold"] as? Double } ?? json["hold"] as? [Double] ?? []
                    let pause = (json["pause"] as? [String: Any])?["frame"] as? Int
                    pack.actionFrames[LiveAnimationKey(stickerID: sticker.id, animationID: id)] = LiveFrames(holds: holds, pause: pause)
                    if let faces = (json["faces"] as? String).flatMap(StageMove.Facing.init(rawValue:)) {
                        pack.actionFaces[LiveAnimationKey(stickerID: sticker.id, animationID: id)] = faces
                    }
                }
                if let place = json["place"] as? [String] {
                    pack.places[LiveAnimationKey(stickerID: sticker.id, animationID: id)] = place
                }
            }
            if let source = CGImageSourceCreateWithURL(dir.appendingPathComponent(sticker.image) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let box = OpaqueBounds.of(image)
            {
                pack.ratios[sticker.id] = Double(box.width / box.height) * Double(image.width) / Double(image.height)
                if let grid = OpaqueGrid.of(image) { pack.shapes[sticker.id] = (grid, box) }
            }
        }
        return pack
    }

    @Test(arguments: packs) func everyStoryKeepsTheStagesRules(_ staged: Staged) throws {
        guard let pack = try Self.load(staged.id), let space = pack.manifest.space else { return }
        var baseWorld = StageWorld(space: space, aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1024, height: 768))
        // What the scene's layers and the foreground hide.
        var arts = ["foreground": pack.manifest.foreground]
        for layer in pack.manifest.layers { arts[layer.id] = layer.image }
        for (art, path) in arts {
            guard let source = CGImageSourceCreateWithURL(pack.dir.appendingPathComponent(path) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let grid = OpaqueGrid.of(image),
                let depth = space.planeDepth(art)
            else { continue }
            baseWorld.covers.append(.init(depth: depth, grid: grid, area: StageRect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        }
        #expect(baseWorld.covers.count == pack.manifest.layers.count + 1)
        // A phone in landscape draws the wide art, all of it across, less a
        // little top and bottom; the camera cut-out and the home indicator
        // keep stickers in from its sides and its bottom, and the pill sits
        // at the bottom right.
        var wideWorld: StageWorld?
        if let foregroundWide = pack.manifest.foregroundWide {
            var wide = StageWorld(space: space, aspect: 4.0 / 3, wide: true, frame: StageSize(width: 1024, height: 768))
            var wideArts = ["foreground": foregroundWide]
            for layer in pack.manifest.layers { wideArts[layer.id] = layer.imageWide }
            for (art, path) in wideArts {
                guard let source = CGImageSourceCreateWithURL(pack.dir.appendingPathComponent(path) as CFURL, nil),
                    let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let grid = OpaqueGrid.of(image),
                    let depth = space.planeDepth(art, wide: true)
                else { continue }
                let across = Double(image.width) / Double(image.height) / (4.0 / 3)
                wide.covers.append(.init(
                    depth: depth, grid: grid, area: StageRect(minX: 0.5 - across / 2, minY: 0, maxX: 0.5 + across / 2, maxY: 1)))
            }
            wideWorld = wide
        }
        let phone = StageScreen(
            visible: StageRect(minX: -256, minY: 30, maxX: 1280, maxY: 738),
            clear: StageRect(minX: -256 + 106, minY: 30 + 38, maxX: 1280 - 106, maxY: 738),
            avoid: [StageRect(minX: 780, minY: 30, maxX: 1090, maxY: 100)])
        // An iPad's landscape window shows the art less a few percent top and bottom.
        let landscape = StageScreen(
            visible: StageRect(minX: 0, minY: 30, maxX: 1024, maxY: 738),
            avoid: [StageRect(minX: 900, minY: 30, maxX: 1024, maxY: 110)])
        // A window narrower than the art (portrait, Split View) shows all
        // its height; the story plays on all of it across and the camera
        // follows (`StoryCamera`), so the pill's band is kept clear
        // across the whole stage.
        // An iPad in portrait shows about half the art across.
        let narrowWidth = 1024 * 834.0 / (1194 * 4 / 3)
        var spread = (wide: 0, all: 0)
        var spreadEmpty = (wide: 0, all: 0)
        let narrow = StageScreen(
            visible: StageRect(minX: 0, minY: 0, maxX: 1024, maxY: 768),
            avoid: [StageRect(minX: 0, minY: 10, maxX: 1024, maxY: 65)], window: narrowWidth)
        let waterPlaces = Set(baseWorld.grounds.filter(\.water).map(\.place))
        let shallowPlaces = Set(baseWorld.grounds.filter(\.shallow).map(\.place))
        let stickers = Dictionary(uniqueKeysWithValues: pack.manifest.stickers.map { ($0.id, $0) })
        var problems: [String] = []
        var backwards: [String] = []
        var circling = 0
        var lags: [Double] = []
        for story in pack.manifest.stories {
            guard let sidecar = story.localizations["en-US"]?.effects,
                let data = try? Data(contentsOf: pack.dir.appendingPathComponent(sidecar)),
                let file = try? EffectTriggerFile(data: data)
            else { continue }
            // Spots are chosen with a little chance: two draws of each.
            for (crowded, seed, narrowWindow, onPhone) in [
                (false, 11, false, false), (true, 11, false, false), (false, 7777, false, false), (true, 7777, false, false),
                (false, 11, true, false), (true, 11, true, false), (false, 11, false, true), (true, 11, false, true),
                (false, 7777, false, true),
            ] where !onPhone || (staged.phone && wideWorld != nil) {
                let screen = onPhone ? phone : narrowWindow ? narrow : landscape
                let world = onPhone ? wideWorld ?? baseWorld : baseWorld
                let config = "\(crowded ? " (crowded)" : "")\(narrowWindow ? " (narrow)" : "")\(onPhone ? " (phone)" : "")"
                var random = SeededGenerator(state: UInt64(seed))
                // The story's cast as visitors; on the crowded canvas the
                // child has placed its stickers (and a few more) here and there.
                var actors: [StageActor] = []
                let placed: [String] = crowded
                    ? Array(Set(story.requiredStickers + story.optionalStickers + staged.extras)).sorted() : []
                for (k, id) in placed.enumerated() {
                    guard let s = stickers[id] else { continue }
                    let feet = SceneSpace.Point(0.08 + 0.84 * Double((k * 37) % 11) / 10, 0.1 + 0.4 * Double((k * 53) % 7) / 6)
                    actors.append(StageActor(
                        id: UUID(), stickerID: id, size: space.sizes[id] ?? 0.2, ratio: pack.ratios[id] ?? 1,
                        stage: s.stage ?? .default, moves: pack.moves[id] ?? [], placed: feet, stature: s.size))
                }
                for entrance in file.entranceTriggers where !placed.contains(entrance.stickerID) {
                    guard !actors.contains(where: { $0.stickerID == entrance.stickerID }), let s = stickers[entrance.stickerID] else { continue }
                    actors.append(StageActor(
                        id: UUID(), stickerID: s.id, size: space.sizes[s.id] ?? 0.2, ratio: pack.ratios[s.id] ?? 1,
                        stage: s.stage ?? .default, moves: pack.moves[s.id] ?? [], stature: s.size))
                }
                let placedIDs = Set(actors.filter { $0.placed != nil }.map(\.id))
                let goes = file.goTriggers + PlacementPlanner.goes(live: file.liveTriggers, places: pack.places, goes: file.goTriggers)
                let cast = StageDirector.cast(
                    entrances: file.entranceTriggers, goes: file.goTriggers, live: file.liveTriggers,
                    faces: file.expressionTriggers, effects: file.triggers)
                let plans = StageDirector.plan(
                    world: world, screen: screen, actors: actors, entrances: file.entranceTriggers, goes: goes,
                    policy: .standard, cast: cast, actions: StageAction.of(file.liveTriggers, frames: { pack.actionFrames[$0] }, faces: { pack.actionFaces[$0] }),
                    random: &random)
                // A move cued after an action waits for it to end; an action
                // waits only for the moves cued before it.
                let ids = Dictionary(uniqueKeysWithValues: actors.map { ($0.id, $0.stickerID) })
                let played = StageDirector.delayed(file.liveTriggers, plans: plans, stickers: ids, places: Set(pack.places.keys))
                for action in StageAction.of(file.liveTriggers, frames: { pack.actionFrames[$0] }, faces: { pack.actionFaces[$0] }) {
                    guard let k = file.liveTriggers.firstIndex(where: { $0.stickerID == action.stickerID && $0.at == action.at }),
                        let a = actors.first(where: { $0.stickerID == action.stickerID }), let plan = plans[a.id]
                    else { continue }
                    let start = played[k].at
                    for leg in plan.legs where leg.cue > action.at + 1e-6 && leg.at < start + action.duration - action.tail - 1e-6 {
                        problems.append("\(story.id)\(config) \(a.stickerID): moves during its \(file.liveTriggers[k].animationID) at \(String(format: "%.1f", leg.at))")
                    }
                }
                // Sent somewhere that way (`toward`), it goes that way — or
                // stays, with nowhere further that way (never the other way).
                for go in goes where go.kind == .to && go.toward != nil && go.target.map({ space.places[$0] != nil }) == true {
                    guard let a = actors.first(where: { $0.stickerID == go.stickerID }), let plan = plans[a.id] else { continue }
                    let mine = plan.legs.filter { $0.cue == go.at }
                    let before = mine.first?.path.first ?? plan.sample(at: go.at).position
                    let after = plan.sample(at: (mine.map(\.end).max() ?? go.at) + 0.01).position
                    let width = world.drawnHeight(size: a.size, atDepth: before.z) * a.ratio
                    let sign: Double = go.toward == .right ? 1 : -1
                    let gone = (world.screen(after).x - world.screen(before).x) * sign
                    if !mine.isEmpty, gone < -width * 0.25 {
                        problems.append("\(story.id)\(config) \(a.stickerID): does not go \(go.toward!) at \(go.at)")
                    }
                }
                // Afloat by the shore, it goes off out to sea, not along the waterline.
                for a in actors {
                    guard let plan = plans[a.id] else { continue }
                    for leg in plan.legs where leg.support == .off && leg.gait != .fade {
                        guard let from = leg.path.first, let to = leg.path.last, let water = world.water(at: from.ground),
                            a.moves.contains(where: { $0.waterline > 0 && $0.on.contains(water) }), !shallowPlaces.contains(water),
                            !world.inOpenWater(from.ground)
                        else { continue }
                        if !world.inOpenWater(to.ground) {
                            problems.append("\(story.id)\(config) \(a.stickerID): goes off along the waterline at \(leg.at)")
                        }
                    }
                }
                // How long after its cue a sticker sent to another gets there.
                for go in goes where go.target.map({ t in actors.contains { $0.stickerID == t } }) == true && go.kind != .away && go.kind != .back {
                    guard let mover = actors.first(where: { $0.stickerID == go.stickerID }), let plan = plans[mover.id] else { continue }
                    let targets = Set(actors.filter { $0.stickerID == go.target }.map(\.id))
                    let leg = plan.legs.first { leg in
                        guard leg.at >= go.at - 1e-6 else { return false }
                        switch leg.support {
                        case .on(let h), .under(let h), .beside(let h): return targets.contains(h)
                        default: return false
                        }
                    }
                    if let leg { lags.append(leg.end - go.at) }
                }
                // A whole lap past the last leg: whoever circles is seen all round its loop.
                let end = (plans.values.flatMap(\.legs).map(\.end).max() ?? 0) + StagePlan.lapTime + 1
                circling += plans.values.flatMap(\.legs).filter { $0.circling != nil }.count
                // Nobody in the story stands mostly hidden behind another
                // sticker while both are still (the deer in front of the
                // frog); one passing in front on its way is fine.
                var t0 = StageDirector.settle
                let last = plans.values.flatMap(\.legs).map(\.end).max() ?? 0
                while t0 <= last + 1 {
                    defer { t0 += 0.25 }
                    let shown = actors.compactMap { a -> (StageActor, StagePlan.Sample, StageRect, Bool)? in
                        guard let plan = plans[a.id] else { return nil }
                        let s = plan.sample(at: t0)
                        guard s.opacity > 0.5, s.support != .off else { return nil }
                        // (Between two legs of one move — the surf in, then
                        // the walk up the sand — it is still on its way.)
                        let still = !plan.legs.contains { $0.at <= t0 && t0 < $0.end }
                            && !zip(plan.legs, plan.legs.dropFirst()).contains { a, b in a.cue == b.cue && a.end <= t0 && t0 < b.at }
                        return (a, s, world.drawing(at: s.position, size: a.size, ratio: a.ratio), still)
                    }
                    for (a, s, r, still) in shown where still && cast.contains(a.stickerID) {
                        // On or under someone hides some of them, as it should;
                        // standing beside them hides little of anyone.
                        func linked(_ x: StageSupport, _ id: UUID) -> Bool {
                            switch x {
                            case .on(let h), .under(let h): return h == id
                            default: return false
                            }
                        }
                        let front = shown.filter { b in
                            b.0.id != a.id && b.3 && b.1.position.z < s.position.z - 1e-6
                                && !linked(s.support, b.0.id) && !linked(b.1.support, a.id)
                        }
                        let h = StageWorld.hidden(r, behind: front.map(\.2))
                        if h > 0.5 {
                            let tag = "\(story.id)\(config) \(a.stickerID)"
                            let who = front.filter { StageWorld.hidden(r, behind: [$0.2]) > 0.1 }.map(\.0.stickerID).sorted()
                            problems.append("\(tag): behind \(who.joined(separator: "+")) at \(String(format: "%.1f", t0))")
                        }
                    }
                }
                // In the narrow window, how often the cast on the stage is
                // wider than the window (the camera cannot show them all).
                if narrowWindow {
                    var t = StageDirector.settle
                    while t <= last + 1 {
                        defer { t += 0.5 }
                        let shown = actors.filter { cast.contains($0.stickerID) }.compactMap { a -> StageRect? in
                            guard let s = plans[a.id]?.sample(at: t), s.opacity > 0.5, s.support != .off else { return nil }
                            return world.drawing(at: s.position, size: a.size, ratio: a.ratio)
                        }
                        guard let lo = shown.map(\.minX).min(), let hi = shown.map(\.maxX).max() else { continue }
                        spread.all += 1
                        if hi - lo > narrowWidth { spread.wide += 1 }
                        if !crowded {
                            spreadEmpty.all += 1
                            if hi - lo > narrowWidth { spreadEmpty.wide += 1 }
                        }
                    }
                }
                // Whoever travels across faces the way it goes.
                for a in actors {
                    guard let plan = plans[a.id] else { continue }
                    var t = 0.0
                    let step = 0.05
                    while t <= end {
                        defer { t += step }
                        let s = plan.sample(at: t), next = plan.sample(at: t + step)
                        // (Not across the moment it turns — an action that
                        // faced it about hands over to the plan's facing.)
                        guard s.opacity > 0.5, next.opacity > 0.5, (s.facing < 0) == (next.facing < 0) else { continue }
                        let leg = plan.legs.last { $0.at <= t }
                        let art = StageMove.pick(a.moves, by: leg?.move).flatMap(\.facing) ?? a.moves.first?.facing
                        guard let art else { continue }
                        let dx = world.screen(next.position).x - world.screen(s.position).x
                        let width = world.drawnHeight(size: a.size, atDepth: s.position.z) * a.ratio
                        // Faster than a quarter of its width a second, sideways
                        // — but a little sidestep making room is not a walk.
                        guard abs(dx) / step > width * 0.25 else { continue }
                        if let now = plan.legs.last(where: { $0.at <= t + step }), now.kind == .shuffle,
                            let a0 = now.path.first, let a1 = now.path.last,
                            abs(world.screen(a1).x - world.screen(a0).x) < width * 0.25
                        { continue }
                        let looks = (art == .right ? 1.0 : -1.0) * (s.facing < 0 ? -1 : 1)
                        if looks * dx < 0 {
                            let what = leg.map { $0.end > t ? "\($0.kind) \($0.gait)" : "after \($0.kind) \($0.gait)" } ?? "start"
                            backwards.append("\(story.id)\(config) \(a.stickerID): \(what) at \(String(format: "%.1f", t))")
                        }
                    }
                }
                for a in actors {
                    guard let plan = plans[a.id] else { continue }
                    let land = !(a.stage.on + a.moves.flatMap(\.on)).contains { waterPlaces.contains($0) }
                    var t = 0.0
                    while t <= end {
                        defer { t += 0.1 }
                        let s = plan.sample(at: t)
                        guard s.opacity > 0.5 else { continue }
                        let tag = "\(story.id)\(config) \(a.stickerID)"
                        let onFoot = s.position.y < 0.01 && t >= StageDirector.settle
                        // A child's sticker left in the water wades out as the story starts.
                        let settling = plan.legs.contains { $0.kind == .settle && $0.at <= t && t < $0.end }
                        if land, onFoot, !settling, let water = world.water(at: s.position.ground) {
                            problems.append("\(tag): in the \(water) at \(String(format: "%.1f", t))")
                        }
                        // In the water only afloat, its feet under it (never standing in it)
                        // — but on the bottom of shallow water it belongs in, seen whole.
                        if !land, onFoot, !settling, let water = world.water(at: s.position.ground),
                            !a.moves.contains(where: { $0.waterline > 0 && $0.on.contains(water) }),
                            !(shallowPlaces.contains(water) && (a.stage.on + a.moves.flatMap(\.on)).contains(water))
                        {
                            problems.append("\(tag): standing in the \(water) at \(String(format: "%.1f", t))")
                        }
                        let moving = plan.legs.contains { $0.at <= t && t < $0.end }
                        // On bark it faces the bark, its beak on it (whichever tree).
                        // (The tree it is on: the nearest bark across the screen.)
                        if !moving, case .perch(let place) = s.support,
                            let face = world.perches.filter({ $0.place == place && $0.facing != nil }).min(by: { p, q in
                                let x = world.screen(s.position).x
                                return abs(world.screen(p.points[0]).x - x) < abs(world.screen(q.points[0]).x - x)
                            })?.facing,
                            let art = a.moves.first?.facing
                        {
                            let looks = (art == .right) == (s.facing > 0) ? StageMove.Facing.right : .left
                            if looks != face { problems.append("\(tag): faces away from the \(place) at \(String(format: "%.1f", t))") }
                        }
                        // On its way in the water by its water way (a duckling swims, never
                        // waddles, afloat); on its way over land by a way that walks it.
                        if let leg = plan.legs.last(where: { $0.at <= t && t < $0.end && $0.gait.carries }), leg.kind != .settle,
                            let id = leg.move, let move = a.moves.first(where: { $0.id == id }), !move.flies, onFoot
                        {
                            let water = world.water(at: s.position.ground)
                            // Its feet on the waterline are on both (it turns there,
                            // steps in): an edge point is in or out by a hair.
                            let waterline = world.grounds.contains { $0.water && $0.polygon.distance(to: s.position.ground) < 0.01 }
                            if !waterline, let water, !move.on.contains(water), a.moves.contains(where: { $0.on.contains(water) }) {
                                problems.append("\(tag): \(id) in the \(water) at \(String(format: "%.1f", t))")
                            }
                            let seen = world.drawing(at: s.position, size: a.size, ratio: a.ratio)
                            if !waterline, water == nil, move.on.contains(where: waterPlaces.contains), seen.maxX > screen.clear.minX, seen.minX < screen.clear.maxX {
                                problems.append("\(tag): \(id) on land at \(String(format: "%.1f", t))")
                            }
                        }
                        if !moving, t >= StageDirector.settle, s.support != .off {
                            // (Afloat on a move that stays, as wide as it lies.)
                            let r = world.drawing(at: s.position, size: a.size, ratio: a.ratio(at: s.position, in: world))
                            // On a shallow bottom it belongs on, seen in the water
                            // (the fish in the rock pool, not up on its rim).
                            // (One that lives in it: whose places are all water.)
                            if onFoot, let water = world.water(at: s.position.ground), shallowPlaces.contains(water),
                                !a.stage.on.isEmpty, a.stage.on.allSatisfy(waterPlaces.contains),
                                world.overWaterShare(water, drawing: r) < 0.75
                            {
                                problems.append("\(tag): on the \(water)'s rim at \(String(format: "%.1f", t))")
                            }
                            // Sheltering just behind whom it is under (Lola under
                            // the umbrella): its face or its middle shows, beside
                            // the pole, below the canopy.
                            if case .under(let id) = s.support, let b = actors.first(where: { $0.id == id }),
                                let host = plans[id]?.sample(at: t), host.position.z < s.position.z, let shape = pack.shapes[b.stickerID]
                            {
                                let h = world.drawing(at: host.position, size: b.size, ratio: b.ratio)
                                var fx = ((r.minX + r.maxX) / 2 - h.minX) / max(h.maxX - h.minX, 1e-9)
                                if host.facing < 0 { fx = 1 - fx }
                                let covered = [0.85, 0.5, 0.4].allSatisfy { k in
                                    let fy = (r.minY + (r.maxY - r.minY) * k - h.minY) / max(h.maxY - h.minY, 1e-9)
                                    return shape.grid.isOpaque(
                                        atU: Double(shape.box.minX) + fx * Double(shape.box.width),
                                        v: Double(shape.box.minY) + fy * Double(shape.box.height))
                                }
                                if covered {
                                    problems.append("\(tag): hidden under \(b.stickerID) at \(String(format: "%.1f", t))")
                                }
                            }
                            // A flyer by someone, in the air: clear of them,
                            // never across them (the gull by Lola).
                            if s.position.y > 0.01, case .beside(let id) = s.support, let b = actors.first(where: { $0.id == id }),
                                let them = plans[id]?.sample(at: t), plans[id]?.legs.contains(where: { $0.at <= t && t < $0.end }) == false
                            {
                                let theirs = world.drawing(at: them.position, size: b.size, ratio: b.ratio)
                                let h = s.position.z < them.position.z
                                    ? StageWorld.hidden(theirs, behind: [r]) : StageWorld.hidden(r, behind: [theirs])
                                if h > 0.15 {
                                    problems.append("\(tag): flies across \(b.stickerID) at \(String(format: "%.1f", t))")
                                }
                            }
                            let c = screen.clear
                            if r.minX < c.minX - 2 || r.maxX > c.maxX + 2 || r.minY < c.minY - 2 || r.maxY > c.maxY + 2 {
                                problems.append("\(tag): not wholly on screen at \(String(format: "%.1f", t)) \(r)")
                            }
                            if onFoot, world.footprints.contains(where: { $0.contains(s.position.ground) }) {
                                problems.append("\(tag): on a tree's roots at \(String(format: "%.1f", t))")
                            }
                            // On (or under) a sticker the child put by a tree, it
                            // shares that sticker's place.
                            var onTheChilds = false
                            switch s.support {
                            case .on(let host), .under(let host): onTheChilds = placedIDs.contains(host)
                            default: break
                            }
                            // (Drawn in front of the plane it stands behind: something
                            // that never moves, left where the child put it.)
                            if !onTheChilds, world.hidden(r, atDepth: plan.drawnAt ?? s.position.z) > 0.35 {
                                problems.append("\(tag): hidden behind the scene at \(String(format: "%.1f", t))")
                            }
                        }
                    }
                }
            }
        }
        let report = Dictionary(grouping: problems) { p -> String in
            let parts = p.split(separator: ":", maxSplits: 1)
            return parts[0] + ":" + (parts.count > 1 ? String(parts[1].split(separator: " at ")[0]) : "")
        }.map { "\($0.key) ×\($0.value.count) — first \($0.value.first!.split(separator: ":", maxSplits: 1).last!)" }.sorted()
        // The birds are left in the air now and then.
        #expect(circling > 0)
        // Sent to someone, it gets there soon: it comes in near them, and
        // a walk to someone takes at most `maxTravelToSomeone`.
        let meanArrival = lags.reduce(0, +) / Double(max(lags.count, 1))
        #expect(lags.count > staged.goesToSomeone && meanArrival < 4.2, "mean arrival \(meanArrival) s over \(lags.count) goes")
        let turned = Dictionary(grouping: backwards) { $0.components(separatedBy: " at ")[0] }
            .map { "\($0.key) ×\($0.value.count) — first at \($0.value[0].components(separatedBy: " at ").last!)" }.sorted()
        #expect(backwards.isEmpty, "\(turned.count) travel backwards:\n\(turned.joined(separator: "\n"))")
        #expect(problems.isEmpty, "\(problems.count) problems:\n\(report.prefix(40).joined(separator: "\n"))")
        // In a portrait window the visitors come in together, so the
        // camera can show the whole cast (17 % of the time it could not,
        // before `togetherPull`); the child's own stickers stay where the
        // child put them, however far apart.
        let wide = Double(spread.wide) / Double(max(spread.all, 1))
        let wideEmpty = Double(spreadEmpty.wide) / Double(max(spreadEmpty.all, 1))
        #expect(wideEmpty < 0.03 && wide < 0.35, "cast wider than the window \(Int(wide * 100)) % of the time, \(Int(wideEmpty * 100)) % on an empty canvas")
    }
}
