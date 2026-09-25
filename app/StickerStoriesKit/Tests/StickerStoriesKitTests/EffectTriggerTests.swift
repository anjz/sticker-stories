import Foundation
import Testing

@testable import StickerStoriesKit

struct EffectTriggerTests {
    private func file(_ json: String) throws -> EffectTriggerFile {
        try EffectTriggerFile(data: Data(json.utf8))
    }

    @Test func decodesTheDocumentedExample() throws {
        let f = try file("""
            { "schema": 1, "triggers": [
              { "at": 3.2, "cue": "sneeze", "sticker": "fox", "effect": "wobble", "repeat": 3 },
              { "at": 3.2, "sticker": "fox", "effect": "sparkle", "intensity": 0.8 },
              { "at": 0, "cue": "start", "sticker": "butterfly", "effect": "float", "repeat": "loop" },
              { "at": 41.5, "sticker": "bird", "effect": "fade-out", "hold": true },
              { "at": 5, "sticker": "owl", "effect": "tint", "color": "#FF0000", "duration": 0.2 }
            ] }
            """)
        #expect(f.warnings.isEmpty)
        #expect(f.triggers.count == 5)
        #expect(f.triggers.map(\.at) == [0, 3.2, 3.2, 5, 41.5])  // sorted by time
        let float = f.triggers[0]
        #expect(float.effect == .float && float.options.repeatCount == .loop && float.cue == "start")
        let wobble = f.triggers[1]
        #expect(wobble.options.repeatCount == .times(3) && wobble.cue == "sneeze")
        #expect(f.triggers[2].options.intensity == 0.8)
        let tint = f.triggers[3]
        #expect(tint.options.color == RGBA(hex: "#FF0000") && tint.options.duration == 0.2)
        #expect(f.triggers[4].options.hold)
    }

    // Criterion 9: unknown effect, out-of-range duration, tint without colour → a log line each, no crash.
    @Test func nonFatalProblemsAreSkippedOrClampedWithWarnings() throws {
        let f = try file("""
            { "schema": 1, "triggers": [
              { "at": 1, "sticker": "fox", "effect": "explode" },
              { "at": 1, "sticker": "fox", "effect": "pulse", "duration": 99, "intensity": 3, "repeat": 200, "mystery": true },
              { "at": 1, "sticker": "fox", "effect": "tint" },
              { "at": 1, "effect": "pulse" },
              { "sticker": "fox", "effect": "pulse" },
              { "at": 1, "sticker": "fox", "effect": "glow", "color": "orange" },
              "not an object"
            ] }
            """)
        #expect(f.triggers.count == 2)
        let clamped = f.triggers[0]
        #expect(clamped.options.duration == 30 && clamped.options.intensity == 1 && clamped.options.repeatCount == .times(50))
        #expect(f.triggers[1].effect == .glow && f.triggers[1].options.color == nil)  // default applied at start
        #expect(f.warnings.count == 9)
    }

    @Test func decodesCanvasTriggersFromTheSameList() throws {
        let f = try file("""
            { "schema": 1, "triggers": [
              { "at": 4.5, "cue": "rain", "effect": "rain", "intensity": 0.8, "duration": 20 },
              { "at": 1.0, "sticker": "fox", "effect": "hop" },
              { "at": 2.0, "effect": "fog" },
              { "at": 3.0, "effect": "dimlight", "sticker": "fox", "repeat": 2, "hold": true, "color": "#FFFFFF" },
              { "at": 9.0, "effect": "rainbow", "duration": 500, "intensity": 2 },
              { "effect": "sunshine" }
            ] }
            """)
        #expect(f.triggers.count == 1 && f.triggers[0].effect == .hop)
        #expect(f.canvasTriggers.map(\.effect) == [.fog, .dimlight, .rain, .rainbow])  // sorted by time
        let rain = f.canvasTriggers[2]
        #expect(rain.at == 4.5 && rain.cue == "rain" && rain.options == CanvasEffectOptions(intensity: 0.8, duration: 20))
        #expect(f.canvasTriggers[0].options == CanvasEffectOptions())
        #expect(f.canvasTriggers[3].options == CanvasEffectOptions(intensity: 1, duration: 120))  // clamped
        // Four ignored sticker keys on dimlight, two clamps on rainbow, one missing `at`.
        #expect(f.warnings.count == 7)
    }

