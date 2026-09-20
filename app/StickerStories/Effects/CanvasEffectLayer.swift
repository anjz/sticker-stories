import SpriteKit
import StickerStoriesKit

/// Renders the canvas effects (`docs/effects.md`, "Canvas effects") over
/// the pack's art frame. Driven every frame by the strengths the
/// `CanvasEffectsRunner` reports: nothing here keeps time of its own, so a
/// seek or a pause looks right for free. Add it to the scene at z 0; its
/// children carry the real z-positions (the rainbow sits in the sky behind
/// the foreground art, everything else over the whole canvas).
///
/// The numbers in this file are the tuning surface — content only ever
/// reaches `strength` (intensity × envelope).
@MainActor
final class CanvasEffectLayer: SKNode {
    /// Over the background art, under the background stickers.
    static let rainbowZ: CGFloat = 50
    /// Over both art planes and every sticker; under the tray (1000).
    static let overlayZ: CGFloat = 500

    private var world: CGRect = .zero
    private var lastTime: TimeInterval = -1

    // Fog: an even haze plus a few big soft blobs, each on its own slow sine drift.
    private let haze = SKSpriteNode()
    private struct Blob {
        let node: SKSpriteNode
        let base: CGPoint  // fractions of the world
        let size: CGSize  // fractions of the world
        let period: Double
        let phase: Double
        let weight: Double
    }
    private var fog: [Blob] = []

    // Rain: an emitter across the top edge plus a cool wash.
    private let rain = SKEmitterNode()
    private let rainWash = SKSpriteNode()

    // Sunshine: a warm wash plus rays fanning from the top-left corner.
    private struct Ray {
        let node: SKSpriteNode
        let angle: CGFloat  // radians, clockwise from straight down
        let width: CGFloat  // fraction of the world height
        let period: Double
        let phase: Double
    }
    private let sunWash = SKSpriteNode()
    private var rays: [Ray] = []

    private let rainbow = SKSpriteNode()
    private let dim = SKSpriteNode()

