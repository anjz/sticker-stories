import Foundation
import Testing

@testable import StickerStoriesKit

/// A seeded generator so plans are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@Suite struct EntranceTriggerDecodingTests {
    @Test func decodesEntrancesOnePerSticker() throws {
        let json = """
            { "schema": 1, "triggers": [
              { "at": 4.2, "cue": "owl", "sticker": "owl", "enter": true },
              { "at": 0, "sticker": "fox", "enter": true },
              { "at": 6, "sticker": "fox", "enter": true },
              { "at": 1, "sticker": "all", "enter": true },
              { "at": 1, "sticker": "bear", "enter": false },
              { "at": 2, "sticker": "fox", "effect": "hop" } ] }
            """
        let file = try EffectTriggerFile(data: Data(json.utf8))
        #expect(file.entranceTriggers == [
            EntranceTrigger(at: 0, stickerID: "fox"),
            EntranceTrigger(at: 4.2, cue: "owl", stickerID: "owl"),
        ])
        #expect(file.triggers.count == 1)
        #expect(file.warnings.count == 3)
    }
}

@Suite struct StagePlannerTests {
    /// A 1000×750 world, all of it visible, a sticker 120 points square.
    static let scene = StagePlanner.Scene(
        world: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750),
        usable: StageRect(minX: 40, minY: 40, maxX: 960, maxY: 710),
        visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750),
        stickerSize: 120)

    static let stages: [String: StickerStage] = [
        "fox": StickerStage(entrance: .hop, area: .init(x: [0.1, 0.9], y: [0.18, 0.36])),
        "owl": StickerStage(entrance: .fly, area: .init(x: [0.1, 0.9], y: [0.5, 0.8])),
        "tree": StickerStage(entrance: .grow, area: .init(x: [0.1, 0.9], y: [0.16, 0.34])),
    ]

    func plan(
        _ ids: [String], placed: Set<String> = [], obstacles: [StageObstacle] = [], policy: EffectPolicy = .standard,
        seed: UInt64 = 7
    ) -> [EntrancePlan] {
        var random = SeededGenerator(state: seed)
        return StagePlanner.plan(
            entrances: ids.enumerated().map { EntranceTrigger(at: Double($0.offset), stickerID: $0.element) },
            placed: placed, stages: Self.stages, scene: Self.scene, obstacles: obstacles, policy: policy,
            random: &random)
    }

    @Test func onlyMissingStickersEnterEachInItsArea() {
        let plans = plan(["fox", "owl", "tree", "fox"], placed: ["tree"])
        #expect(plans.map(\.stickerID) == ["fox", "owl"])
        #expect(plans.map(\.motion) == [.hop, .fly])
        let fox = plans[0].target, owl = plans[1].target
        #expect((100...900).contains(fox.x) && (135...270).contains(fox.y))
        #expect((100...900).contains(owl.x) && (375...600).contains(owl.y))
    }

    @Test func landsOnTheFreeSpotAndVisitorsAvoidEachOther() {
        // Stickers already fill the left of the ground band.
        let crowd = stride(from: 100.0, through: 500, by: 100).map {
            StageObstacle(center: StagePoint(x: $0, y: 200), radius: 50)
        }
        for seed in 1...20 {
            let plans = plan(["fox", "tree"], obstacles: crowd, seed: UInt64(seed))
            #expect(plans[0].target.x > 600, "seed \(seed): fox should take the free right side")
            let dx = plans[0].target.x - plans[1].target.x, dy = plans[0].target.y - plans[1].target.y
            #expect((dx * dx + dy * dy).squareRoot() >= 2 * StagePlanner.footprint * 120 - 1e-9)
        }
    }

    @Test func aCrowdedStageStillGivesASpotInTheArea() {
        let wall = stride(from: 0.0, through: 1000, by: 40).flatMap { x in
            stride(from: 100.0, through: 300, by: 40).map { StageObstacle(center: StagePoint(x: x, y: $0), radius: 60) }
        }
        let fox = plan(["fox"], obstacles: wall)[0].target
        #expect((100...900).contains(fox.x) && (135...270).contains(fox.y))
    }

    @Test func narrowWindowsKeepVisitorsInView() {
        var scene = Self.scene
        scene.visible = StageRect(minX: 600, minY: 0, maxX: 900, maxY: 750)
        scene.usable = StageRect(minX: 640, minY: 40, maxX: 860, maxY: 710)
        var random = SeededGenerator(state: 3)
        let plans = StagePlanner.plan(
            entrances: [EntranceTrigger(at: 0, stickerID: "fox")], placed: [], stages: Self.stages, scene: scene,
            obstacles: [], policy: .standard, random: &random)
        #expect((640...860).contains(plans[0].target.x))
    }

    @Test func walkersComeFromOffScreenAndScaleWithDepth() {
        for seed in 1...30 {
            let fox = plan(["fox"], seed: UInt64(seed))[0]
            // Starts beyond the nearer side.
            let startX = fox.target.x + fox.startOffset.x * 120
            #expect(startX < 0 || startX > 1000)
            // Going up the meadow (start lower, y down ⇒ positive offset)
            // starts bigger; coming down starts smaller.
            if fox.startOffset.y > 0.01 {
                #expect(fox.startScale > 1)
            } else if fox.startOffset.y < -0.01 {
                #expect(fox.startScale < 1)
            }
            #expect(abs(fox.startScale - 1) <= 0.25)
        }
    }

    @Test func calmModeJustFadesIn() {
        let plans = plan(["fox", "owl", "tree"], policy: EffectPolicy(reduceMotion: true))
        #expect(plans.allSatisfy { $0.motion == .fade && $0.startScale == 1 })
    }
}

@Suite struct EntrancePlanTests {
    let hop = EntrancePlan(
        stickerID: "fox", at: 2, motion: .hop, target: StagePoint(x: 500, y: 200),
        startOffset: (x: -5, y: 0.5), startScale: 1.2, duration: 2)

    @Test func hiddenBeforeInOnTheWayThenPlaced() {
        #expect(hop.delta(at: 1.9).opacityMul == 0)
        let start = hop.delta(at: 2)
        #expect(start.opacityMul == 1)
        #expect(abs(start.offsetXSelf + 5) < 1e-9 && abs(start.scaleMul - 1.2) < 1e-9)
        let mid = hop.delta(at: 3)
        #expect(mid.offsetXSelf > -5 && mid.offsetXSelf < 0)
        #expect(mid.scaleMul < 1.2 && mid.scaleMul > 1)
        #expect(hop.delta(at: 4).isIdentity())
        #expect(hop.isFinished(at: 4) && !hop.isFinished(at: 3.9))
    }

    @Test func hopsBounceUpNeverBelowThePath() {
        for step in 0...40 {
            let t = 2 + Double(step) * 0.05
            let delta = hop.delta(at: t)
            let p = min((t - 2) / 2, 1)
            let path = 0.5 * (1 - EntrancePlan.easeOut(p))
            #expect(delta.offsetYSelf <= path + 1e-9)  // y down: bounces go up
        }
    }

    @Test func growFadesInFromSmall() {
        let grow = EntrancePlan(stickerID: "tree", at: 0, motion: .grow, target: StagePoint(x: 0, y: 0), duration: 0.8)
        #expect(grow.delta(at: 0).opacityMul == 0)
        #expect(abs(grow.delta(at: 0).scaleMul - EntrancePlan.growFrom) < 1e-9)
        #expect(grow.delta(at: 0.4).opacityMul == 1)
        #expect(grow.delta(at: 0.8).isIdentity())
    }
}
