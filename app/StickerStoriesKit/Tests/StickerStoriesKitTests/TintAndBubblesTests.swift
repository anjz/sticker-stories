import Foundation
import Testing

@testable import StickerStoriesKit

/// `tint` reaching a full wash at intensity 1, and `bubble-puff`.
struct TintAndBubblesTests {
    private let octopus = UUID()

    private func peak(_ intensity: Double, color: String = "#9C948C", hold: Bool = false) -> Double {
        let effect = ActiveEffect(
            name: .tint, target: octopus, startTime: 0,
            options: EffectOptions(intensity: intensity, color: RGBA(hex: color), hold: hold), sequence: 1)
        return EffectEvaluator.delta(of: effect, at: 0.4).tintAmount
    }

    @Test func tintKeepsItsLookUpToTheDefaultAndWashesWholeAtOne() {
        // As it always was up to the default intensity: half of it.
        for i in [0.0, 0.2, 0.4, 0.6] {
            #expect(abs(EffectDefinition.tintStrength(i) - 0.5 * i) < 1e-12)
        }
        // Then deepening, to the whole colour at 1.
        #expect(EffectDefinition.tintStrength(0.8) > 0.4)
        #expect(EffectDefinition.tintStrength(1) == 1)
        var last = 0.0
        for i in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(EffectDefinition.tintStrength(i) >= last)
            last = EffectDefinition.tintStrength(i)
        }
        #expect(abs(peak(1) - 1) < 1e-9)
        // Held at 1, it stays all that colour.
        let held = ActiveEffect(
            name: .tint, target: octopus, startTime: 0,
            options: EffectOptions(intensity: 1, color: RGBA(hex: "#9C948C"), hold: true), sequence: 1)
        #expect(abs(EffectEvaluator.delta(of: held, at: 20).tintAmount - 1) < 1e-9)
    }

    @Test func aWhiteTintStaysASoftFlash() {
        #expect(peak(1, color: "#FFFFFF") <= EffectDefinition.whiteTintCap + 1e-12)
        #expect(abs(peak(0.6, color: "#FFFFFF") - peak(0.6)) < 1e-12)
    }

    @Test func calmModeKeepsAColouredWashButDampsAFlash() {
        let calm = EffectPolicy(calmMode: true)
        #expect(calm.adjusted(.tint, EffectOptions(intensity: 1, color: RGBA(hex: "#9C948C")))?.intensity == 1)
        #expect(calm.adjusted(.tint, EffectOptions(intensity: 1, color: .white))?.intensity == 0.6)
        #expect(EffectPolicy(reduceMotion: true).adjusted(.tint, EffectOptions(intensity: 1, color: .white))?.intensity == 1)
    }

    @Test func bubblePuffIsAParticleFramesCanFire() {
        let name = try! #require(EffectName(rawValue: "bubble-puff"))
        #expect(name.category == .particle && name.firesFromFrames && !name.followsWorld && !name.readsColor)
        // Never the canvas `bubbles`: one namespace in a trigger file.
        #expect(CanvasEffectName(rawValue: name.rawValue) == nil)
        #expect(EffectName.allCases.allSatisfy { CanvasEffectName(rawValue: $0.rawValue) == nil })
        #expect(EffectName.allCases.filter(\.firesFromFrames) == [.dustPuff, .spray, .sparks, .bubblePuff])
        #expect(EffectPolicy(reduceMotion: true).adjusted(.bubblePuff, EffectOptions(intensity: 1))?.intensity == 0.4)
        // A trigger decodes as the sticker effect.
        let file = try! EffectTriggerFile(data: Data("""
            {"schema": 1, "triggers": [{"at": 1, "sticker": "fish", "effect": "bubble-puff"},
            {"at": 2, "effect": "bubbles"}]}
            """.utf8))
        #expect(file.triggers.map(\.effect) == [.bubblePuff] && file.canvasTriggers.map(\.effect) == [.bubbles])
    }
}
