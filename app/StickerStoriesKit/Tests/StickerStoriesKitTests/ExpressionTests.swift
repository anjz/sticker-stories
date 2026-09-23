import Foundation
import Testing

@testable import StickerStoriesKit

struct ExpressionTests {
    @Test func decodesExpressionTriggersAndAllTargets() throws {
        let f = try EffectTriggerFile(data: Data("""
            { "schema": 1, "triggers": [
              { "at": 5, "cue": "slept", "sticker": "all", "expression": "sleeping" },
              { "at": 1, "cue": "smiled", "sticker": "bear", "expression": "happy" },
              { "at": 2, "sticker": "all", "effect": "hop" },
              { "at": 3, "sticker": "owl", "expression": "sad", "duration": 2 },
              { "at": 4, "expression": "happy" }
            ] }
            """.utf8))
        #expect(f.expressionTriggers.map(\.expression) == ["happy", "sad", "sleeping"])
        #expect(f.expressionTriggers.last?.stickerID == EffectTrigger.allStickers)
        #expect(f.triggers.count == 1 && f.triggers[0].stickerID == "all")
        #expect(f.warnings.count == 2)  // duration ignored, no sticker
    }

    @Test func facesStayUntilChangedAndAllReachesEveryone() {
        let timeline = ExpressionTimeline(triggers: [
            ExpressionTrigger(at: 1, stickerID: "bear", expression: "happy"),
            ExpressionTrigger(at: 3, stickerID: "all", expression: "surprised"),
            ExpressionTrigger(at: 4, stickerID: "owl", expression: "normal"),
            ExpressionTrigger(at: 6, stickerID: "all", expression: "sleeping"),
        ])
        let placed: Set<String> = ["bear", "owl"]
        #expect(timeline.expressions(at: 0.5, for: placed) == ["bear": "normal", "owl": "normal"])
        #expect(timeline.expressions(at: 2, for: placed) == ["bear": "happy", "owl": "normal"])  // no duration
        #expect(timeline.expressions(at: 3.5, for: placed) == ["bear": "surprised", "owl": "surprised"])
        #expect(timeline.expressions(at: 5, for: placed) == ["bear": "surprised", "owl": "normal"])
        #expect(timeline.expressions(at: 9, for: placed) == ["bear": "sleeping", "owl": "sleeping"])
        #expect(timeline.expressions(at: 2, for: placed) == ["bear": "happy", "owl": "normal"])  // seeking back
        #expect(timeline.expressionsUsed(by: placed) == ["bear": ["happy", "surprised", "sleeping"], "owl": ["surprised", "sleeping"]])
    }

    @Test func allTargetsEveryPlacedSticker() {
        let a = UUID(), b = UUID(), c = UUID()
        let runner = StickerEffectsRunner(
            triggers: [EffectTrigger(at: 0, stickerID: EffectTrigger.allStickers, effect: .hop)],
            targets: ["fox": [a, b], "owl": [c]])
        runner.tick(0.1)
        #expect(Set(runner.active.map(\.target)) == [a, b, c])
    }
}
