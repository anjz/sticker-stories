import SpriteKit
import StickerStoriesKit

/// The one stateful piece of the sticker effects system: the SpriteKit
/// emitters behind the particle effects (`sparkle`, `hearts`, `dust-puff`,
/// `spray`, `sparks`). Reconciled every frame against
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

    /// The pack's world: the physical particles fall under its gravity, and
    /// dust is the colour of its ground.
    var world = PackWorld.defaults(for: .none)

    private var live: [EffectHandle: Live] = [:]
    /// Bursts fired by animation frames, until their particles are gone.
    private var bursts: [SKEmitterNode] = []
    private var dropped: Set<EffectHandle> = []
    private var lastTime: TimeInterval = -1
    private let budget = Budget.current

    func reconcile(_ active: [ActiveEffect], at time: TimeInterval, nodes: [UUID: StickerNode]) {
        let paused = time == lastTime
        lastTime = time
        for burst in bursts { burst.isPaused = paused }

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
            entry.node.position = node.convert(Self.point(entry.anchor, on: node), to: parent)
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
        for burst in bursts { burst.removeFromParent() }
        bursts.removeAll()
        live.removeAll()
        dropped.removeAll()
    }

    // MARK: -

    private func start(_ effect: ActiveEffect, on node: StickerNode, at time: TimeInterval) {
        guard let name = EmitterSpec.name(for: effect.name), let spec = EmitterSpec.bundled[name],
            let parent = node.parent
        else { return }
        // Seeking into the middle of an effect starts fresh at reduced
        // intensity rather than simulating what "should" exist.
        let seekedIn = time - effect.startTime > Self.rampIn + 0.05
        let emitter = makeEmitter(effect.name, spec: spec, options: effect.options, on: node)
        emitter.particleBirthRate = 0  // ramped in by reconcile
        parent.addChild(emitter)

        live[effect.handle] = Live(
            node: emitter, spec: spec, effect: effect,
            baseBirthRate: spec.birthRate * Self.intensityFactor(effect.options.intensity, damped: seekedIn),
            anchor: EffectDefinition.definition(for: effect.name).anchor,
            inFront: spec.inFront)
    }

    /// One short burst of a particle effect from a point of a sticker (in
    /// its own space) — fired by an animation's frame, not by a story cue:
    /// it emits for the effect's default duration where the sticker is now
    /// and its particles live out their lives in the scene. Within the
    /// emitter budget; nothing under calm mode's limits is lost, only damped.
    func burst(_ name: EffectName, options: EffectOptions, on node: StickerNode, at point: CGPoint) {
        guard let emitterName = EmitterSpec.name(for: name), let spec = EmitterSpec.bundled[emitterName],
            let parent = node.parent
        else { return }
        bursts.removeAll { $0.parent == nil }
        guard bursts.count + live.values.filter({ !$0.dying }).count < budget.maxEmitters else { return }
        let emitter = makeEmitter(name, spec: spec, options: options, on: node)
        emitter.position = node.convert(point, to: parent)
        emitter.zPosition = node.zPosition + (spec.inFront ? 0.5 : -0.5)
        emitter.particleBirthRate = CGFloat(spec.birthRate * Self.intensityFactor(options.intensity, damped: false))
        parent.addChild(emitter)
        bursts.append(emitter)
        let duration = options.duration ?? EffectDefinition.definition(for: name).defaultDuration
        let fade = Double(emitter.particleLifetime + emitter.particleLifetimeRange / 2) + 0.1
        emitter.run(.sequence([
            .wait(forDuration: duration),
            .run { [weak emitter] in emitter?.particleBirthRate = 0 },
            .wait(forDuration: fade),
            .removeFromParent(),
        ]))
    }

    /// How much of an emitter's birth rate an intensity gives.
    private static func intensityFactor(_ intensity: Double, damped: Bool) -> Double {
        (0.3 + 0.7 * intensity) * (damped ? 0.6 : 1)
    }

    /// An emitter for a particle effect on a sticker, sized on its drawing,
    /// in the pack's world, not yet emitting or placed.
    private func makeEmitter(_ name: EffectName, spec: EmitterSpec, options: EffectOptions, on node: StickerNode) -> SKEmitterNode {
        let intensity = options.intensity
        // Sized on the drawing, not its image's box (a sticker drawn at its size).
        let renderedHeight = node.size.height * node.content.height * CGFloat(node.placement.scale)
        let renderedWidth = node.size.width * node.content.width * CGFloat(node.placement.scale)
        // The physical particles fall under the world's gravity and hang
        // longer where it is weak (the Moon: a sixth, about 2.4× as long).
        let gravity = spec.worldGravity == true ? CGFloat(max(world.gravity, 0.02)) : 1
        let hang = spec.worldGravity == true ? min(2.5, 1 / sqrt(gravity)) : 1
        let sizeFactor = (renderedHeight / Self.referenceHeight).clamped(to: 0.4...2)

        let emitter = SKEmitterNode()
        emitter.particleTexture = EffectTextures.texture(named: spec.texture)
        emitter.particleBlendMode = spec.blend == "add" ? .add : .alpha
        emitter.particleLifetime = CGFloat(spec.lifetime.value) * hang
        emitter.particleLifetimeRange = CGFloat(spec.lifetime.variance * 2) * hang
        emitter.particleSpeed = CGFloat(spec.speed.value) * sizeFactor
        emitter.particleSpeedRange = CGFloat(spec.speed.variance * 2) * sizeFactor
        emitter.emissionAngle = CGFloat(spec.emissionAngle.value) * .pi / 180
        emitter.emissionAngleRange = CGFloat(spec.emissionAngle.range) * .pi / 180
        emitter.xAcceleration = CGFloat(spec.gravity.first ?? 0) * sizeFactor * gravity
        emitter.yAcceleration = CGFloat(spec.gravity.last ?? 0) * sizeFactor * gravity
        emitter.particlePositionRange = CGVector(
            dx: renderedWidth * CGFloat(spec.positionSpread.first ?? 0),
            dy: renderedHeight * CGFloat(spec.positionSpread.last ?? 0))
        let particleScale = CGFloat(spec.scale.start) * sizeFactor * CGFloat(0.6 + 0.4 * intensity)
        emitter.particleScale = particleScale
        emitter.particleScaleRange = CGFloat(spec.scale.variance) * sizeFactor
        emitter.particleScaleSpeed = (CGFloat(spec.scale.end) * sizeFactor * CGFloat(0.6 + 0.4 * intensity) - particleScale) / (CGFloat(spec.lifetime.value) * hang)
        emitter.particleRotationRange = .pi * 2
        emitter.particleRotationSpeed = CGFloat(spec.rotationSpeed)
        emitter.particleAlphaSequence = SKKeyframeSequence(
            keyframeValues: [spec.alpha.start, spec.alpha.peak, spec.alpha.end],
            times: [0, NSNumber(value: spec.alpha.peakAt), 1])
        // Dust is the world's ground, a shade lighter so it shows against
        // it, unless the story names a colour.
        let fallback = name == .dustPuff ? Self.lighter(world.ground) : spec.color
        let color = name.readsColor ? (options.color ?? fallback) : fallback
        emitter.particleColor = UIColor(color)
        emitter.particleColorBlendFactor = 1
        emitter.targetNode = node.parent  // particles live in scene space, not on the sticker
        return emitter
    }

    /// A colour 40 % of the way to white: dust against the ground it came from.
    static func lighter(_ c: RGBA) -> RGBA {
        RGBA(red: c.red + (1 - c.red) * 0.4, green: c.green + (1 - c.green) * 0.4, blue: c.blue + (1 - c.blue) * 0.4, alpha: c.alpha)
    }

    /// The bursts an animation's frame fires as it comes on show: each from
    /// its point of the sticker's image (`StickerAnimation.ParticleCue`).
    func fire(_ animation: StickerAnimation, frame: Int, on node: StickerNode) {
        for cue in animation.particles where cue.frame == frame {
            var options = EffectOptions(intensity: cue.intensity ?? 0.6)
            options.color = cue.color.flatMap(RGBA.init(hex:))
            let w = node.size.width / max(abs(node.xScale), 0.0001), h = node.size.height / max(abs(node.yScale), 0.0001)
            let pivot = EffectTransformMath.pivot(for: EffectAnchor(x: cue.x, y: cue.y), width: w, height: h)
            burst(cue.effect, options: options, on: node, at: CGPoint(x: pivot.x, y: pivot.y))
        }
    }

    /// Where an anchor is on a sticker, in its own space: on its drawing
    /// (`StickerNode.content`), so the feet of a sticker drawn at its size
    /// are its drawing's feet, not its image's bottom edge.
    static func point(_ anchor: EffectAnchor, on node: StickerNode) -> CGPoint {
        let c = node.content
        let onDrawing = EffectAnchor(x: c.minX + anchor.x * c.width, y: (1 - c.maxY) + anchor.y * c.height)
        let w = node.size.width / max(abs(node.xScale), 0.0001), h = node.size.height / max(abs(node.yScale), 0.0001)
        let pivot = EffectTransformMath.pivot(for: onDrawing, width: w, height: h)
        return CGPoint(x: pivot.x, y: pivot.y)
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
