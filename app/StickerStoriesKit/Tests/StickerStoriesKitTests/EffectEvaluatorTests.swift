import Foundation
import Testing

@testable import StickerStoriesKit

/// Pins the pure evaluator to the spec's acceptance criteria (§10).
struct EffectEvaluatorTests {
    private let target = UUID()

    private func effect(
        _ name: EffectName, start: TimeInterval = 0, options: EffectOptions = EffectOptions(), sequence: Int = 1
    ) -> ActiveEffect {
        var options = options
        if options.color == nil { options.color = EffectDefinition.definition(for: name).defaultColor ?? (name == .tint ? .white : nil) }
        return ActiveEffect(name: name, target: target, startTime: start, options: options, sequence: sequence)
    }

    private func samples(over duration: TimeInterval, count: Int = 97) -> [TimeInterval] {
        (0...count).map { duration * Double($0) / Double(count) }
    }

    // Criterion 1: after a full run every effect's delta is identity.
    @Test(arguments: EffectName.allCases)
    func everyEffectEndsAtIdentity(name: EffectName) {
        let e = effect(name)
        let end = e.startTime + e.activeDuration!
        // Held/one-way effects auto-stop through the runner; here the pure
        // evaluator must report identity once the effect is finished or, for
        // fade-in, at its natural end.
        if name.isOneWay {
            #expect(EffectEvaluator.rawDelta(of: e, at: end).isIdentity() == (name == .fadeIn))
        } else {
            #expect(EffectEvaluator.delta(of: e, at: end).isIdentity())
            #expect(EffectEvaluator.delta(of: e, at: end + 5).isIdentity())
            #expect(EffectEvaluator.isFinished(e, at: end))
        }
        // And every closed cycle starts at identity too (P2).
        if !name.isOneWay {
            #expect(EffectEvaluator.delta(of: e, at: 0).isIdentity(tolerance: 1e-9))
        }
    }

    // Criterion 2: repeat 3 runs for exactly 3 × duration.
    @Test func repeatThreeRunsThreeCycles() {
        let e = effect(.pulse, options: EffectOptions(repeatCount: .times(3)))
        #expect(e.activeDuration == 1.5)
        if case .running(let cycle, let phase) = EffectEvaluator.status(of: e, at: 0.6) {
            #expect(cycle == 1 && abs(phase - 0.2) < 1e-9)
        } else { Issue.record("expected running") }
        #expect(!EffectEvaluator.delta(of: e, at: 1.25).isIdentity())
        #expect(EffectEvaluator.delta(of: e, at: 1.5).isIdentity())
        #expect(EffectEvaluator.isFinished(e, at: 1.5))
        #expect(!EffectEvaluator.isFinished(e, at: 1.49))
    }

