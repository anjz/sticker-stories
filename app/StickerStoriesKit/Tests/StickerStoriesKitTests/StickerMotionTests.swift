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

    @Test func twoBesideTheSameStickerTakeBothSides() {
        let plans = plan([
            GoTrigger(at: 0, stickerID: "fox", kind: .to, target: "rabbit"),
            GoTrigger(at: 0, stickerID: "mouse", kind: .to, target: "rabbit"),
        ])
        let fox = place(self.fox, plans, at: 30), mouse = place(self.mouse, plans, at: 30)
        #expect((fox.x - 700) * (mouse.x - 700) < 0)
    }
}