    @Test func malformedJSONAndWrongShapesThrow() {
        #expect(throws: EffectTriggerFile.DecodingError.self) { try file("{ not json") }
        #expect(throws: EffectTriggerFile.DecodingError.self) { try file("[]") }
        #expect(throws: EffectTriggerFile.DecodingError.self) { try file("{ \"schema\": 1 }") }
        #expect(throws: EffectTriggerFile.DecodingError.unsupportedSchema(2)) { try file("{ \"schema\": 2, \"triggers\": [] }") }
    }

    @Test func missingSchemaIsAssumedWithAWarning() throws {
        let f = try file("{ \"triggers\": [] }")
        #expect(f.schema == 1 && f.warnings.count == 1 && f.triggers.isEmpty)
    }

    @Test func colorParsing() {
        #expect(RGBA(hex: "#FFD166") == RGBA(red: 1, green: 209.0 / 255, blue: 102.0 / 255))
        #expect(RGBA(hex: "ffd166")?.hexString == "#FFD166")
        #expect(RGBA(hex: "#FFFFFF80")?.alpha == 128.0 / 255)
        #expect(RGBA(hex: "#FFF") == nil)
        #expect(RGBA(hex: "#GGGGGG") == nil)
        #expect(RGBA.white.isWhite && !(RGBA(hex: "#FF0000")!.isWhite))
    }

