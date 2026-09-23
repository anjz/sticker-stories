import Foundation
import Testing

@testable import StickerStoriesKit

struct CanvasEffectsRunnerTests {
    private func runner(
        _ triggers: [CanvasEffectTrigger] = [], setting: PackSetting = .outdoors,
        policy: EffectPolicy = .standard, log: @escaping (String) -> Void = { _ in }
    ) -> CanvasEffectsRunner {
        CanvasEffectsRunner(triggers: triggers, setting: setting, policy: policy, log: log)
    }

    // The envelope: 0 → 1 over the ramp-in, flat, → 0 over the ramp-out, then retired.
    @Test func envelopeRampsInHoldsAndRampsOut() {
        let e = ActiveCanvasEffect(name: .rain, startTime: 2, options: CanvasEffectOptions(intensity: 1, duration: 10), sequence: 1)
        #expect(e.rampIn == 1.2 && e.rampOut == 1.5)
        #expect(CanvasEffectEvaluator.level(of: e, at: 1.9) == 0)
        #expect(CanvasEffectEvaluator.level(of: e, at: 2) == 0)
        let rising = CanvasEffectEvaluator.level(of: e, at: 2.6)
        #expect(rising > 0 && rising < 1)
        #expect(CanvasEffectEvaluator.level(of: e, at: 3.2) == 1)
        #expect(CanvasEffectEvaluator.level(of: e, at: 8) == 1)
        let falling = CanvasEffectEvaluator.level(of: e, at: 11.3)
        #expect(falling > 0 && falling < 1)
        #expect(CanvasEffectEvaluator.level(of: e, at: 12) == 0)
        #expect(CanvasEffectEvaluator.isFinished(e, at: 12))
        #expect(!CanvasEffectEvaluator.isFinished(e, at: 11.99))
        // Strength scales with intensity, never with time.
        let half = ActiveCanvasEffect(name: .rain, startTime: 2, options: CanvasEffectOptions(intensity: 0.5, duration: 10), sequence: 2)
        #expect(abs(CanvasEffectEvaluator.strength(of: half, at: 5) - 0.5) < 1e-9)
    }

    // A short effect still spends a third of its time at full strength.
    @Test func rampsAreCappedForShortDurations() {
        let e = ActiveCanvasEffect(name: .fog, startTime: 0, options: CanvasEffectOptions(duration: 3), sequence: 1)
        #expect(e.rampIn == 1 && e.rampOut == 1)
        #expect(CanvasEffectEvaluator.level(of: e, at: 1.5) == 1)
    }

    @Test func intensityZeroIsNothingAndOptionsAreClamped() {
        let o = CanvasEffectOptions(intensity: 4, duration: 999).clamped
        #expect(o.intensity == 1 && o.duration == 120)
        #expect(CanvasEffectOptions(intensity: -1, duration: 0.2).clamped == CanvasEffectOptions(intensity: 0, duration: 1))
        let e = ActiveCanvasEffect(name: .sunshine, startTime: 0, options: CanvasEffectOptions(intensity: 0), sequence: 1)
        #expect(CanvasEffectEvaluator.strengths(for: [e], at: 3).isEmpty)
    }

    @Test func overlappingEffectsOfOneKindTakeTheMax() {
        let heavy = ActiveCanvasEffect(name: .rain, startTime: 0, options: CanvasEffectOptions(intensity: 0.9, duration: 10), sequence: 1)
        let light = ActiveCanvasEffect(name: .rain, startTime: 0, options: CanvasEffectOptions(intensity: 0.3, duration: 10), sequence: 2)
        let fog = ActiveCanvasEffect(name: .fog, startTime: 0, options: CanvasEffectOptions(intensity: 0.5, duration: 10), sequence: 3)
        let s = CanvasEffectEvaluator.strengths(for: [heavy, light, fog], at: 5)
        #expect(abs(s[.rain]! - 0.9) < 1e-9)
        #expect(abs(s[.fog]! - 0.5) < 1e-9)
        #expect(s.count == 2)
    }

