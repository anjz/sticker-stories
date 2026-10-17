import Foundation
import Testing

@testable import StickerStoriesKit

/// `surf-wave`: a wave painted behind a sticker in the water, a pure
/// function of the timeline (`SurfWave`).
struct SurfWaveTests {
    private let surfer = UUID()

    private func effect(
        start: TimeInterval = 1, options: EffectOptions = EffectOptions(), stop: TimeInterval? = nil
    ) -> ActiveEffect {
        ActiveEffect(name: .surfWave, target: surfer, startTime: start, options: options, sequence: 1, stopTime: stop)
    }

    private func shape(_ phase: Double, intensity: Double = 0.6, aspect: Double = 0.5) -> SurfWave.Shape {
        SurfWave.shape(SurfWave.frame(phase: phase, intensity: intensity, cycleDuration: 4), aspect: aspect)
    }

    private let phases = stride(from: 0.0, through: 1.0, by: 0.01).map { $0 }

    @Test func isAWaterEffectThatMovesNothing() {
        let name = try! #require(EffectName(rawValue: "surf-wave"))
        #expect(name == .surfWave && name.category == .water)
        let definition = EffectDefinition.definition(for: .surfWave)
        #expect(definition.defaultDuration == 4)
        #expect(definition.anchor == .bottomCenter)
        #expect(!name.readsColor && !name.supportsHold && !name.isOneWay && !name.followsWorld)
        // The sticker itself never moves: the wave is painted behind it.
        for phase in phases {
            var identity = EffectDelta.identity
            identity.anchor = .bottomCenter
            #expect(definition.delta(atPhase: phase, intensity: 1, cycleDuration: 4) == identity)
        }
    }

    @Test func eachCycleRisesFromNothingAndBreaksAway() {
        for intensity in [0.3, 0.6, 1.0] {
            #expect(shape(0, intensity: intensity) == .none)
            #expect(shape(1, intensity: intensity) == .none)
            #expect(shape(0.5, intensity: intensity).opacity == 1)
            #expect(!shape(0.5, intensity: intensity).body.isEmpty)
        }
        // It grows, then pitches and crashes, then collapses into foam.
        let heights = [0.1, 0.25, 0.4, 0.8, 0.95].map { shape($0).height }
        #expect(heights[0] < heights[1] && heights[1] < heights[2])
        #expect(heights[2] > heights[3] && heights[3] > heights[4])
        #expect(shape(0.3).spray.isEmpty && !shape(0.7).spray.isEmpty)
    }

    @Test func intensityZeroDrawsNothing() {
        for phase in phases {
            #expect(shape(phase, intensity: 0) == .none)
        }
        #expect(SurfWave.frame(of: effect(options: EffectOptions(intensity: 0)), at: 3) == nil)
    }

    @Test func intensityScalesTheWaveNotItsPace() {
        let small = shape(0.4, intensity: 0.3), big = shape(0.4, intensity: 1)
        #expect(small.height < big.height)
        // The same stage of the cycle at any intensity: both are rising.
        #expect(shape(0.2, intensity: 0.3).height < small.height && shape(0.2, intensity: 1).height < big.height)
    }

    @Test func isInProportionToTheDrawing() {
        // Units are the drawing's height: the crest at most a little over it.
        for phase in phases {
            #expect(shape(phase, intensity: 1).height <= 1.0)
        }
        #expect(shape(0.4, intensity: 0.6).height > 0.5)
        // A long, low sticker (the seal) gets a taller wave than its height alone.
        #expect(shape(0.4, aspect: 1.6).height > shape(0.4, aspect: 0.5).height)
    }

    @Test func staysBehindTheStickerAndNeverCoversIt() {
        // The water and its foam are drawn behind the sticker (the app's
        // z-order); its crest rises behind the sticker's back and, above
        // its base, the water never shows past its front. Only the low
        // foam line is in front, at its feet.
        for aspect in [0.45, 0.9, 1.6] {
            let back = -0.5 * aspect, front = 0.5 * aspect
            for phase in phases {
                let s = shape(phase, intensity: 1, aspect: aspect)
                if let crest = s.body.max(by: { $0.y < $1.y }) {
                    #expect(crest.x < back, "phase \(phase) aspect \(aspect): crest \(crest)")
                }
                for point in s.body where point.y > 0.1 {
                    #expect(point.x < front, "phase \(phase) aspect \(aspect): \(point)")
                }
                for blob in s.frontFoam {
                    #expect(blob.y + blob.radius < 0.06, "phase \(phase): \(blob)")
                    #expect(blob.x - blob.radius * blob.stretch < front + 0.2)
                }
            }
        }
    }

    @Test func risesOnlyInTheWater() {
        let w = testWorld()
        let pond = w.groundPoint(.init(0.55, 0.25)).onGround, meadow = w.groundPoint(.init(0.55, 0.12)).onGround
        #expect(SurfWave.rises(at: pond, in: w))
        #expect(!SurfWave.rises(at: meadow, in: w))
        // Above the water (a bird flying over the pond) is not in it.
        #expect(!SurfWave.rises(at: pond + Vec3(0, 0.2, 0), in: w))
    }

