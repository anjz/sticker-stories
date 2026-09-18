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
              { "at": 0, "cue": "start", "sticker": "tree", "effect": "sway", "repeat": "loop" },
              { "at": 41.5, "sticker": "bird", "effect": "fade-out", "hold": true },
              { "at": 5, "sticker": "owl", "effect": "tint", "color": "#FF0000", "duration": 0.2 }
            ] }
            """)
        #expect(f.warnings.isEmpty)
        #expect(f.triggers.count == 5)
        #expect(f.triggers.map(\.at) == [0, 3.2, 3.2, 5, 41.5])  // sorted by time
        let sway = f.triggers[0]
        #expect(sway.effect == .sway && sway.options.repeatCount == .loop && sway.cue == "start")
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
}
