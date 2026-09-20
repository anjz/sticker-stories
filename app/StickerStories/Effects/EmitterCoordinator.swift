import SpriteKit
import StickerStoriesKit

/// The one stateful piece of the sticker effects system: the SpriteKit
/// emitters behind `sparkle` and `hearts`. Reconciled every frame against
/// the runner's active effects — emitters are created for new particle
/// effects, ramped in/out, frozen while the clock is paused, dropped when
/// their effect is gone, and kept within the device budget.
@MainActor
final class EmitterCoordinator {
    /// Rendered sticker height at which `emitters.json` scales are 1:1.
    static let referenceHeight: CGFloat = 150
    static let rampIn: TimeInterval = 0.1
    static let rampOut: TimeInterval = 0.3

    private struct Budget {
        let maxEmitters: Int
        let maxParticles: Int
        static var current: Budget {
            let lowTier = ProcessInfo.processInfo.physicalMemory < 4 * 1024 * 1024 * 1024
            return lowTier ? Budget(maxEmitters: 4, maxParticles: 150) : Budget(maxEmitters: 6, maxParticles: 250)
        }
    }

    private struct Live {
        let node: SKEmitterNode
        let spec: EmitterSpec
        let effect: ActiveEffect
        let baseBirthRate: Double
        let anchor: EffectAnchor
        let inFront: Bool
        var dying = false
    }

    private var live: [EffectHandle: Live] = [:]
    private var dropped: Set<EffectHandle> = []
    private var lastTime: TimeInterval = -1
    private let budget = Budget.current

    func reconcile(_ active: [ActiveEffect], at time: TimeInterval, nodes: [UUID: StickerNode]) {
        let paused = time == lastTime
        lastTime = time

        let wanted = active.filter { $0.name.category == .particle }
        let wantedHandles = Set(wanted.map(\.handle))

        // Effects that ended or were seeked away: stop emitting, let live particles die.
        for (handle, entry) in live where !wantedHandles.contains(handle) && !entry.dying {
            retire(handle)
        }
        dropped = dropped.intersection(wantedHandles)

        // New particle effects, oldest first so the budget drops the newest.
        for effect in wanted.sorted(by: { $0.sequence < $1.sequence }) where live[effect.handle] == nil && !dropped.contains(effect.handle) {
            guard let node = nodes[effect.target] else { continue }
            let emitting = live.values.filter { !$0.dying }.count
            guard emitting < budget.maxEmitters else {
                dropped.insert(effect.handle)
                continue
            }
            start(effect, on: node, at: time)
        }

        // Per-frame: position, ramp, pause, particle budget.
        var totalExpected = 0.0
        for (handle, entry) in live {
            guard let node = nodes[entry.effect.target], let parent = node.parent else {
                retire(handle)
                continue
            }
            let pivot = EffectTransformMath.pivot(for: entry.anchor, width: node.size.width, height: node.size.height)
            entry.node.position = node.convert(CGPoint(x: pivot.x, y: pivot.y), to: parent)
            entry.node.zPosition = node.zPosition + (entry.inFront ? 0.5 : -0.5)
            entry.node.isPaused = paused
            if !entry.dying {
                let rate = entry.baseBirthRate * ramp(for: entry.effect, at: time)
                entry.node.particleBirthRate = rate
                totalExpected += rate * entry.spec.lifetime.value
            }
        }
        if totalExpected > Double(budget.maxParticles) {
            let factor = Double(budget.maxParticles) / totalExpected
            for entry in live.values where !entry.dying {
                entry.node.particleBirthRate *= factor
            }
        }

        // Remove emitters whose particles have all died.
        for (handle, entry) in live where entry.dying && entry.node.userData?["retiredAt"] != nil {
            let retiredAt = entry.node.userData?["retiredAt"] as? CFTimeInterval ?? 0
            if CACurrentMediaTime() - retiredAt > entry.spec.lifetime.value + entry.spec.lifetime.variance + 0.1 {
                entry.node.removeFromParent()
                live[handle] = nil
            }
        }
    }

    /// Stops everything immediately (playback cancelled — P4).
    func clearAll() {
        for entry in live.values { entry.node.removeFromParent() }
        live.removeAll()
        dropped.removeAll()
    }

    // MARK: -