    override init() {
        super.init()
        buildFog()
        buildRain()
        buildSunshine()
        rainbow.texture = EffectTextures.texture(named: "rainbow")
        rainbow.anchorPoint = CGPoint(x: 0.5, y: 0)
        rainbow.zPosition = Self.rainbowZ
        rainbow.alpha = 0
        addChild(rainbow)
        dim.texture = EffectTextures.texture(named: "vignette")
        dim.color = UIColor(red: 0.055, green: 0.07, blue: 0.19, alpha: 1)
        dim.colorBlendFactor = 1
        dim.zPosition = Self.overlayZ + 3
        dim.alpha = 0
        addChild(dim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static let fogColor = UIColor(red: 0.9, green: 0.93, blue: 0.95, alpha: 1)

    private func buildFog() {
        haze.color = Self.fogColor
        haze.zPosition = Self.overlayZ
        haze.alpha = 0
        addChild(haze)
        let layout: [(CGPoint, CGSize, Double, Double, Double)] = [
            (CGPoint(x: 0.15, y: 0.30), CGSize(width: 0.95, height: 0.42), 19, 0.0, 1.0),
            (CGPoint(x: 0.80, y: 0.22), CGSize(width: 0.90, height: 0.38), 23, 1.9, 0.95),
            (CGPoint(x: 0.50, y: 0.48), CGSize(width: 1.05, height: 0.44), 27, 3.7, 0.8),
            (CGPoint(x: 0.30, y: 0.70), CGSize(width: 0.85, height: 0.38), 21, 0.8, 0.7),
            (CGPoint(x: 0.85, y: 0.64), CGSize(width: 0.80, height: 0.36), 25, 2.6, 0.65),
            (CGPoint(x: 0.55, y: 0.08), CGSize(width: 1.0, height: 0.32), 17, 4.4, 0.9),
        ]
        for (base, size, period, phase, weight) in layout {
            let node = SKSpriteNode(texture: EffectTextures.texture(named: "fog"))
            node.color = Self.fogColor
            node.colorBlendFactor = 1
            node.zPosition = Self.overlayZ + 1
            node.alpha = 0
            addChild(node)
            fog.append(Blob(node: node, base: base, size: size, period: period, phase: phase, weight: weight))
        }
    }

    private static let rainWind: CGFloat = -8 * .pi / 180  // a little to the left

    private func buildRain() {
        rain.particleTexture = EffectTextures.texture(named: "drop")
        rain.particleBlendMode = .alpha
        rain.particleColor = UIColor(red: 0.87, green: 0.92, blue: 1.0, alpha: 1)
        rain.particleColorBlendFactor = 1
        rain.emissionAngle = 3 * .pi / 2 + Self.rainWind  // straight down, leaning
        rain.emissionAngleRange = 0.03
        rain.particleRotation = Self.rainWind  // streaks aligned with the fall
        rain.particleAlpha = 0.65
        rain.particleAlphaRange = 0.3
        rain.particleBirthRate = 0
        rain.zPosition = Self.overlayZ + 2
        addChild(rain)

        rainWash.color = UIColor(red: 0.18, green: 0.25, blue: 0.39, alpha: 1)
        rainWash.zPosition = Self.overlayZ
        rainWash.alpha = 0
        addChild(rainWash)
    }

    private func buildSunshine() {
        sunWash.color = UIColor(red: 1.0, green: 0.82, blue: 0.48, alpha: 1)
        sunWash.blendMode = .add
        sunWash.zPosition = Self.overlayZ
        sunWash.alpha = 0
        addChild(sunWash)
        let layout: [(CGFloat, CGFloat, Double, Double)] = [
            (16, 0.09, 9.0, 0.0), (30, 0.17, 11.0, 1.3), (44, 0.11, 8.0, 2.9), (57, 0.20, 12.5, 4.1), (70, 0.10, 10.0, 0.7),
        ]
        for (degrees, width, period, phase) in layout {
            let node = SKSpriteNode(texture: EffectTextures.texture(named: "ray"))
            node.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the sun
            node.color = UIColor(red: 1.0, green: 0.88, blue: 0.55, alpha: 1)
            node.colorBlendFactor = 1
            node.blendMode = .add
            node.zPosition = Self.overlayZ + 1
            node.alpha = 0
            addChild(node)
            rays.append(Ray(node: node, angle: degrees * .pi / 180, width: width, period: period, phase: phase))
        }
    }

    // MARK: Layout

    /// Sizes everything to the art frame (world coordinates). Call whenever
    /// the scene lays out; cheap.
    func layout(world: CGRect) {
        guard world != self.world, world.width > 0, world.height > 0 else { return }
        self.world = world
        let w = world.width, h = world.height
        let center = CGPoint(x: world.midX, y: world.midY)

        haze.size = CGSize(width: w * 1.02, height: h * 1.02)
        haze.position = center
        for blob in fog {
            blob.node.size = CGSize(width: w * blob.size.width, height: h * blob.size.height)
        }

        rain.position = CGPoint(x: world.midX, y: world.maxY + h * 0.06)
        rain.particlePositionRange = CGVector(dx: w * 1.3, dy: 0)
        let speed = h * 1.15  // crosses the scene in under a second
        rain.particleSpeed = speed
        rain.particleSpeedRange = speed * 0.25
        rain.particleLifetime = 1.5
        rain.particleLifetimeRange = 0.3
        rain.particleScale = h / 700
        rain.particleScaleRange = rain.particleScale * 0.4
        rainWash.size = CGSize(width: w * 1.02, height: h * 1.02)
        rainWash.position = center

        sunWash.size = rainWash.size
        sunWash.position = center
        let sun = CGPoint(x: world.minX + w * 0.1, y: world.maxY + h * 0.03)
        for ray in rays {
            ray.node.position = sun
            ray.node.size = CGSize(width: h * ray.width, height: h * 1.7)
        }

        // A wide arc whose centre sits below the scene, so only the top of
        // it shows — high in the sky, clearing the horizon at the edges.
        rainbow.size = CGSize(width: w * 1.7, height: w * 0.85)
        rainbow.position = CGPoint(x: world.midX, y: world.minY - h * 0.25)

        dim.size = CGSize(width: w * 1.04, height: h * 1.04)
        dim.position = center
    }

    // MARK: Per-frame

    /// Renders the given strengths (0...1 per effect kind, absent = off) at
    /// timeline time `time`; a time that does not advance pauses the rain.
    func apply(_ strengths: [CanvasEffectName: Double], at time: TimeInterval) {
        let paused = time == lastTime
        lastTime = time
        guard world.width > 0 else { return }

        let fogStrength = strengths[.fog] ?? 0
        for blob in fog {
            let drift = sin(2 * .pi * time / blob.period + blob.phase)
            let bob = sin(2 * .pi * time / (blob.period * 1.6) + blob.phase * 0.5)
            blob.node.position = CGPoint(
                x: world.minX + world.width * (blob.base.x + 0.10 * drift),
                y: world.minY + world.height * (blob.base.y + 0.025 * bob))
            blob.node.alpha = fogStrength * 0.85 * blob.weight
        }
        haze.alpha = fogStrength * 0.25

        let rainStrength = strengths[.rain] ?? 0
        rain.particleBirthRate = rainStrength * 380 * (world.width / 1000)
        rain.isPaused = paused
        rainWash.alpha = rainStrength * 0.16

        let sunStrength = strengths[.sunshine] ?? 0
        sunWash.alpha = sunStrength * 0.12
        for ray in rays {
            let sway = sin(2 * .pi * time / ray.period + ray.phase)
            ray.node.zRotation = -(ray.angle + 1.5 * .pi / 180 * sway)  // clockwise from straight down
            ray.node.alpha = sunStrength * (0.5 + 0.1 * sway)
        }

        rainbow.alpha = (strengths[.rainbow] ?? 0) * 0.72
        dim.alpha = (strengths[.dimlight] ?? 0) * 0.66
    }

    /// Everything off at once (playback cancelled); live raindrops are
    /// dropped too so nothing lingers into edit mode.
    func clearAll() {
        apply([:], at: lastTime)
        rain.resetSimulation()
    }
}
