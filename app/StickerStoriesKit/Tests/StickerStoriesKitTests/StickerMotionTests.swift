import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct GoTriggerDecodingTests {
    @Test func decodesMovesWithTheirTargets() throws {
        let json = """
            { "schema": 1, "triggers": [
              { "at": 4, "cue": "flew", "sticker": "bee", "go": "on", "target": "flower" },
              { "at": 1, "sticker": "fox", "go": "to", "target": "rabbit" },
              { "at": 6, "sticker": "fox", "go": "away" },
              { "at": 7, "sticker": "fox", "go": "back", "target": "rabbit" },
              { "at": 8, "sticker": "fox", "go": "under" },
              { "at": 9, "sticker": "all", "go": "away" },
              { "at": 9, "sticker": "fox", "go": "fly" },
              { "at": 10, "sticker": "bee", "go": "to", "target": "fox", "by": "walk" } ] }
            """
        let file = try EffectTriggerFile(data: Data(json.utf8))
        #expect(file.goTriggers == [
            GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit"),
            GoTrigger(at: 4, cue: "flew", stickerID: "bee", kind: .on, target: "flower"),
            GoTrigger(at: 6, stickerID: "fox", kind: .away),
            GoTrigger(at: 7, stickerID: "fox", kind: .back),
            GoTrigger(at: 10, stickerID: "bee", kind: .to, target: "fox", by: "walk"),
        ])
        #expect(file.warnings.count == 4)  // target on back, under without target, all, unknown kind
    }
}