    private func start(_ effect: ActiveEffect, on node: StickerNode, at time: TimeInterval) {
        guard let name = EmitterSpec.name(for: effect.name), let spec = EmitterSpec.bundled[name],
            let parent = node.parent
        else { return }

        let intensity = effect.options.intensity
        let renderedHeight = node.size.height * CGFloat(node.placement.scale)
        let sizeFactor = (renderedHeight / Self.referenceHeight).clamped(to: 0.4...2)
        // Seeking into the middle of an effect starts fresh at reduced
        // intensity rather than simulating what "should" exist.
        let seekedIn = time - effect.startTime > Self.rampIn + 0.05
        let intensityFactor = (0.3 + 0.7 * intensity) * (seekedIn ? 0.6 : 1)

        let emitter = SKEmitterNode()
        emitter.particleTexture = EffectTextures.texture(named: spec.texture)
        emitter.particleBlendMode = spec.blend == "add" ? .add : .alpha
        emitter.particleLifetime = CGFloat(spec.lifetime.value)
        emitter.particleLifetimeRange = CGFloat(spec.lifetime.variance * 2)
        emitter.particleSpeed = CGFloat(spec.speed.value) * sizeFactor
        emitter.particleSpeedRange = CGFloat(spec.speed.variance * 2) * sizeFactor
        emitter.emissionAngle = CGFloat(spec.emissionAngle.value) * .pi / 180
        emitter.emissionAngleRange = CGFloat(spec.emissionAngle.range) * .pi / 180
        emitter.xAcceleration = CGFloat(spec.gravity.first ?? 0) * sizeFactor
        emitter.yAcceleration = CGFloat(spec.gravity.last ?? 0) * sizeFactor
        emitter.particlePositionRange = CGVector(
            dx: node.size.width * CGFloat(node.placement.scale) * CGFloat(spec.positionSpread.first ?? 0),
            dy: renderedHeight * CGFloat(spec.positionSpread.last ?? 0))
        let particleScale = CGFloat(spec.scale.start) * sizeFactor * CGFloat(0.6 + 0.4 * intensity)
        emitter.particleScale = particleScale
        emitter.particleScaleRange = CGFloat(spec.scale.variance) * sizeFactor
        emitter.particleScaleSpeed = (CGFloat(spec.scale.end) * sizeFactor * CGFloat(0.6 + 0.4 * intensity) - particleScale) / CGFloat(spec.lifetime.value)
        emitter.particleRotationRange = .pi * 2
        emitter.particleRotationSpeed = CGFloat(spec.rotationSpeed)
        emitter.particleAlphaSequence = SKKeyframeSequence(
            keyframeValues: [spec.alpha.start, spec.alpha.peak, spec.alpha.end],
            times: [0, NSNumber(value: spec.alpha.peakAt), 1])
        let color = effect.name.readsColor ? (effect.options.color ?? spec.color) : spec.color
        emitter.particleColor = UIColor(color)
        emitter.particleColorBlendFactor = 1
        emitter.targetNode = parent  // particles live in scene space, not on the sticker
        emitter.particleBirthRate = 0  // ramped in by reconcile
        parent.addChild(emitter)

        live[effect.handle] = Live(
            node: emitter, spec: spec, effect: effect,
            baseBirthRate: spec.birthRate * intensityFactor,
            anchor: EffectDefinition.definition(for: effect.name).anchor,
            inFront: spec.inFront)
    }

    private func retire(_ handle: EffectHandle) {
        guard var entry = live[handle] else { return }
        entry.node.particleBirthRate = 0
        entry.node.isPaused = false
        entry.node.userData = ["retiredAt": CACurrentMediaTime()]
        entry.dying = true
        live[handle] = entry
    }

    /// Birth-rate envelope: in over 0.1s, out over the last 0.3s of a finite
    /// run (or after a stop), so emitters never pop on and off.
    private func ramp(for effect: ActiveEffect, at time: TimeInterval) -> Double {
        let local = time - effect.startTime
        var value = min(1, max(0, local / Self.rampIn))
        if let active = effect.activeDuration {
            let remaining = effect.startTime + active - time
            value = min(value, max(0, remaining / Self.rampOut))
        }
        if let stopTime = effect.stopTime, time >= stopTime {
            value = min(value, max(0, 1 - (time - stopTime) / Self.rampOut))
        }
        return value
    }
}

extension CGFloat {
    fileprivate func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
