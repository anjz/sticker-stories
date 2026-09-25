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
              { "at": 4.2, "cue": "owl", "sticker": "owl", "enter": true, "by": "hop" },
              { "at": 0, "sticker": "fox", "enter": true },
              { "at": 6, "sticker": "fox", "enter": true },
              { "at": 1, "sticker": "all", "enter": true },
              { "at": 1, "sticker": "bear", "enter": false },
              { "at": 2, "sticker": "fox", "effect": "hop" } ] }
            """
        let file = try EffectTriggerFile(data: Data(json.utf8))
        #expect(file.entranceTriggers == [
            EntranceTrigger(at: 0, stickerID: "fox"),
            EntranceTrigger(at: 4.2, cue: "owl", stickerID: "owl", by: "hop"),
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

    @Test func moveFramesSetThePaceTheGaitAndTheWayRound() {
        // The fox's frames walk right, 0.5 widths a 0.8 s loop; the tree sprouts.
        let moves: [String: [StageMove]] = [
            "fox": [StageMove(id: "trot", cycle: 0.8, stride: 0.5, facing: .right)],
            "owl": [StageMove(id: "fly", cycle: 0.5, stride: 1, flies: true, facing: .left)],
            "tree": [StageMove(id: "sprout", seconds: 1.4)],
        ]
        for seed in [UInt64(1), 7, 42] {
            var random = SeededGenerator(state: seed)
            let plans = StagePlanner.plan(
                entrances: ["fox", "owl", "tree"].map { EntranceTrigger(at: 0, stickerID: $0) },
                placed: [], stages: Self.stages, moves: moves, scene: Self.scene, obstacles: [], policy: .standard,
                random: &random)
            let fox = plans[0], owl = plans[1], tree = plans[2]
            #expect(fox.gait == .walk)
            let distance = (fox.startOffset.x * fox.startOffset.x + fox.startOffset.y * fox.startOffset.y).squareRoot()
            #expect(abs(fox.duration - min(max(distance / (0.5 / 0.8), 1.2), 6)) < 1e-9)
            // Coming in from the left it travels right, as its frames do.
            #expect(fox.mirrored == (fox.startOffset.x > 0))
            #expect(owl.mirrored == (owl.startOffset.x < 0))
            #expect(tree.motion == .sprout && tree.duration == 1.4 && tree.travel == 0)
            #expect([fox.move, owl.move, tree.move] == ["trot", "fly", "sprout"])
        }
        // Calm: no frames, so no gait from them either.
        var random = SeededGenerator(state: 3)
        let calm = StagePlanner.plan(
            entrances: [EntranceTrigger(at: 0, stickerID: "fox")], placed: [], stages: Self.stages, moves: moves,
            scene: Self.scene, obstacles: [], policy: EffectPolicy(calmMode: true), random: &random)
        #expect(calm[0].motion == .fade && !calm[0].mirrored)
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

    static let features: [String: SceneFeature] = [
        "branches": SceneFeature(description: "The trees' side branches.", areas: [
            .init(x: [0.12, 0.18], y: [0.84, 0.9]), .init(x: [0.82, 0.88], y: [0.85, 0.92]),
        ]),
        "sky": SceneFeature(description: "Open sky.", areas: [.init(x: [0.15, 0.85], y: [0.55, 0.85])]),
    ]

    func perch(
        _ ids: [String], scene: StagePlanner.Scene = Self.scene, obstacles: [StageObstacle] = [], seed: UInt64 = 5
    ) -> [EntrancePlan] {
        var random = SeededGenerator(state: seed)
        let bird = StickerStage(entrance: .fly, on: ["branches", "sky"])
        return StagePlanner.plan(
            entrances: ids.enumerated().map { EntranceTrigger(at: Double($0.offset), stickerID: $0.element) },
            placed: [], stages: Dictionary(uniqueKeysWithValues: ids.map { ($0, bird) }), features: Self.features,
            scene: scene, obstacles: obstacles, policy: .standard, random: &random)
    }

    @Test func landsOnItsFirstFeatureWithRoom() {
        for seed in 1...20 {
            let plans = perch(["bird", "owl", "woodpecker"], seed: UInt64(seed))
            // Two branches (one per tree) have room for two birds; the third
            // goes to the sky.
            let onBranches = plans.filter { $0.target.y >= 0.84 * 750 - 1e-9 && ($0.target.x <= 200 || $0.target.x >= 800) }
            #expect(onBranches.count == 2, "seed \(seed): \(plans.map { ($0.target.x, $0.target.y) })")
            #expect(plans[0].target.y >= 630 && plans[1].target.y >= 630)
            let third = plans[2].target
            #expect((150...850).contains(third.x) && (412.5...637.5).contains(third.y))
        }
    }

    @Test func aFeatureOffScreenIsSkipped() {
        var scene = Self.scene
        // A portrait window over the middle of the art: neither tree shows.
        scene.visible = StageRect(minX: 300, minY: 0, maxX: 700, maxY: 750)
        scene.usable = StageRect(minX: 340, minY: 40, maxX: 660, maxY: 710)
        let bird = perch(["bird"], scene: scene)[0].target
        #expect((340...660).contains(bird.x) && (412.5...637.5).contains(bird.y))
    }

    @Test func comesInAnotherWayWhenTheStoryNamesIt() {
        // The bird usually flies onto a branch; hopping, it comes along the
        // ground onto the meadow. The ladybug usually crawls; flying, it
        // glides in.
        let features = Self.features.merging(
            ["meadow": SceneFeature(description: "Grass.", areas: [.init(x: [0.1, 0.9], y: [0.16, 0.36])])]) { a, _ in a }
        let moves: [String: [StageMove]] = [
            "bird": [
                StageMove(id: "fly", cycle: 0.6, stride: 1.2, flies: true, facing: .right),
                StageMove(id: "hop", cycle: 0.5, stride: 0.5, hops: true, on: ["meadow"], facing: .right),
            ],
            "ladybug": [
                StageMove(id: "crawl", cycle: 0.6, stride: 0.35, facing: .right),
                StageMove(id: "fly", cycle: 0.5, stride: 1, flies: true, facing: .right),
            ],
        ]
        let stages: [String: StickerStage] = [
            "bird": StickerStage(entrance: .fly, on: ["branches", "sky"]),
            "ladybug": StickerStage(entrance: .hop, on: ["meadow"]),
        ]
        for seed in [UInt64(1), 9] {
            var random = SeededGenerator(state: seed)
            let plans = StagePlanner.plan(
                entrances: [EntranceTrigger(at: 0, stickerID: "bird", by: "hop"),
                            EntranceTrigger(at: 1, stickerID: "ladybug", by: "fly")],
                placed: [], stages: stages, features: features, moves: moves, scene: Self.scene, obstacles: [],
                policy: .standard, random: &random)
            let bird = plans[0], ladybug = plans[1]
            #expect(bird.motion == .hop && bird.gait == .hops(cycle: 0.5) && bird.move == "hop")
            #expect((0.16 * 750...0.36 * 750).contains(bird.target.y))
            #expect(ladybug.motion == .fly && ladybug.move == "fly")
            #expect((0.16 * 750...0.36 * 750).contains(ladybug.target.y))
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

    @Test func hoppingFramesLeapOncePerLoop() {
        let leaps = EntrancePlan(
            stickerID: "frog", at: 0, motion: .hop, target: StagePoint(x: 500, y: 200),
            startOffset: (x: -4, y: 0), duration: 3, gait: .hops(cycle: 0.6))
        #expect(abs(leaps.delta(at: 0.6).offsetYSelf) < 1e-9)  // landed, one loop in
        #expect(leaps.delta(at: 0.3).offsetYSelf < -0.2)  // the top of the leap
        #expect(abs(leaps.delta(at: 1.5).offsetXSelf + 2) < 1e-9)  // an even slide
        let walk = EntrancePlan(
            stickerID: "fox", at: 0, motion: .hop, target: StagePoint(x: 500, y: 200),
            startOffset: (x: -4, y: 0), duration: 3, gait: .walk)
        #expect(walk.delta(at: 1.3).offsetYSelf == 0)  // the legs walk; it does not bounce
    }

    @Test func growFadesInFromSmall() {
        let grow = EntrancePlan(stickerID: "tree", at: 0, motion: .grow, target: StagePoint(x: 0, y: 0), duration: 0.8)
        #expect(grow.delta(at: 0).opacityMul == 0)
        #expect(abs(grow.delta(at: 0).scaleMul - EntrancePlan.growFrom) < 1e-9)
        #expect(grow.delta(at: 0.4).opacityMul == 1)
        #expect(grow.delta(at: 0.8).isIdentity())
    }
}