    @Test func readsAsAPitchingWaveNotAFin() {
        // At its fullest: a body much wider than it is tall, and a lip that
        // pitches forward over the face under it, in a short hook.
        let s = shape(0.5)
        let xs = s.body.map(\.x)
        #expect(xs.max()! - xs.min()! > 2.5 * s.height)
        let lip = s.body.filter { $0.y > 0.6 * s.height }.map(\.x).max()!
        let crestIndex = s.body.firstIndex { $0.y == s.body.map(\.y).max()! }!
        let face = s.body[crestIndex...].filter { $0.y > 0.15 * s.height && $0.y < 0.4 * s.height }.map(\.x).min()!
        #expect(lip > face)
        // A hook, not a spiral: the lip's tip is still ahead of the crest
        // and above the water, never wound back under it.
        let tip = try! #require(s.lipTip)
        #expect(tip.x > xs[crestIndex] && tip.y > 0.2 * s.height)
        // Shaded softly under the lip, a white puffy lip, a faint highlight.
        #expect(!s.shade.isEmpty && !s.glow.isEmpty && s.foam.count > 20 && !s.streaks.isEmpty)
    }

    @Test func breaksForwardAndNeverPlaysBackwards() {
        // The lip only ever goes forward and, once grown, only ever down:
        // it crashes, it never uncurls.
        var last: SurfWave.Point?
        for phase in stride(from: 0.4, through: 0.88, by: 0.01) {
            let tip = try! #require(shape(phase, intensity: 1).lipTip)
            if let last {
                #expect(tip.x >= last.x - 1e-9, "phase \(phase)")
                #expect(tip.y <= last.y + 1e-9, "phase \(phase)")
            }
            last = tip
        }
        // It bursts into foam and spray as it crashes, then whitewater
        // takes over from the water and fizzles out.
        let before = shape(0.55), burst = shape(0.64), whitewater = shape(0.85)
        #expect(burst.foam.count > before.foam.count + 15 && !burst.spray.isEmpty)
        #expect(whitewater.bodyOpacity < 0.3 && whitewater.foam.count > 20)
        #expect(shape(0.97).foam.allSatisfy { $0.alpha < 0.3 })
    }

    @Test func isAPureFunctionOfTheTimeline() {
        let wave = effect(start: 2, options: EffectOptions(repeatCount: .times(2)))
        // Seconds into the cycle, the same every time it is asked: a seek
        // or a replay shows the same wave, foam and spray.
        for t in stride(from: 2.0, to: 10.0, by: 0.37) {
            let a = SurfWave.frame(of: wave, at: t), b = SurfWave.frame(of: wave, at: t)
            #expect(a == b)
            if let a { #expect(SurfWave.shape(a, aspect: 0.5) == SurfWave.shape(a, aspect: 0.5)) }
        }
        // The second cycle is the first again.
        #expect(SurfWave.frame(of: wave, at: 3.3) == SurfWave.frame(of: wave, at: 7.3))
        #expect(SurfWave.frame(of: wave, at: 1.9) == nil)
        #expect(SurfWave.frame(of: wave, at: 10.1) == nil)

        // Through the runner, a seek back shows what playing forward did.
        let trigger = EffectTrigger(at: 1, stickerID: "surfer", effect: .surfWave)
        let runner = StickerEffectsRunner(triggers: [trigger], targets: ["surfer": [surfer]])
        runner.tick(3.4)
        let forward = runner.active.compactMap { SurfWave.frame(of: $0, at: 3.4) }
        runner.tick(4.6)
        runner.tick(0.5)
        runner.tick(3.4)
        let seeked = runner.active.compactMap { SurfWave.frame(of: $0, at: 3.4) }
        #expect(!forward.isEmpty && forward == seeked)
    }

    @Test func durationSetsThePace() {
        let slow = effect(start: 0, options: EffectOptions(duration: 8))
        #expect(SurfWave.frame(of: slow, at: 4)?.phase == 0.5)
        #expect(SurfWave.frame(of: effect(start: 0), at: 2)?.phase == 0.5)
    }

    @Test func stoppingEarlyFadesItAway() {
        let stopped = effect(start: 0, stop: 2)
        let at = [2.0, 2.1, 2.2].compactMap { SurfWave.frame(of: stopped, at: $0)?.opacity }
        #expect(at.count == 3 && at[0] > at[1] && at[1] > at[2])
        #expect(SurfWave.frame(of: stopped, at: 2 + EffectEvaluator.easeBackDuration + 0.01) == nil)
    }

    @Test func reduceMotionAndCalmModeKeepItSmall() {
        let options = EffectOptions(intensity: 1)
        #expect(EffectPolicy(reduceMotion: true).adjusted(.surfWave, options)?.intensity == 0.4)
        #expect(EffectPolicy(calmMode: true).adjusted(.surfWave, options)?.intensity == 0.4 * 0.6)
    }
}