    @Test func triggersFireAtTheirTimeAndRetire() {
        let r = runner([
            CanvasEffectTrigger(at: 1, cue: "rain", effect: .rain, options: CanvasEffectOptions(intensity: 1, duration: 4)),
            CanvasEffectTrigger(at: 20, effect: .rainbow),
        ])
        #expect(r.tick(0.5).isEmpty && r.active.isEmpty)
        #expect(r.tick(2.5)[.rain] == 1)
        #expect(r.active.first?.startTime == 1)  // starts at the trigger's time, not the tick's
        r.tick(5)
        #expect(r.active.isEmpty)
        #expect(r.tick(21).keys.contains(.rainbow))
    }

    // Seeking backwards rebuilds the same state as playing forward.
    @Test func seekingBackwardsMatchesPlayingForward() {
        let triggers = [
            CanvasEffectTrigger(at: 0, effect: .fog, options: CanvasEffectOptions(duration: 30)),
            CanvasEffectTrigger(at: 2, effect: .rain, options: CanvasEffectOptions(intensity: 0.7)),
        ]
        let a = runner(triggers)
        var forward: [CanvasEffectName: Double] = [:]
        for step in 0...400 { forward = a.tick(Double(step) * 0.01) }  // → 4.0
        let b = runner(triggers)
        b.tick(15)
        #expect(b.active.count == 1)  // rain (default 10 s) has ended by 15 s
        let seeked = b.tick(4.0)
        #expect(forward == seeked)
        #expect(Set(a.active.map(\.name)) == Set(b.active.map(\.name)))
    }

    @Test func triggersThatDoNotSuitTheSettingAreDroppedWithALog() {
        var logs: [String] = []
        let indoors = runner(
            [CanvasEffectTrigger(at: 0, effect: .rain), CanvasEffectTrigger(at: 0, effect: .dimlight)],
            setting: .indoors, log: { logs.append($0) })
        #expect(Array(indoors.tick(1).keys) == [.dimlight])
        #expect(logs.count == 1 && logs[0].contains("rain"))

        let none = runner([CanvasEffectTrigger(at: 0, effect: .fog)], setting: .none)
        #expect(none.tick(1).isEmpty)

        // Explicit play (the gallery) ignores the setting.
        #expect(!none.play(.fog).id.uuidString.isEmpty)
        #expect(none.tick(2).keys.contains(.fog))
    }

    @Test func stopEasesOutThenRetiresAndStopAllSnaps() {
        let r = runner()
        let handle = r.play(.fog, options: CanvasEffectOptions(intensity: 1, duration: 30))
        r.tick(5)
        r.stop(handle)
        let easing = r.tick(6)[.fog]!
        #expect(easing > 0 && easing < 1)
        r.tick(7.5)  // fog's ramp-out is 2.5 s
        #expect(r.active.isEmpty)

        r.play(.dimlight)
        r.tick(8)
        r.stopAll()
        #expect(r.active.isEmpty && r.tick(8.1).isEmpty)
    }

    @Test func policyDampsRainAndCalmModeDampsEverything() {
        let reduce = EffectPolicy(reduceMotion: true)
        #expect(reduce.adjusted(.rain, CanvasEffectOptions(intensity: 1))?.intensity == 0.4)
        #expect(reduce.adjusted(.fog, CanvasEffectOptions(intensity: 1))?.intensity == 1)
        let calm = EffectPolicy(calmMode: true, calmIntensityMultiplier: 0.5)
        #expect(calm.adjusted(.sunshine, CanvasEffectOptions(intensity: 0.8))?.intensity == 0.4)
        let r = runner(policy: reduce)
        r.play(.rain, options: CanvasEffectOptions(intensity: 1))
        #expect(r.active.first?.options.intensity == 0.4)
    }

    @Test func anEffectForSeveralSettingsRunsInEachOfThem() {
        let trigger = CanvasEffectTrigger(at: 0, effect: .confetti)
        for setting in [PackSetting.outdoors, .indoors, .space] {
            let r = runner([trigger], setting: setting)
            #expect(!r.tick(1).isEmpty, Comment(rawValue: setting.rawValue))
        }
        #expect(runner([trigger], setting: .none).tick(1).isEmpty)
    }

    @Test func everyCanvasEffectSuitsSomeSettingButNone() {
        for name in CanvasEffectName.allCases {
            #expect(!name.settings.isEmpty, Comment(rawValue: name.rawValue))
            #expect(!name.suits(.none), Comment(rawValue: name.rawValue))
        }
    }
}
