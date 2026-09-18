import Foundation
import Testing

@testable import StickerStoriesKit

struct EffectRunnerTests {
    private let fox = UUID()
    private let fox2 = UUID()
    private let tree = UUID()

    private var targets: [String: [UUID]] { ["fox": [fox, fox2], "tree": [tree]] }

    private func runner(_ triggers: [EffectTrigger] = [], policy: EffectPolicy = .standard, log: @escaping (String) -> Void = { _ in }) -> StickerEffectsRunner {
        StickerEffectsRunner(triggers: triggers, targets: targets, policy: policy, log: log)
    }

    @Test func playThenTickProducesDeltasAndRetires() {
        let r = runner()
        r.tick(1.0)
        r.play(.pulse, on: fox)
        let mid = r.tick(1.25)
        #expect(mid[fox] != nil && !mid[fox]!.isIdentity())
        #expect(r.affectedTargets == [fox])
        r.tick(1.5)
        #expect(r.active.isEmpty)
        #expect(r.tick(1.6).isEmpty)
    }

    // Criterion 3: loop restores on stopAll.
    @Test func loopRestoresOnStopAll() {
        let r = runner()
        r.play(.sway, on: tree, options: EffectOptions(repeatCount: .loop))
        #expect(!r.tick(100)[tree]!.isIdentity())
        r.stopAll()
        #expect(r.active.isEmpty)
        #expect(r.tick(100.1).isEmpty)
    }

    @Test func stopEasesThenRetires() {
        let r = runner()
        r.play(.float, on: tree, options: EffectOptions(repeatCount: .loop, intensity: 1))
        r.tick(0.75)
        r.stopAll(on: tree)
        #expect(!r.tick(0.8)[tree]!.isIdentity())
        r.tick(1.0)
        #expect(r.active.isEmpty)
    }

    // Criterion 6: seeking backwards rebuilds the same state as playing forward.
    @Test func seekingBackwardsMatchesPlayingForward() {
        let triggers = [
            EffectTrigger(at: 0, stickerID: "tree", effect: .sway, options: EffectOptions(repeatCount: .loop)),
            EffectTrigger(at: 1.0, stickerID: "fox", effect: .hop),
            EffectTrigger(at: 2.0, stickerID: "fox", effect: .glow, options: EffectOptions(hold: true)),
        ]
        let a = runner(triggers)
        var forward: [UUID: EffectDelta] = [:]
        for step in 0...130 { forward = a.tick(Double(step) * 0.01) }  // → 1.30
        let b = runner(triggers)
        b.tick(2.5)
        let seeked = b.tick(1.30)
        #expect(forward == seeked)
        #expect(Set(a.active.map(\.name)) == Set(b.active.map(\.name)))
    }

    // Criterion 12: absent stickers are silently skipped.
    @Test func triggersForAbsentStickersAreSkippedSilently() {
        var logs: [String] = []
        let r = runner([EffectTrigger(at: 0, stickerID: "dragon", effect: .wobble)], log: { logs.append($0) })
        #expect(r.tick(1).isEmpty)
        #expect(r.active.isEmpty)
        #expect(logs.isEmpty)
    }

    @Test func triggerExpandsToEveryInstanceAndStartsAtItsOwnTime() {
        let r = runner([EffectTrigger(at: 0.5, stickerID: "fox", effect: .spin)])
        let deltas = r.tick(0.7)  // first tick lands after the trigger
        #expect(Set(deltas.keys) == [fox, fox2])
        #expect(r.active.allSatisfy { $0.startTime == 0.5 })
    }

    // Criterion 9: tint without a colour logs and does not crash.
    @Test func tintWithoutColorIsSkippedWithALog() {
        var logs: [String] = []
        let r = runner(log: { logs.append($0) })
        r.play(.tint, on: fox)
        #expect(r.active.isEmpty)
        #expect(logs.count == 1)
        r.play(.tint, on: fox, options: EffectOptions(color: RGBA(hex: "#FF0000")))
        #expect(r.active.count == 1)
    }