@Suite struct MotionPlannerTests {
    /// A 1000×750 world, all visible; stickers 120 points square.
    static let scene = StagePlanner.Scene(
        world: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750),
        usable: StageRect(minX: 60, minY: 60, maxX: 940, maxY: 690),
        visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750),
        stickerSize: 120)
    static let size = StageSize(width: 120, height: 120)
    let fox = UUID(), rabbit = UUID(), bee = UUID(), flower = UUID(), mouse = UUID(), mushroom = UUID()

    func actors() -> [MotionPlanner.Actor] {
        [
            .init(id: fox, stickerID: "fox", home: StagePoint(x: 200, y: 200), size: Self.size),
            .init(id: rabbit, stickerID: "rabbit", home: StagePoint(x: 700, y: 220), size: Self.size),
            .init(id: bee, stickerID: "bee", home: StagePoint(x: 500, y: 600), size: Self.size, flies: true),
            .init(id: flower, stickerID: "flower", home: StagePoint(x: 450, y: 200), size: Self.size, canMove: false),
            .init(id: mouse, stickerID: "mouse", home: StagePoint(x: 820, y: 200), size: StageSize(width: 60, height: 60)),
            .init(id: mushroom, stickerID: "mushroom", home: StagePoint(x: 960, y: 700), size: Self.size, canMove: false),
        ]
    }

    func plan(_ goes: [GoTrigger], policy: EffectPolicy = .standard) -> [UUID: MotionPlan] {
        var random = SeededGenerator(state: 3)
        return MotionPlanner.plan(
            goes: goes, actors: actors(),
            moves: [
                "fox": [StageMove(id: "trot", cycle: 0.8, stride: 0.6, facing: .right)],
                // The mouse scurries, and it can fly too (a story says so).
                "mouse": [StageMove(id: "scurry", cycle: 0.6, stride: 0.4, facing: .left),
                          StageMove(id: "fly", cycle: 0.5, stride: 1, flies: true, facing: .left)],
            ],
            scene: Self.scene, policy: policy, random: &random)
    }

    /// Where the sticker's centre is at `time`, and its size, from its plan.
    func place(_ id: UUID, _ plans: [UUID: MotionPlan], at time: Double) -> (x: Double, y: Double, scale: Double, alpha: Double) {
        let actor = actors().first { $0.id == id }!
        let d = plans[id]?.delta(at: time) ?? .identity
        return (
            actor.home.x + d.offsetXSelf * actor.size.width, actor.home.y - d.offsetYSelf * actor.size.height,
            d.scaleMul, d.opacityMul
        )
    }

    @Test func aWalkerGoingToSomethingWithADoorStandsAtItInFront() {
        var scene = Self.scene
        scene.doors = ["rabbit": StagePoint(x: 0.6, y: 0.1)]
        scene.feet = ["fox": 0.4]
        let go = { (who: String, at: Double) in GoTrigger(at: at, stickerID: who, kind: .to, target: "rabbit") }
        var random = SeededGenerator(state: 3)
        let plans = MotionPlanner.plan(
            goes: [go("fox", 1), go("mouse", 2)], actors: actors(), scene: scene, policy: .standard, random: &random)
        // The rabbit (120 square at 700, 220): its door at x 712, ground 172.
        let fox = place(self.fox, plans, at: 30)
        #expect(abs(fox.x - 712) < 1e-6 && abs(fox.y - (172 + 0.4 * 120)) < 1e-6, "\(fox)")
        #expect(plans[self.fox]!.legs.last!.stacking == .onto(rabbit))
        // The door is taken: the mouse goes beside.
        let mouse = place(self.mouse, plans, at: 30)
        #expect(abs(mouse.x - 712) > 30, "\(mouse)")
    }

    @Test func movesAreMeasuredInTheImageNotTheNarrowerDrawing() {
        // The fox drawn half its image's width (a drawn-size pack): the
        // planner spaces by the drawing, the stage moves by the image.
        var actors = actors()
        actors[0].size = StageSize(width: 60, height: 120)
        actors[0].unit = StageSize(width: 120, height: 120)
        var random = SeededGenerator(state: 3)
        let plans = MotionPlanner.plan(
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")], actors: actors,
            scene: Self.scene, policy: .standard, random: &random)
        let x = 200 + plans[fox]!.delta(at: 30).offsetXSelf * 120
        // Beside the rabbit (700), a narrow drawing standing close to it.
        #expect(x < 700 - 60 && x > 700 - 60 - 60, "\(x)")
    }

    @Test func besideSomethingAtTheScreensEdgeItTakesTheSideWithRoom() {
        var actors = actors()
        actors[0].home = StagePoint(x: 20, y: 200)  // the fox, left of the rabbit
        actors[1].home = StagePoint(x: 70, y: 220)  // the rabbit, squeezed in at the left edge
        var random = SeededGenerator(state: 3)
        let plans = MotionPlanner.plan(
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")], actors: actors,
            scene: Self.scene, policy: .standard, random: &random)
        let d = plans[fox]!.delta(at: 30)
        #expect(20 + d.offsetXSelf * 120 > 70 + 60, "the fox should stand right of the rabbit, not behind it")
    }

    @Test func walksBesideAnotherStickerFacingIt() {
        let plans = plan([GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let leg = plans[fox]!.legs[0]
        #expect(leg.gait == .walk && leg.at == 1 && leg.facingTo == 1)  // walks right, as its frames do
        let end = place(fox, plans, at: 20)
        #expect(end.x < 700 && end.x > 700 - 120 && abs(end.y - 220) < 1e-6 && end.scale == 1)
        #expect(place(fox, plans, at: 0.5).x == 200)  // nothing before its cue
        #expect(plans[flower] == nil)  // still things never move
    }

    @Test func onAndUnderShrinkToThreeQuartersAndStayOnScreen() {
        let plans = plan([
            GoTrigger(at: 0, stickerID: "bee", kind: .on, target: "flower"),
            GoTrigger(at: 0, stickerID: "mouse", kind: .under, target: "mushroom"),
            GoTrigger(at: 0, stickerID: "fox", kind: .on, target: "mushroom"),
        ])
        let bee = place(self.bee, plans, at: 20)
        #expect(abs(bee.scale - 0.65) < 1e-9 && abs(bee.x - 450) < 1e-6 && bee.y > 200)
        // The mouse is already smaller than 65 % of the mushroom: its size stays.
        let mouse = place(self.mouse, plans, at: 20)
        #expect(mouse.scale == 1)
        // The mushroom is in the top-right corner: whoever goes on it is
        // pushed back onto the screen (more overlap), never cut off.
        let fox = place(self.fox, plans, at: 20)
        let half = 60 * fox.scale
        #expect(fox.x + half <= 1000 + 1e-6 && fox.y + half <= 750 + 1e-6)
    }

    @Test func goesAwayOffTheCanvasAndComesBackHome() {
        let plans = plan([
            GoTrigger(at: 1, stickerID: "fox", kind: .away),
            GoTrigger(at: 10, stickerID: "fox", kind: .back),
        ])
        #expect(place(fox, plans, at: 9).alpha == 0)  // gone
        let out = place(fox, plans, at: 9)
        #expect(out.x < 0)  // by the nearer (left) side
        let back = place(fox, plans, at: 30)
        #expect(back.alpha == 1 && abs(back.x - 200) < 1e-6 && abs(back.y - 200) < 1e-6)
        // Coming back it walks in from the side it left by, facing the way it goes.
        let leg = plans[fox]!.legs[1]
        #expect(leg.from.x < 0 && leg.facingTo == 1)
    }

    @Test func leavingAPlaceThatRunsOnPastOneSideGoesThatWay() {
        // The open sea runs on past the left; the rabbit (at 700, 220) is out on it.
        let sea = ["sea": SceneFeature(
            description: "Water.", areas: [.init(x: [0.1, 0.9], y: [0.2, 0.4])], from: .left)]
        func away(_ id: String) -> MotionLeg? {
            var random = SeededGenerator(state: 3)
            let who = actors().first { $0.stickerID == id }!.id
            return MotionPlanner.plan(
                goes: [GoTrigger(at: 1, stickerID: id, kind: .away)], actors: actors(), features: sea,
                scene: Self.scene, policy: .standard, random: &random)[who]?.legs.first
        }
        // Nearer the right edge, it still sails out to the left.
        #expect((away("rabbit")?.to.x ?? 0) < 0)
        // The mouse (at 820, 200) is just off it, up on the sand: the nearer side as ever.
        let sand = ["sea": SceneFeature(description: "Water.", areas: [.init(x: [0.1, 0.9], y: [0.6, 0.8])], from: .left)]
        var random = SeededGenerator(state: 3)
        let mouse = MotionPlanner.plan(
            goes: [GoTrigger(at: 1, stickerID: "mouse", kind: .away)], actors: actors(), features: sand,
            scene: Self.scene, policy: .standard, random: &random)[self.mouse]?.legs.first
        #expect((mouse?.to.x ?? 0) > 0)
    }

    @Test func calmModeFadesInsteadOfTravelling() {
        let plans = plan([GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit")], policy: EffectPolicy(calmMode: true))
        let leg = plans[fox]!.legs[0]
        #expect(leg.gait == .fade && !leg.travels)
        #expect(place(fox, plans, at: leg.duration / 2).alpha < 0.05)
        #expect(plans[fox]!.facing(at: 5) == 1)  // no turning either
    }

    @Test func turnsRoundThroughASquash() {
        // The fox's frames face right; going left, it mirrors.
        let plans = plan([GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit"),
                          GoTrigger(at: 10, stickerID: "fox", kind: .back)])
        let plan = plans[fox]!
        #expect(plan.facing(at: 11) != plan.facing(at: 9.9) || plan.legs[1].facingTo == -1)
        #expect(plan.legs[1].facingTo == -1)
        let mid = plan.facing(at: 10 + MotionPlan.turn / 2)
        #expect(abs(mid) < 0.6 && abs(mid) >= 0.05)
    }

    @Test func aWalkerGoingToAFlyerStaysOnTheGround() {
        let plans = plan([GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "bee")])
        let end = place(fox, plans, at: 20)
        #expect(abs(end.y - 200) < 1e-6 && abs(end.x - 500) < 150)
    }

    @Test func twoUnderTheSameStickerShareItCentredAndOverlapping() {
        let plans = plan([
            GoTrigger(at: 0, stickerID: "mouse", kind: .under, target: "flower"),
            GoTrigger(at: 10, stickerID: "bee", kind: .under, target: "flower"),
            GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit"),
            GoTrigger(at: 20, stickerID: "bee", kind: .away),
        ])
        // Alone, the mouse is centred under the flower.
        #expect(abs(place(mouse, plans, at: 9).x - 450) < 1e-6)
        // The bee comes (from the right): both shuffle so the pair is
        // centred on the flower, overlapping by a quarter of the narrower.
        let m = place(mouse, plans, at: 19), b = place(bee, plans, at: 19)
        let mw = 60.0 * m.scale, bw = 120.0 * b.scale
        #expect(m.x < 450 && b.x > 450)
        let leftEdge = m.x - mw / 2, rightEdge = b.x + bw / 2
        #expect(abs((leftEdge + rightEdge) / 2 - 450) < 1e-6)
        #expect(abs((m.x + mw / 2) - (b.x - bw / 2) - MotionPlanner.sharedOverlap * min(mw, bw)) < 1e-6)
        // The bee leaves: the mouse closes up to the middle again.
        #expect(abs(place(mouse, plans, at: 40).x - 450) < 1e-6)
    }

    @Test func goesTheWayTheStoryNames() {
        let plans = plan([
            GoTrigger(at: 0, stickerID: "mouse", kind: .on, target: "flower", by: "fly"),
            GoTrigger(at: 10, stickerID: "fox", kind: .on, target: "flower"),
            GoTrigger(at: 20, stickerID: "mouse", kind: .back),
        ])
        let legs = plans[mouse]!.legs
        // Flies onto the flower, its flight frames playing; shuffles over by
        // the way it came when the fox joins; walks home, its usual way.
        #expect(legs[0].gait == .fly && legs[0].move == "fly")
        #expect(legs[1].at >= 10 && legs[1].gait == .fly && legs[1].move == "fly")
        #expect(legs.last!.gait == .walk && legs.last!.move == "scurry")
        #expect(plans[fox]!.legs[0].move == "trot")
    }

    @Test func travelsBehindOthersAndEndsInFrontOfWhereItGoes() {
        let plans = plan([
            GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit"),
            GoTrigger(at: 0, stickerID: "mouse", kind: .under, target: "flower"),
            GoTrigger(at: 10, stickerID: "bee", kind: .under, target: "flower"),
            GoTrigger(at: 10, stickerID: "fox", kind: .away),
            GoTrigger(at: 20, stickerID: "fox", kind: .back),
            GoTrigger(at: 30, stickerID: "bee", kind: .to, target: "rabbit"),
        ])
        #expect(plans[fox]!.legs.map(\.stacking) == [.onto(rabbit), .behind, .home])
        #expect(plans[bee]!.legs.map(\.stacking) == [.onto(flower), .onto(rabbit)])
        // The mouse went under the flower, then shuffled to make room.
        #expect(plans[mouse]!.legs.map(\.stacking) == [.onto(flower), .shuffle, .shuffle])
    }

    @Test func goesTheWayTheWindBlows() throws {
        let file = try EffectTriggerFile(data: Data("""
            { "schema": 1, "triggers": [
              { "at": 1, "sticker": "fox", "go": "away", "toward": "right" },
              { "at": 2, "sticker": "fox", "go": "on", "target": "rabbit", "toward": "right" },
              { "at": 3, "sticker": "fox", "go": "to", "target": "rabbit", "toward": "up" } ] }
            """.utf8))
        #expect(file.goTriggers.map(\.toward) == [.right, nil, nil])
        #expect(file.warnings.count == 2)

        // The fox is on the left: away goes by the nearer (left) side, unless
        // the wind carries it right.
        #expect(place(fox, plan([GoTrigger(at: 0, stickerID: "fox", kind: .away)]), at: 20).x < 0)
        #expect(place(fox, plan([GoTrigger(at: 0, stickerID: "fox", kind: .away, toward: .right)]), at: 20).x > 1000)
        // Beside the rabbit: on the side it comes from, or the one named.
        #expect(place(fox, plan([GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit")]), at: 20).x < 700)
        #expect(place(fox, plan([GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit", toward: .right)]), at: 20).x > 700)
        // To a place: somewhere on that side of it.
        let meadow = ["meadow": SceneFeature(description: "Grass.", areas: [.init(x: [0.1, 0.9], y: [0.2, 0.4])])]
        for seed in UInt64(1)...8 {
            var random = SeededGenerator(state: seed)
            let plans = MotionPlanner.plan(
                goes: [GoTrigger(at: 0, stickerID: "rabbit", kind: .to, target: "meadow", toward: .left)],
                actors: actors(), features: meadow, scene: Self.scene, policy: .standard, random: &random)
            #expect(place(rabbit, plans, at: 20).x <= 700 - 120 + 1e-6)
        }
    }

    @Test func besideAnotherItTakesTheirSizeRatio() {
        let deer = UUID(), bird = UUID(), ladybug = UUID(), fox = UUID()
        func actor(_ id: UUID, _ name: String, x: Double, _ size: StickerSize?) -> MotionPlanner.Actor {
            .init(id: id, stickerID: name, home: StagePoint(x: x, y: 200), size: Self.size, stature: size?.relativeHeight)
        }
        let actors = [actor(deer, "deer", x: 700, .big), actor(bird, "bird", x: 200, .small),
                      actor(ladybug, "ladybug", x: 400, .tiny), actor(fox, "fox", x: 900, nil)]
        var random = SeededGenerator(state: 2)
        let plans = MotionPlanner.plan(
            goes: [GoTrigger(at: 0, stickerID: "bird", kind: .to, target: "deer"),
                   GoTrigger(at: 0, stickerID: "ladybug", kind: .to, target: "deer"),
                   GoTrigger(at: 0, stickerID: "deer", kind: .to, target: "fox"),
                   GoTrigger(at: 10, stickerID: "bird", kind: .back)],
            actors: actors, scene: Self.scene, policy: .standard, random: &random)
        // A small bird by a big deer: 0.55 of its height.
        #expect(abs(plans[bird]!.legs[0].to.scale - 0.55) < 1e-9)
        // A tiny ladybug by it would be 0.4; never under 0.45 of its own size.
        #expect(abs(plans[ladybug]!.legs[0].to.scale - MotionPlanner.besideScale.lowerBound) < 1e-9)
        // No size class on the fox: the deer keeps its own size.
        #expect(plans[deer]!.legs[0].to.scale == 1)
        // Its feet stay on the deer's line though it is smaller.
        let bottom = 200 - plans[bird]!.legs[0].to.y * 120 - 60 * plans[bird]!.legs[0].to.scale
        #expect(abs(bottom - 140) < 1e-6)
        // Home again, its own size.
        #expect(plans[bird]!.legs.last!.to.scale == 1)
    }

    @Test func besideAnotherTheLongestSidesKeepTheRatio() {
        // A long, low buggy (big) going to a tall astronaut (medium), both
        // drawn at their sizes: their longest sides take the ratio 1 : 0.75.
        let buggy = UUID(), astronaut = UUID()
        let actors: [MotionPlanner.Actor] = [
            .init(id: buggy, stickerID: "buggy", home: StagePoint(x: 200, y: 200), size: StageSize(width: 100, height: 50),
                  stature: StickerSize.big.relativeHeight),
            .init(id: astronaut, stickerID: "astronaut", home: StagePoint(x: 700, y: 200),
                  size: StageSize(width: 40, height: 90), stature: StickerSize.medium.relativeHeight),
        ]
        var random = SeededGenerator(state: 3)
        let plans = MotionPlanner.plan(
            goes: [GoTrigger(at: 0, stickerID: "buggy", kind: .to, target: "astronaut")],
            actors: actors, scene: Self.scene, policy: .standard, random: &random)
        // 90 × 1 / 0.75 = 120 long: 1.2 × its 100.
        #expect(abs(plans[buggy]!.legs[0].to.scale - 1.2) < 1e-9)
    }

    @Test func aStickerAlreadyThereStays() {
        let pond = ["pond": SceneFeature(description: "Water.", areas: [.init(x: [0.1, 0.3], y: [0.2, 0.35])])]
        func planned(_ go: GoTrigger) -> [UUID: MotionPlan] {
            var random = SeededGenerator(state: 4)
            return MotionPlanner.plan(goes: [go], actors: actors(), features: pond, scene: Self.scene, policy: .standard, random: &random)
        }
        // The fox (at 200, 200) is in the pond's area: "went to the pond" keeps it there.
        #expect(planned(GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "pond"))[fox] == nil)
        // The rabbit (at 700) is not: it goes.
        #expect(planned(GoTrigger(at: 0, stickerID: "rabbit", kind: .to, target: "pond"))[rabbit] != nil)
    }

    @Test func onlyThoseThatBelongGoIntoAPlaceTheRestStopAtItsEdge() {
        // The water at x 500–700, its banks either side of it.
        let pond = ["pond": SceneFeature(
            description: "Water.", areas: [.init(x: [0.5, 0.7], y: [0.3, 0.4])],
            edge: [.init(x: [0.3, 0.45], y: [0.3, 0.4]), .init(x: [0.75, 0.9], y: [0.3, 0.4])])]
        let frog = UUID(), duckling = UUID()
        let actors = actors() + [
            .init(id: frog, stickerID: "frog", home: StagePoint(x: 150, y: 150), size: Self.size, places: ["pond", "meadow"]),
            .init(id: duckling, stickerID: "duckling", home: StagePoint(x: 900, y: 150), size: Self.size, places: ["meadow"]),
        ]
        let moves = ["duckling": [StageMove(id: "waddle", cycle: 0.8, stride: 0.4, facing: .right),
                                  StageMove(id: "swim", cycle: 0.8, stride: 0.5, on: ["pond"], facing: .right)]]
        func spot(_ id: UUID, _ go: GoTrigger, seed: UInt64) -> Double {
            var random = SeededGenerator(state: seed)
            let plans = MotionPlanner.plan(
                goes: [go], actors: actors, features: pond, moves: moves, scene: Self.scene, policy: .standard,
                random: &random)
            let actor = actors.first { $0.id == id }!
            return actor.home.x + (plans[id]?.delta(at: 30) ?? .identity).offsetXSelf * actor.size.width
        }
        let water = 500.0...700.0
        for seed in UInt64(1)...10 {
            // The frog's stage lands on the pond: it hops in.
            #expect(water.contains(spot(frog, GoTrigger(at: 0, stickerID: "frog", kind: .to, target: "pond"), seed: seed)))
            // The mouse's doesn't: it stops on a bank.
            let mouse = spot(mouse, GoTrigger(at: 0, stickerID: "mouse", kind: .to, target: "pond"), seed: seed)
            #expect((300...450).contains(mouse) || (750...900).contains(mouse), "seed \(seed): mouse at \(mouse)")
            // The duckling waddles up to the edge, and swims in when the story says so.
            let waddled = spot(duckling, GoTrigger(at: 0, stickerID: "duckling", kind: .to, target: "pond"), seed: seed)
            #expect(!water.contains(waddled), "seed \(seed): duckling waddled into the water at \(waddled)")
            let swam = spot(duckling, GoTrigger(at: 0, stickerID: "duckling", kind: .to, target: "pond", by: "swim"), seed: seed)
            #expect(water.contains(swam))
        }
    }

    @Test func aWayThatStaysKeepsGoingOnlyOnceItIsInItsElement() {
        let sea = ["sea": SceneFeature(description: "Water.", areas: [.init(x: [0.5, 0.7], y: [0.3, 0.4])])]
        let surfer = UUID()
        let actors = actors() + [
            .init(id: surfer, stickerID: "surfer", home: StagePoint(x: 150, y: 150), size: Self.size, places: ["meadow"]),
        ]
        let moves = ["surfer": [StageMove(id: "walk", cycle: 0.8, stride: 0.4, facing: .left),
                                StageMove(id: "surf", cycle: 0.8, stride: 0.9, on: ["sea"], stays: true, facing: .left)]]
        func leg(_ go: GoTrigger) -> MotionLeg? {
            var random = SeededGenerator(state: 1)
            return MotionPlanner.plan(
                goes: [go], actors: actors, features: sea, moves: moves, scene: Self.scene, policy: .standard,
                random: &random)[surfer]?.legs.last
        }
        // Surfing out to the sea: the surf loop stays on once it is there.
        let out = leg(GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "sea", by: "surf"))
        #expect(out?.move == "surf" && out?.stays == true)
        // Walking there, or surfing to someone rather than into the sea: it settles as ever.
        #expect(leg(GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "sea"))?.stays == false)
        #expect(leg(GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "fox", by: "surf"))?.stays == false)
        // Calm mode fades it there: nothing loops.
        var random = SeededGenerator(state: 1)
        let calm = MotionPlanner.plan(
            goes: [GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "sea", by: "surf")], actors: actors,
            features: sea, moves: moves, scene: Self.scene, policy: EffectPolicy(reduceMotion: true), random: &random)
        #expect(calm[surfer]?.legs.last?.stays == false)
    }

    @Test func aWaterWayIsOnlyForTheWaterAndBoatsNeverLeaveIt() {
        // The sea up top (y 450–600) with the shore along its near edge; sand below.
        let features = [
            "sea": SceneFeature(
                description: "Water.", areas: [.init(x: [0.1, 0.9], y: [0.6, 0.8])],
                edge: [.init(x: [0.1, 0.9], y: [0.52, 0.56])]),
            "sand": SceneFeature(description: "Sand.", areas: [.init(x: [0.1, 0.9], y: [0.1, 0.4])]),
        ]
        let surfer = UUID(), boat = UUID()
        let actors = actors() + [
            .init(id: surfer, stickerID: "surfer", home: StagePoint(x: 500, y: 200), size: Self.size, places: ["sand"]),
            .init(id: boat, stickerID: "boat", home: StagePoint(x: 300, y: 520), size: Self.size, places: ["sea"]),
        ]
        let moves = [
            "surfer": [StageMove(id: "walk", cycle: 0.8, stride: 0.4, facing: .left),
                       StageMove(id: "surf", cycle: 0.8, stride: 0.9, on: ["sea"], stays: true, facing: .left)],
            "boat": [StageMove(id: "sail", cycle: 0.8, stride: 0.6, on: ["sea"], facing: .left)],
        ]
        func legs(_ goes: [GoTrigger], _ id: UUID) -> [MotionLeg] {
            var random = SeededGenerator(state: 2)
            return MotionPlanner.plan(
                goes: goes, actors: actors, features: features, moves: moves, scene: Self.scene, policy: .standard,
                random: &random)[id]?.legs ?? []
        }
        // From the sand out onto the sea and back: he walks to the waterline and
        // paddles out; riding in, he surfs to the shore and walks up the sand.
        let ride = legs([GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "sea", by: "surf"),
                         GoTrigger(at: 10, stickerID: "surfer", kind: .to, target: "sand", by: "surf")], surfer)
        #expect(ride.map(\.move) == ["walk", "surf", "surf", "walk"])
        #expect(!ride[0].stays && ride[1].stays && !ride[2].stays)
        let shoreY = 750 * 0.54, landY = 750 * 0.25
        let at = { (home: Double, leg: MotionLeg) in home - leg.to.y * Self.size.height }
        #expect(abs(at(200, ride[0]) - shoreY) < 60 && abs(at(200, ride[2]) - shoreY) < 60 && at(200, ride[3]) < 750 * 0.45)
        // On land, "by surf" is no way to go anywhere: he walks.
        let walk = legs([GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "fox", by: "surf")], surfer)
        #expect(walk.map(\.move) == ["walk"])
        _ = landY
        // At sea, swimming over to someone also at sea is all swimming.
        let ring = UUID()
        let withRing = actors + [.init(id: ring, stickerID: "ring", home: StagePoint(x: 750, y: 520), size: Self.size)]
        var random = SeededGenerator(state: 2)
        let over = MotionPlanner.plan(
            goes: [GoTrigger(at: 0, stickerID: "surfer", kind: .to, target: "sea", by: "surf"),
                   GoTrigger(at: 10, stickerID: "surfer", kind: .to, target: "ring", by: "surf")],
            actors: withRing, features: features, moves: moves, scene: Self.scene, policy: .standard, random: &random)[surfer]?.legs ?? []
        #expect(over.map(\.move) == ["walk", "surf", "surf"])
        // A boat sent to the fox on the land stops in the water, as near as it gets.
        let sail = legs([GoTrigger(at: 0, stickerID: "boat", kind: .to, target: "fox")], boat)
        #expect(sail.count == 1 && at(520, sail[0]) >= 750 * 0.6 - 1)
    }

    @Test func aPlaceSpotIsNeverUnderThePill() {
        var scene = Self.scene
        scene.avoid = [StageRect(minX: 700, minY: 0, maxX: 1000, maxY: 260)]
        let meadow = ["meadow": SceneFeature(description: "Grass.", areas: [.init(x: [0.1, 0.9], y: [0.1, 0.35])])]
        for seed in UInt64(1)...20 {
            var random = SeededGenerator(state: seed)
            let plans = MotionPlanner.plan(
                goes: [GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "meadow", another: true)],
                actors: actors(), features: meadow, scene: scene, policy: .standard, random: &random)
            let spot = place(fox, plans, at: 30)
            #expect(!scene.isCovered(StagePoint(x: spot.x, y: spot.y), size: Self.size), "seed \(seed): \(spot)")
        }
    }

    @Test func twoBesideTheSameStickerTakeBothSides() {
        let plans = plan([
            GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit"),
            GoTrigger(at: 0, stickerID: "mouse", kind: .to, target: "rabbit"),
        ])
        let fox = place(self.fox, plans, at: 30), mouse = place(self.mouse, plans, at: 30)
        #expect((fox.x - 700) * (mouse.x - 700) < 0)
    }
}
