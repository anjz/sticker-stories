import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct StickerPlacementTests {
    /// A 1000×750 world, all visible; the woodpecker's beak reaches a
    /// quarter of its 120-point width in front of its centre, and its art
    /// faces left.
    static let scene = StagePlanner.Scene(
        world: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750),
        usable: StageRect(minX: 60, minY: 60, maxX: 940, maxY: 690),
        visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750),
        stickerSize: 120, fronts: ["woodpecker": 0.25])
    static let trunks: [String: SceneFeature] = [
        "trunks": SceneFeature(description: "Bark.", areas: [
            .init(x: [0.05, 0.06], y: [0.5, 0.7], facing: .left),
            .init(x: [0.95, 0.96], y: [0.5, 0.7], facing: .right),
        ])
    ]
    static let moves: [String: [StageMove]] = [
        "woodpecker": [StageMove(id: "fly", cycle: 0.5, stride: 1.2, flies: true, facing: .left)]
    ]
    let woodpecker = UUID()

    @Test func comesInWithItsBeakOnTheBark() {
        for seed in UInt64(1)...12 {
            var random = SeededGenerator(state: seed)
            let plan = StagePlanner.plan(
                entrances: [EntranceTrigger(at: 0, stickerID: "woodpecker")], placed: [],
                stages: ["woodpecker": StickerStage(entrance: .fly, on: ["trunks"])], features: Self.trunks,
                moves: Self.moves, scene: Self.scene, obstacles: [], policy: .standard, random: &random)[0]
            // Centre a quarter width less the overlap (25.2) behind the bark, facing it: on the
            // left tree facing left (its art's way), on the right mirrored.
            if plan.target.x < 500 {
                #expect((75.2...85.2).contains(plan.target.x) && !plan.mirrored && plan.startOffset.x > 0)
            } else {
                #expect((924.8...934.8).contains(plan.target.x) && plan.mirrored && plan.startOffset.x < 0)
            }
            #expect((375...525).contains(plan.target.y))
        }
    }

    func plans(_ goes: [GoTrigger], home: StagePoint, facing: Double = 1) -> [UUID: MotionPlan] {
        var random = SeededGenerator(state: 1)
        return MotionPlanner.plan(
            goes: goes,
            actors: [.init(id: woodpecker, stickerID: "woodpecker", home: home, size: StageSize(width: 120, height: 120),
                           facing: facing, flies: true)],
            features: Self.trunks, moves: Self.moves, scene: Self.scene, policy: .standard, random: &random)
    }

    @Test func goesToTheNearestBarkBeforeItTaps() {
        let live = [LiveAnimationTrigger(at: 0.5, stickerID: "woodpecker", animationID: "tap")]
        let places = [LiveAnimationKey(stickerID: "woodpecker", animationID: "tap"): ["trunks"]]
        let auto = PlacementPlanner.goes(live: live, places: places, goes: [])
        #expect(auto == [GoTrigger(at: 0, stickerID: "woodpecker", kind: .to, target: "trunks", unlessThere: true)])

        // Put in the middle of the meadow: it flies to the left tree (the
        // nearer), beak on the bark, facing it.
        let away = plans(auto, home: StagePoint(x: 480, y: 300))
        let leg = away[woodpecker]!.legs[0]
        #expect(leg.gait == .fly && leg.facingTo == 1)
        #expect(abs(480 + leg.to.x * 120 - 85.2) < 1e-6 && abs(300 - leg.to.y * 120 - 375) < 1e-6)
        // …and taps only once it is there.
        let tap = PlacementPlanner.delayed(live, plans: away, stickers: [woodpecker: "woodpecker"], places: Set(places.keys))
        #expect(tap[0].at == leg.at + leg.duration)

        // Already on the bark, facing it: it stays, and taps on its cue.
        let there = plans(auto, home: StagePoint(x: 84, y: 450))
        #expect(there[woodpecker] == nil)
        // On the right spot but facing away: it turns round.
        #expect(plans(auto, home: StagePoint(x: 84, y: 450), facing: -1)[woodpecker] != nil)
    }

    @Test func onToTheNextTree() {
        // On the left tree's bark, a story sends it to the trunks: the other one.
        let next = plans([GoTrigger(at: 0, stickerID: "woodpecker", kind: .to, target: "trunks")], home: StagePoint(x: 84, y: 450))
        let leg = next[woodpecker]!.legs[0]
        #expect(abs(84 + leg.to.x * 120 - 924.8) < 1e-6 && leg.facingTo == -1)
    }

    @Test func aStoryThatTakesItThereNeedsNoHelp() {
        let live = [LiveAnimationTrigger(at: 5, stickerID: "woodpecker", animationID: "tap")]
        let places = [LiveAnimationKey(stickerID: "woodpecker", animationID: "tap"): ["trunks"]]
        #expect(PlacementPlanner.goes(
            live: live, places: places,
            goes: [GoTrigger(at: 1, stickerID: "woodpecker", kind: .to, target: "trunks")]).isEmpty)
        // Taken somewhere else first: back to a trunk after that move.
        let auto = PlacementPlanner.goes(
            live: live, places: places, goes: [GoTrigger(at: 1, stickerID: "woodpecker", kind: .to, target: "owl")])
        #expect(auto.map(\.at) == [1.001])
    }
}