    @Test func glowGetsItsDefaultColor() {
        let r = runner()
        r.play(.glow, on: fox)
        #expect(r.active.first?.options.color == RGBA(hex: "#FFF3C4"))
        #expect(r.tick(0.5)[fox]?.glowColor == RGBA(hex: "#FFF3C4"))
    }

    // Criterion 10 (runner half): a non-held fade-out eases back in at its end.
    @Test func fadeOutWithoutHoldReturnsToBase() {
        let r = runner()
        r.play(.fadeOut, on: fox, options: EffectOptions(intensity: 1))
        #expect(r.tick(0.6)[fox]!.opacityMul == 0)
        #expect(r.tick(0.7)[fox]!.opacityMul > 0.3)
        r.tick(0.85)
        #expect(r.active.isEmpty)

        let held = runner()
        held.play(.fadeOut, on: fox, options: EffectOptions(intensity: 1, hold: true))
        #expect(held.tick(30)[fox]!.opacityMul == 0)
        held.stopAll()
        #expect(held.tick(30.1).isEmpty)
    }

    @Test func repeatIsIgnoredForOneWayEffects() {
        var logs: [String] = []
        let r = runner(log: { logs.append($0) })
        r.play(.fadeIn, on: fox, options: EffectOptions(repeatCount: .times(3)))
        #expect(r.active.first?.activeDuration == 0.6)
        #expect(logs.count == 1)
    }

    // Criterion 13: a fresh runner carries nothing over.
    @Test func freshRunnerHasNoStateFromPreviousRun() {
        let triggers = [EffectTrigger(at: 0, stickerID: "fox", effect: .wobble)]
        let first = runner(triggers)
        first.tick(0.3)
        first.stopAll()
        let second = runner(triggers)
        #expect(second.active.isEmpty && second.currentTime == 0)
        #expect(second.tick(0.3) == runner(triggers).tick(0.3))
    }

    @Test func flashesAreCappedAtThreePerSecond() {
        var logs: [String] = []
        let r = runner(log: { logs.append($0) })
        for _ in 0..<5 { r.play(.blink, on: fox) }
        #expect(r.active.count == 3)
        r.play(.tint, on: fox, options: EffectOptions(color: .white))  // a white flash counts too
        #expect(r.active.count == 3)
        r.play(.tint, on: fox, options: EffectOptions(color: RGBA(hex: "#FF0000")))  // a red wash does not
        #expect(r.active.count == 4)
        #expect(logs.count == 3)
        r.tick(1.5)
        r.play(.blink, on: fox)
        #expect(r.active.contains { $0.name == .blink && $0.startTime == 1.5 })
    }

    @Test func policyDropsAndDampsUnderReduceMotion() {
        let calm = EffectPolicy(reduceMotion: true)
        #expect(calm.adjusted(.shake, EffectOptions()) == nil)
        #expect(calm.adjusted(.blink, EffectOptions()) == nil)
        #expect(calm.adjusted(.pulse, EffectOptions(intensity: 0.9))?.intensity == 0.3)
        #expect(calm.adjusted(.pulse, EffectOptions(intensity: 0.2))?.intensity == 0.2)
        #expect(calm.adjusted(.fadeOut, EffectOptions(intensity: 0.9))?.intensity == 0.9)
        #expect(calm.adjusted(.sparkle, EffectOptions(intensity: 0.9))?.intensity == 0.4)
        #expect(EffectPolicy.standard.adjusted(.shake, EffectOptions()) != nil)

        let calmMode = EffectPolicy(calmMode: true, calmIntensityMultiplier: 0.5)
        #expect(calmMode.adjusted(.glow, EffectOptions(intensity: 0.8))?.intensity == 0.4)

        let r = runner(policy: calm)
        r.play(.spin, on: fox)
        #expect(r.active.isEmpty)
    }
}
