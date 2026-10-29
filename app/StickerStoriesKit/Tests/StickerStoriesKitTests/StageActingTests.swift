import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct StageActingTests {
    let world = shoreWorld()
    let screen = StageScreen(visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750))
    let surfer = UUID()

    /// Walking on the sand, paddling in the sea (its back to us going out).
    let surferMoves = [
        StageMove(id: "walk", cycle: 0.8, stride: 0.45, facing: .left),
        StageMove(id: "paddle", cycle: 0.8, stride: 0.5, on: ["sea"], stays: true, waterline: 0.3, facing: .left, away: "paddle-out"),
        StageMove(id: "paddle-out", cycle: 0.8, stride: 0.5, on: ["sea"], waterline: 0.3, facing: .left),
    ]

    func plan(_ goes: [GoTrigger], at feet: SceneSpace.Point) -> StagePlan? {
        var random = SeededGenerator(state: 3)
        let actor = StageActor(
            id: surfer, stickerID: "fox", size: 0.3, ratio: 0.6, stage: StickerStage(entrance: .hop, on: ["sand"]),
            moves: surferMoves, placed: feet)
        return StageDirector.plan(
            world: world, screen: screen, actors: [actor], entrances: [], goes: goes, policy: .standard, random: &random)[surfer]
    }

    @Test func goingOutToSeaItShowsItsBackAndRestsLookingAtUs() throws {
        let p = try #require(plan([GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "sea", by: "paddle")], at: .init(0.3, 0.12)))
        let out = try #require(p.legs.last)
        #expect(out.move == "paddle" && out.away == "paddle-out")
        #expect(p.travel(at: (out.at + out.end) / 2)?.move == "paddle-out")
        // From its back to the front as it gets there: a quick squash
        // through edge-on, never a cut.
        #expect(abs(abs(p.sample(at: out.end).facing) - StagePlan.narrowest) < 1e-6)
        #expect(abs(p.sample(at: out.end - StagePlan.turn).facing) == 1 && abs(p.sample(at: out.end + StagePlan.turn).facing) == 1)
        // Loaded before the story plays: both.
        #expect(p.movesPlayed.isSuperset(of: ["paddle", "paddle-out"]))
        // There, afloat, paddling on — looking at us.
        let there = try #require(p.travel(at: out.end + 2))
        #expect(there.move == "paddle" && there.stays)
        // Out in open water, not hugging the shore.
        let at = try #require(out.path.last).ground
        #expect(world.water(at: at) == "sea" && world.inOpenWater(at))
        // Back to the sand: it comes towards us on its own move.
        let back = try #require(plan(
            [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "sea", by: "paddle"),
             GoTrigger(at: 20, stickerID: "fox", kind: .to, target: "sand", by: "paddle")], at: .init(0.3, 0.12)))
        let home = back.legs.filter { $0.at >= 20 && $0.move == "paddle" }
        #expect(!home.isEmpty && home.allSatisfy { $0.away == nil })
    }

    @Test func onHisBoardHeFacesTheWayTheWavesRollAndSitsWaiting() throws {
        // His art faces left; on the board he faces right, sitting to wait.
        let moves = [
            StageMove(id: "walk", cycle: 0.8, stride: 0.45, facing: .left),
            StageMove(
                id: "paddle", cycle: 0.8, stride: 0.5, on: ["sea"], stays: true, waterline: 0.3, facing: .left,
                faces: .right, rest: "wait"),
            StageMove(id: "wait", cycle: 2, stride: 0.1, on: ["sea"], stays: true, waterline: 0.3, facing: .left, faces: .right),
        ]
        func plan(_ goes: [GoTrigger], at feet: SceneSpace.Point) -> StagePlan? {
            var random = SeededGenerator(state: 3)
            let actor = StageActor(
                id: surfer, stickerID: "fox", size: 0.3, ratio: 0.6, stage: StickerStage(entrance: .hop, on: ["sand"]),
                moves: moves, placed: feet)
            return StageDirector.plan(
                world: world, screen: screen, actors: [actor], entrances: [], goes: goes, policy: .standard, random: &random)[surfer]
        }
        for feet in [SceneSpace.Point(0.2, 0.12), SceneSpace.Point(0.8, 0.12)] {
            let p = try #require(plan([GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "sea", by: "paddle")], at: feet))
            let out = try #require(p.legs.last)
            #expect(out.move == "paddle" && out.facingTo == -1 && out.ways.isEmpty)
            // There, he sits on his board facing the same way.
            let there = try #require(p.travel(at: out.end + 2))
            #expect(there.move == "wait" && there.stays && p.sample(at: out.end + 2).facing == -1)
            #expect(p.movesPlayed.contains("wait"))
        }
        // An action that happens in the sea takes him out there paddling.
        let p = try #require(plan([GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "sea", unlessThere: true)], at: .init(0.3, 0.12)))
        #expect(p.legs.last?.move == "paddle")
    }

    @Test func openWaterIsAThirdOfTheWayOut() throws {
        // The sea runs from v 0.3 (its waterline) to 0.42 at u 0.3.
        let near = world.groundPoint(.init(0.3, 0.31)), far = world.groundPoint(.init(0.3, 0.4))
        #expect(try #require(world.outInWater(near)) < 0.2 && !world.inOpenWater(near))
        #expect(try #require(world.outInWater(far)) > 0.7 && world.inOpenWater(far))
        #expect(world.outInWater(world.groundPoint(.init(0.3, 0.2))) == nil)
    }

    @Test func inTheWaterAnActionNotDoneThereKeepsToItsFace() {
        let paddling = StageTravel(at: 0, duration: 3, move: "paddle", stays: true)
        let paddle = surferMoves[1]
        // A laugh while he paddles: his face only.
        #expect(StageActing.keepsToFace(actionOn: [], travel: paddling, move: paddle, water: "sea"))
        // Riding a wave, done in the sea: it plays.
        #expect(!StageActing.keepsToFace(actionOn: ["sea"], travel: paddling, move: paddle, water: "sea"))
        // On the sand, or on a move that does not stay (a duckling swimming): it plays.
        #expect(!StageActing.keepsToFace(actionOn: [], travel: paddling, move: paddle, water: nil))
        let swimming = StageTravel(at: 0, duration: 3, move: "swim", stays: false)
        let swim = StageMove(id: "swim", cycle: 0.8, stride: 0.5, on: ["pond"], waterline: 0.25, facing: .right)
        #expect(!StageActing.keepsToFace(actionOn: [], travel: swimming, move: swim, water: "pond"))
    }

    @Test func anActionThatFacesAWayTurnsTheWholeStickerAndBack() {
        // The art looks left; riding the wave faces right: mirrored.
        func at(_ elapsed: Double, _ duration: Double? = 4) -> Double {
            StageActing.facing(1, art: .left, faces: .right, elapsed: elapsed, duration: duration)
        }
        #expect(at(0) == 1)
        #expect(at(1) == -1 && at(3.5) == -1)
        #expect(at(4) == 1)
        #expect(at(10, nil) == -1)
        // Already facing right (mirrored): it stays.
        #expect(StageActing.facing(-1, art: .left, faces: .right, elapsed: 0, duration: 4) == -1)
        // Its art already looks right: no mirror.
        #expect(StageActing.facing(1, art: .right, faces: .right, elapsed: 1, duration: 4) == 1)
        #expect(StageActing.facing(0.5, art: .left, faces: nil, elapsed: 1, duration: 4) == 0.5)
    }

    @Test func theMoveKeepsTheBodyAndTheActionGivesTheFace() throws {
        let attachment = #"{"part": "p", "x": 0, "y": 0, "w": 1, "h": 1}"#
        let json = """
            {"sticker": "surfer", "atlas": "a.webp", "size": 100,
             "parts": {"p": {"rect": [0, 0, 1, 1], "border": [0, 0, 1, 1], "pad": 0}},
             "bones": [{"id": "root", "x": 0, "y": 0}],
             "slots": [
               {"id": "body", "bone": "root", "default": "stand", "attachments": {"stand": \(attachment), "paddle": \(attachment)}},
               {"id": "eyes", "bone": "root", "default": "open", "attachments": {"open": \(attachment), "squint": \(attachment)}},
               {"id": "mouth", "bone": "root", "default": "smile", "attachments": {"smile": \(attachment), "laugh": \(attachment)}}],
             "faces": {"happy": {"mouth": "smile"}},
             "idle": {"blink": {"eyes": "closed"}}}
            """
        let rig = try JSONDecoder().decode(PuppetRig.self, from: Data(json.utf8))
        #expect(rig.faceSlots == ["eyes", "mouth"])
        let move = PuppetPose(bones: ["root": BonePose(r: 10)], slots: ["body": "paddle", "eyes": "open", "mouth": "smile"])
        let laugh = PuppetPose(bones: ["root": BonePose(r: -20)], slots: ["body": "stand", "eyes": "squint", "mouth": "laugh"])
        let worn = move.wearingFace(of: laugh, rig: rig)
        #expect(worn.bones == move.bones && worn.slots == ["body": "paddle", "eyes": "squint", "mouth": "laugh"])
        // Its back to us: the face it hides stays hidden.
        var back = move
        back.slots["eyes"] = PuppetRig.hidden
        back.slots["mouth"] = PuppetRig.hidden
        #expect(back.wearingFace(of: laugh, rig: rig).slots == back.slots)
    }

    @Test func anActionOverAMoveThatGoesOnSkipsItsStillEnds() {
        // Riding a wave (12 keys) over paddling: never standing still on
        // the water, going in or coming out.
        let into = StageActing.overMove(LiveTween(frame: 0, next: 1, progress: 0.5), keys: 12)
        #expect(into == LiveTween(frame: 1, next: 1, progress: 0))
        let riding = LiveTween(frame: 5, next: 6, progress: 0.3)
        #expect(StageActing.overMove(riding, keys: 12) == riding)
        #expect(StageActing.overMove(LiveTween(frame: 10, next: 11, progress: 0.1), keys: 12) == nil)
        #expect(StageActing.overMove(LiveTween(frame: 11, next: 11, progress: 0), keys: 12) == nil)
    }
}