    @Test func decodesLiveAnimationTriggersFromTheSameList() throws {
        let f = try file("""
            { "schema": 1, "triggers": [
              { "at": 6.2, "cue": "yawned", "sticker": "bear", "animation": "yawn" },
              { "at": 1.0, "sticker": "fox", "effect": "hop" },
              { "at": 2.5, "sticker": "owl", "animation": "sleepy-blink", "repeat": 2 },
              { "at": 3.0, "animation": "yawn" },
              { "at": 3.0, "sticker": "bear", "animation": "" }
            ] }
            """)
        #expect(f.triggers.count == 1 && f.canvasTriggers.isEmpty)
        #expect(f.liveTriggers == [
            LiveAnimationTrigger(at: 2.5, stickerID: "owl", animationID: "sleepy-blink"),
            LiveAnimationTrigger(at: 6.2, cue: "yawned", stickerID: "bear", animationID: "yawn"),
        ])
        #expect(f.warnings.count == 3)  // repeat ignored, no sticker, empty animation
    }

    @Test func decodesLiveModes() throws {
        let f = try file("""
            { "schema": 1, "triggers": [
              { "at": 1, "sticker": "snail", "animation": "hide", "mode": "hold" },
              { "at": 5, "sticker": "snail", "animation": "hide", "mode": "resume" },
              { "at": 6, "sticker": "snail", "animation": "hide", "mode": "twirl" }
            ] }
            """)
        #expect(f.liveTriggers.map(\.mode) == [.hold, .resume, .whole])
        #expect(f.warnings.count == 1)
        #expect(!EffectPolicy(calmMode: true).allowsLiveAnimations && EffectPolicy.standard.allowsLiveAnimations)
    }

    // Four frames of 0.5 s, pause on frame 2.
    private let snail = LiveFrames(holds: [0.5, 0.5, 0.5, 0.5], pause: 2)

    @Test func wholePlayDissolvesInAndOutOfTheStillSticker() throws {
        #expect(snail.duration(.whole) == 2)
        let start = try #require(snail.state(.whole, at: 0))
        #expect(start.frame == 0 && start.liveAlpha == 0 && start.stillAlpha == 1)
        let early = try #require(snail.state(.whole, at: 0.3))
        #expect(early.liveAlpha == 1 && early.stillAlpha == 1)  // frames in, still underneath
        #expect(snail.state(.whole, at: 0.49)!.stillAlpha < 0.1)  // then the still dissolves away
        #expect(snail.state(.whole, at: 0.75) == LiveFrameState(frame: 1, liveAlpha: 1, stillAlpha: 0))
        let end = try #require(snail.state(.whole, at: 1.95))
        #expect(end.frame == 3 && end.stillAlpha == 1 && end.liveAlpha < 0.5)
        #expect(snail.state(.whole, at: 2) == nil)
    }

    @Test func holdStaysOnThePauseFrameAndResumePlaysOnFromIt() {
        #expect(snail.duration(.toPause) == nil)
        #expect(snail.state(.toPause, at: 60) == LiveFrameState(frame: 2, liveAlpha: 1, stillAlpha: 0))
        #expect(snail.state(.fromPause(held: true), at: 0) == LiveFrameState(frame: 2, liveAlpha: 1, stillAlpha: 0))
        #expect(snail.state(.fromPause(held: false), at: 0)?.liveAlpha == 0)  // no hold before: dissolve in
        #expect(snail.duration(.fromPause(held: true)) == 1)
        #expect(snail.state(.fromPause(held: true), at: 1) == nil)
    }

    @Test func moveLoopsWhileTravellingThenSettles() {
        // Frame 0 rest, 1–4 a walk cycle of 0.1 s each, 5 settles back to rest.
        let walk = LiveFrames(holds: [0.1, 0.1, 0.1, 0.1, 0.1, 0.4], loop: 1...4)
        #expect(abs(walk.loopDuration - 0.4) < 1e-9)
        #expect(walk.state(.move(travel: 2), at: 0) == LiveFrameState(frame: 1, liveAlpha: 1, stillAlpha: 0))
        #expect(walk.state(.move(travel: 2), at: 0.45)?.frame == 1)  // round again
        #expect(walk.state(.move(travel: 2), at: 1.55)?.frame == 4)
        #expect(walk.state(.move(travel: 2), at: 2.05)?.frame == 5)  // arrived: settling
        #expect(walk.duration(.move(travel: 2)).map { abs($0 - 2.4) < 1e-9 } == true)
        #expect(walk.state(.move(travel: 2), at: 2.41) == nil)
        // A sprout plays once from frame 1.
        let sprout = LiveFrames(holds: [0.1, 0.2, 0.2, 0.3])
        #expect(sprout.state(.move(travel: 5), at: 0)?.frame == 1)
        #expect(sprout.duration(.move(travel: 5)).map { abs($0 - 0.7) < 1e-9 } == true)
    }

    @Test func timelineFollowsTheLastTriggerForEachSticker() {
        let timeline = LiveTimeline(triggers: [
            LiveAnimationTrigger(at: 10, stickerID: "snail", animationID: "hide", mode: .resume),
            LiveAnimationTrigger(at: 2, stickerID: "snail", animationID: "hide", mode: .hold),
            LiveAnimationTrigger(at: 4, stickerID: "bear", animationID: "yawn"),
        ])
        let frames: (LiveAnimationKey) -> LiveFrames? = { key in
            key.animationID == "hide" ? self.snail : LiveFrames(holds: [1, 1])
        }
        #expect(timeline.animations.count == 2)
        #expect(timeline.current(for: "snail", at: 1, frames: frames) == nil)
        #expect(timeline.current(for: "snail", at: 9, frames: frames)?.part == .toPause)
        #expect(timeline.current(for: "snail", at: 10.2, frames: frames)?.part == .fromPause(held: true))
        #expect(timeline.current(for: "snail", at: 11.5, frames: frames) == nil)  // done
        #expect(timeline.current(for: "snail", at: 3, frames: frames)?.part == .toPause)  // a seek back is exact
        #expect(timeline.current(for: "bear", at: 5, frames: frames)?.elapsed == 1)
        #expect(timeline.current(for: "bear", at: 6.5, frames: frames) == nil)
        #expect(timeline.current(for: "bear", at: 5, frames: { _ in nil }) == nil)  // not loaded: still
    }
}