    // Criterion 3 (evaluator half): loop never finishes on its own.
    @Test func loopNeverFinishesByItself() {
        let e = effect(.float, options: EffectOptions(repeatCount: .loop))
        #expect(e.activeDuration == nil)
        #expect(!EffectEvaluator.isFinished(e, at: 1000))
        if case .running(let cycle, _) = EffectEvaluator.status(of: e, at: 10) { #expect(cycle == 3) } else { Issue.record("expected running") }
    }

    // Criterion 4: intensity 0 is indistinguishable from no effect.
    @Test(arguments: EffectName.allCases)
    func zeroIntensityIsIdentity(name: EffectName) {
        let e = effect(name, options: EffectOptions(repeatCount: .times(2), intensity: 0))
        for t in samples(over: e.activeDuration! + 0.5) {
            #expect(EffectEvaluator.rawDelta(of: e, at: t).isIdentity(tolerance: 0), "\(name) at \(t)")
        }
    }

    // Criterion 5: purity.
    @Test func sameTimelineSameTimeSameDeltas() {
        let effects = [effect(.wobble), effect(.pulse, start: 0.1, sequence: 2), effect(.glow, start: 0.2, sequence: 3)]
        for t in samples(over: 1.5) {
            #expect(EffectEvaluator.deltas(for: effects, at: t) == EffectEvaluator.deltas(for: effects, at: t))
        }
    }

    // Criterion 6 (evaluator half): the delta depends on t only.
    @Test func deltaIsAFunctionOfTimeOnly() {
        let e = effect(.hop)
        let forward = samples(over: 0.6).map { EffectEvaluator.delta(of: e, at: $0) }
        let backward = samples(over: 0.6).reversed().map { EffectEvaluator.delta(of: e, at: $0) }
        #expect(forward == Array(backward.reversed()))
    }

    // Criterion 7: composition rules.
    @Test func overlappingEffectsCompose() {
        let a = effect(.pulse, options: EffectOptions(intensity: 1), sequence: 1)  // scale
        let b = effect(.wobble, options: EffectOptions(intensity: 1), sequence: 2)  // rotation, bottom anchor
        let composed = EffectEvaluator.deltas(for: [a, b], at: 0.2)[target]!
        let da = EffectEvaluator.delta(of: a, at: 0.2)
        let db = EffectEvaluator.delta(of: b, at: 0.2)
        #expect(composed.scaleMul == da.scaleMul * db.scaleMul)
        #expect(composed.rotationAdd == da.rotationAdd + db.rotationAdd)
        #expect(composed.anchor == .bottomCenter)  // later-started wins

        let g1 = effect(.glow, options: EffectOptions(intensity: 1), sequence: 1)
        let g2 = effect(.glow, start: 0.3, options: EffectOptions(intensity: 0.5, color: RGBA(hex: "#FF0000")), sequence: 2)
        let glows = EffectEvaluator.deltas(for: [g1, g2], at: 0.5)[target]!
        #expect(glows.glow == max(EffectEvaluator.delta(of: g1, at: 0.5).glow, EffectEvaluator.delta(of: g2, at: 0.5).glow))
        #expect(glows.glowColor == RGBA(hex: "#FF0000"))

        // Both restore cleanly.
        #expect(EffectEvaluator.deltas(for: [a, b], at: 5).isEmpty || EffectEvaluator.deltas(for: [a, b], at: 5)[target]!.isIdentity())
    }

    // Criterion 10: fade-out with hold stays invisible.
    @Test func fadeOutWithHoldStaysInvisible() {
        let e = effect(.fadeOut, options: EffectOptions(intensity: 1, hold: true))
        #expect(EffectEvaluator.delta(of: e, at: 0.6).opacityMul == 0)
        #expect(EffectEvaluator.delta(of: e, at: 60).opacityMul == 0)
        #expect(!EffectEvaluator.isFinished(e, at: 60))
        #expect(EffectEvaluator.status(of: e, at: 60) == .holding)
    }

    @Test func glowWithHoldRisesThenStaysAtPeak() {
        let e = effect(.glow, options: EffectOptions(intensity: 1, hold: true))
        let peak = 0.8
        #expect(EffectEvaluator.delta(of: e, at: 0).glow == 0)
        #expect(abs(EffectEvaluator.delta(of: e, at: 1.0).glow - peak) < 1e-9)
        #expect(abs(EffectEvaluator.delta(of: e, at: 30).glow - peak) < 1e-9)
    }

    // Stop eases back over min(0.25, remaining cycle time).
    @Test func stopEasesBackToIdentity() {
        var e = effect(.float, options: EffectOptions(repeatCount: .loop, intensity: 1))
        e.stopTime = 0.75  // a quarter into a 3s cycle; remaining 2.25 > 0.25
        let atStop = EffectEvaluator.delta(of: e, at: 0.75)
        #expect(abs(atStop.offsetYSelf - -0.06) < 1e-9)
        let mid = EffectEvaluator.delta(of: e, at: 0.875)
        #expect(abs(mid.offsetYSelf) < abs(atStop.offsetYSelf))
        #expect(EffectEvaluator.delta(of: e, at: 1.0).isIdentity())
        #expect(EffectEvaluator.isFinished(e, at: 1.0))
        #expect(!EffectEvaluator.isFinished(e, at: 0.99))

        var short = effect(.pulse)  // 0.5s cycle
        short.stopTime = 0.4  // remaining 0.1 < 0.25
        #expect(abs(EffectEvaluator.easeBackDuration(of: short, stoppingAt: 0.4) - 0.1) < 1e-9)
        #expect(EffectEvaluator.isFinished(short, at: 0.5))
    }

    @Test func pendingEffectsContributeNothing() {
        let e = effect(.spin, start: 2)
        #expect(EffectEvaluator.status(of: e, at: 1) == .pending)
        #expect(EffectEvaluator.delta(of: e, at: 1).isIdentity())
    }

    // Blink is hard-edged: only 1 or 1−i, and back to 1 at the cycle end.
    @Test func blinkIsHardEdged() {
        let e = effect(.blink, options: EffectOptions(intensity: 1))
        let values = Set(samples(over: 0.3, count: 60).map { EffectEvaluator.delta(of: e, at: $0).opacityMul })
        #expect(values == [0, 1])
        #expect(EffectEvaluator.delta(of: e, at: 0.3).opacityMul == 1)
    }

    @Test func shakeUsesTimeBasedTremblePeriod() {
        let slow = effect(.shake, options: EffectOptions(duration: 1.0, intensity: 1))
        let fast = effect(.shake, options: EffectOptions(duration: 0.5, intensity: 1))
        // Count sign changes: doubling the duration roughly doubles the trembles.
        func crossings(_ e: ActiveEffect) -> Int {
            let d = e.cycleDuration
            let xs = samples(over: d, count: 400).map { EffectEvaluator.delta(of: e, at: $0).offsetXSelf }
            return zip(xs, xs.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        }
        #expect(crossings(slow) > crossings(fast) * 3 / 2)
    }

    @Test func optionsAreClamped() {
        let o = EffectOptions(repeatCount: .times(500), duration: 99, intensity: 4).clamped
        #expect(o.repeatCount == .times(50))
        #expect(o.duration == 30)
        #expect(o.intensity == 1)
    }

    @Test func deltaComposition() {
        var a = EffectDelta()
        a.opacityMul = 0.5
        a.scaleMul = 2
        a.rotationAdd = 10
        a.glow = 0.3
        a.tintColor = .white
        var b = EffectDelta()
        b.opacityMul = 0.5
        b.scaleMul = 1.5
        b.rotationAdd = -4
        b.glow = 0.1
        b.anchor = .bottomCenter
        let c = a.combined(with: b)
        #expect(c.opacityMul == 0.25)
        #expect(c.scaleMul == 3)
        #expect(c.rotationAdd == 6)
        #expect(c.glow == 0.3)
        #expect(c.tintColor == .white)
        #expect(c.anchor == .bottomCenter)
        #expect(a.blendedTowardIdentity(1).isIdentity())
        #expect(a.blendedTowardIdentity(0) == a)
    }
}
