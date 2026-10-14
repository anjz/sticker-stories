import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct PuppetTests {
    static let rigJSON = """
        { "sticker": "owl", "atlas": "anims/owl.rig.webp", "size": 768,
          "parts": { "body": { "rect": [0, 0, 10, 10], "border": [12, 0, 14, 14], "pad": 2 },
                     "eye": { "rect": [0, 20, 4, 4], "border": [6, 20, 8, 8], "pad": 2 },
                     "shut": { "rect": [0, 30, 4, 4], "border": [6, 30, 8, 8], "pad": 2 } },
          "bones": [ { "id": "root", "x": 380, "y": 700 }, { "id": "head", "parent": "root", "x": 380, "y": 360 } ],
          "slots": [ { "id": "body", "bone": "root", "default": "body",
                       "attachments": { "body": { "part": "body", "x": 100, "y": 300, "w": 400, "h": 400 } } },
                     { "id": "eye", "bone": "head", "default": "open",
                       "attachments": { "open": { "part": "eye", "x": 300, "y": 200, "w": 60, "h": 60, "flip": true },
                                        "shut": { "part": "shut", "x": 300, "y": 200, "w": 60, "h": 60 } } } ],
          "faces": { "sleeping": { "eye": "shut" } },
          "idle": { "breathe": "root", "blink": { "eye": "shut" } } }
        """

    static let rig = try! JSONDecoder().decode(PuppetRig.self, from: Data(rigJSON.utf8))

    @Test func decodesARig() {
        let rig = Self.rig
        #expect(rig.isWellFormed)
        #expect(rig.bones.map(\.id) == ["root", "head"])
        #expect(rig.slots[1].attachments["open"]?.flip == true)
        #expect(rig.slots[1].attachments["shut"]?.rotate == 0)
        #expect(rig.faces["sleeping"] == ["eye": "shut"])
    }

    /// Up in the air, the wings (here the head, with the eye it carries)
    /// keep the flight's pose over an action; the rest plays the action.
    @Test func wingsKeepTheFlightOverAnAction() {
        let rig = Self.rig
        var action = PuppetPose.rest(face: ExpressionTrigger.normal, rig: rig)
        action.bones["root"] = BonePose(r: 10)
        action.bones["head"] = BonePose(r: -5)
        var flight = PuppetPose.rest(face: ExpressionTrigger.normal, rig: rig)
        flight.bones["root"] = BonePose(y: 40)
        flight.bones["head"] = BonePose(r: 30)
        flight.slots["eye"] = "shut"
        let both = action.flying(["head"], as: flight, rig: rig)
        #expect(both.bones["root"] == BonePose(r: 10))
        #expect(both.bones["head"] == BonePose(r: 30))
        #expect(both.slots["eye"] == "shut" && both.slots["body"] == "body")
        #expect(action.flying([], as: flight, rig: rig) == action)
        // Whatever hangs on a wing goes with it.
        #expect(action.flying(["root"], as: flight, rig: rig).bones["head"] == BonePose(r: 30))
    }

    @Test func aBoneBeforeItsParentIsNotWellFormed() throws {
        let json = Self.rigJSON.replacingOccurrences(
            of: #"{ "id": "root", "x": 380, "y": 700 }, { "id": "head", "parent": "root", "x": 380, "y": 360 }"#,
            with: #"{ "id": "head", "parent": "root", "x": 380, "y": 360 }, { "id": "root", "x": 380, "y": 700 }"#)
        let rig = try JSONDecoder().decode(PuppetRig.self, from: Data(json.utf8))
        #expect(!rig.isWellFormed)
    }

    @Test func keysEaseBonesAndSwapSlotsOnTheirKey() throws {
        let keys = try JSONDecoder().decode([PuppetKey].self, from: Data("""
            [ { "hold": 0.4, "ease": "linear", "bones": { "head": { "r": -10, "sy": 0.5 } } },
              { "hold": 0.2, "bones": { "head": { "r": 10, "x": 4 } }, "slots": { "eye": "shut" } },
              { "hold": 0.2, "ease": "wobble" } ]
            """.utf8))
        #expect(keys[1].ease == .inOut)
        #expect(keys[2].ease == .inOut)  // unknown: smooth
        let half = PuppetPose.between(keys[0], keys[1], progress: 0.5, face: "normal", rig: Self.rig)
        #expect(half.bones["head"] == BonePose(r: 0, x: 2, y: 0, sx: 1, sy: 0.75))
        #expect(half.bones["root"] == .rest)
        #expect(half.slots == ["body": "body", "eye": "open"])
        // The swap is the first key's: it shows from that key on.
        let swapped = PuppetPose.between(keys[1], keys[2], progress: 0.25, face: "normal", rig: Self.rig)
        #expect(swapped.slots["eye"] == "shut")
        // Smooth in and out: a quarter of the way is less than a quarter.
        #expect(swapped.bones["head"]!.r > 10 * 0.75)
    }

    @Test func aKeyWinsOverTheFaceAndTheFaceOverTheDefault() {
        let plain = PuppetKey(hold: 0.3)
        let opened = PuppetKey(hold: 0.3, slots: ["eye": "open"])
        #expect(PuppetPose.between(plain, plain, progress: 0, face: "sleeping", rig: Self.rig).slots["eye"] == "shut")
        #expect(PuppetPose.between(opened, plain, progress: 0, face: "sleeping", rig: Self.rig).slots["eye"] == "open")
        #expect(PuppetPose.rest(face: "happy", rig: Self.rig).slots["eye"] == "open")  // no such face: defaults
    }

    @Test func idlingBreathesAndBlinksUnlessTheFaceSetsTheEyes() {
        let rig = Self.rig
        let quarter = PuppetPose.idle(at: PuppetPose.breath / 4, face: "normal", rig: rig)
        #expect(quarter.bones["root"]!.sy > 1)
        #expect(quarter.slots["eye"] == "open")
        let blinking = PuppetPose.idle(at: PuppetPose.blinkEvery - 0.05, face: "normal", rig: rig)
        #expect(blinking.slots["eye"] == "shut")
        // A face that sets the eyes itself is not blinked over.
        #expect(PuppetPose.idle(at: PuppetPose.blinkEvery - 0.05, face: "sleeping", rig: rig).slots["eye"] == "shut")
    }

    @Test func tweenFollowsTheFramesAndMovesOnToTheNextKey() {
        let doze = LiveFrames(holds: [0.5, 0.5, 0.5, 0.5], pause: 2)
        #expect(doze.tween(.whole, at: 0.25) == LiveTween(frame: 0, next: 1, progress: 0.5))
        #expect(doze.tween(.whole, at: 1.75) == LiveTween(frame: 3, next: 3, progress: 0.5))
        #expect(doze.tween(.whole, at: 2.1) == nil)
        // A hold reaches its pause key and stays on it.
        #expect(doze.tween(.toPause, at: 0.75) == LiveTween(frame: 1, next: 2, progress: 0.5))
        #expect(doze.tween(.toPause, at: 9) == LiveTween(frame: 2, next: 2, progress: 0))
        #expect(doze.tween(.fromPause(held: true), at: 0.25) == LiveTween(frame: 2, next: 3, progress: 0.5))
        // Every tween is on the frame `state` shows.
        for t in stride(from: 0.0, through: 2.0, by: 0.05) {
            #expect(doze.tween(.whole, at: t)?.frame == doze.state(.whole, at: t)?.frame)
        }
    }

    @Test func aMovesLoopGoesRoundThenSettles() {
        let fly = LiveFrames(holds: [0.125, 0.25, 0.25, 0.5, 0.5], loop: 1...2)
        #expect(fly.tween(.move(travel: 2), at: 0.125) == LiveTween(frame: 1, next: 2, progress: 0.5))
        #expect(fly.tween(.move(travel: 2), at: 0.375) == LiveTween(frame: 2, next: 1, progress: 0.5))
        #expect(fly.tween(.move(travel: 1), at: 1.25) == LiveTween(frame: 3, next: 4, progress: 0.5))
        #expect(fly.tween(.move(travel: 1), at: 1.75) == LiveTween(frame: 4, next: 4, progress: 0.5))
        #expect(fly.tween(.move(travel: 1, stays: true), at: 5.1)?.frame == 1)
    }

    @Test func aRollKeepsRollingRoundItsLoop() {
        let rig = Self.rig
        let bone = rig.bones[0].id
        let last = PuppetKey(hold: 0.25, ease: .linear, bones: [bone: BonePose(r: 240)])
        let first = PuppetKey(hold: 0.25, ease: .linear, bones: [bone: BonePose(r: 0)])
        // Round the loop from 240° to its start: on to 300°, not back to 120°.
        let on = PuppetPose.between(last, first, progress: 0.5, face: "normal", rig: rig, wrapping: true)
        #expect(on.bones[bone]?.r == 300)
        let back = PuppetPose.between(last, first, progress: 0.5, face: "normal", rig: rig)
        #expect(back.bones[bone]?.r == 120)
    }
}
