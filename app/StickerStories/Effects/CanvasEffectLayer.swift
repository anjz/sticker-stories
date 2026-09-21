import SpriteKit
import StickerStoriesKit

/// Renders the canvas effects (`docs/effects.md`, "Canvas effects") over
/// the pack's art frame. Driven every frame by the strengths the
/// `CanvasEffectsRunner` reports: nothing here keeps time of its own, so a
/// seek or a pause looks right for free. Add it to the scene at z 0; its
/// children carry the real z-positions (the rainbow, the moon and the stars
/// sit in the sky behind the foreground art, everything else over the whole
/// canvas).
///
/// The numbers in this file are the tuning surface — content only ever
/// reaches `strength` (intensity × envelope).
@MainActor
final class CanvasEffectLayer: SKNode {
    /// In the sky: over the background art, under the background stickers
    /// and the foreground art (the rainbow, the moon, the stars).
    static let skyZ: CGFloat = 50
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

    // Sunshine: a warm wash, a glow along the whole top edge and a few broad
    // shafts hanging from it — the art paints no sun of its own
    // (docs/pack-format.md), so the light comes from the whole sky.
    private struct Shaft {
        let node: SKSpriteNode
        let x: CGFloat  // fraction of the world width, along the top edge
        let angle: CGFloat  // radians, clockwise from straight down
        let width: CGFloat  // fraction of the world height
        let period: Double
        let phase: Double
    }
    private let sunWash = SKSpriteNode()
    private let skyGlow = SKSpriteNode()
    private var shafts: [Shaft] = []

    private let rainbow = SKSpriteNode()
    private let dim = SKSpriteNode()

    // Night: the dimlight vignette in a deeper blue and a darker wash down
    // from the top edge so the sky goes first, both over everything like
    // the other overlays; a few small stars twinkling on their own slow
    // phases and the moon's disc in the sky behind the foreground art, so
    // the trees stand in front of them; and the moon's halo above the
    // washes — additive light that keeps the disc bright under the darkness
    // and spills a little onto whatever is in front of the moon.
    private let nightDim = SKSpriteNode()
    private let nightSky = SKSpriteNode()
    private struct Star {
        let node: SKSpriteNode
        let place: CGPoint  // fractions of the world
        let size: CGFloat  // fraction of the world height
        let period: Double
        let phase: Double
    }
    private var stars: [Star] = []
    private let moonGlow = SKSpriteNode()
    private let moon = SKSpriteNode()
    /// Where the moon sits, as fractions of the art frame: top centre, the
    /// part of a scene least likely to hold stickers or scenery, and clear
    /// of the corner buttons (the tray is faded out while a story plays).
    private static let moonPlace = CGPoint(x: 0.5, y: 0.82)
    /// A sparse sky: twelve stars in the upper half, none near the moon.
    private static let starLayout: [(CGFloat, CGFloat, CGFloat, Double, Double)] = [
        (0.06, 0.92, 0.012, 2.6, 0.0), (0.17, 0.84, 0.009, 3.1, 1.2), (0.11, 0.70, 0.011, 2.2, 2.4),
        (0.25, 0.95, 0.010, 3.5, 0.7), (0.30, 0.72, 0.013, 2.8, 3.3), (0.36, 0.62, 0.008, 2.4, 1.9),
        (0.64, 0.64, 0.010, 3.2, 0.4), (0.70, 0.91, 0.012, 2.5, 2.8), (0.78, 0.78, 0.009, 3.4, 1.5),
        (0.86, 0.95, 0.011, 2.3, 3.9), (0.92, 0.70, 0.013, 2.9, 0.9), (0.95, 0.85, 0.008, 3.0, 2.1),
    ]

    override init() {
        super.init()
        buildFog()
        buildRain()
        buildSunshine()
        rainbow.texture = EffectTextures.texture(named: "rainbow")
        rainbow.anchorPoint = CGPoint(x: 0.5, y: 0)
        rainbow.zPosition = Self.skyZ
        rainbow.alpha = 0
        addChild(rainbow)
        dim.texture = EffectTextures.texture(named: "vignette")
        dim.color = UIColor(red: 0.055, green: 0.07, blue: 0.19, alpha: 1)
        dim.colorBlendFactor = 1
        dim.zPosition = Self.overlayZ + 3
        dim.alpha = 0
        addChild(dim)
        buildNight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildNight() {
        nightDim.texture = EffectTextures.texture(named: "vignette")
        nightDim.color = UIColor(red: 0.03, green: 0.05, blue: 0.17, alpha: 1)
        nightDim.colorBlendFactor = 1
        nightDim.zPosition = Self.overlayZ + 3
        nightDim.alpha = 0
        addChild(nightDim)
        nightSky.texture = EffectTextures.texture(named: "skyglow")
        nightSky.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the top edge
        nightSky.color = UIColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 1)
        nightSky.colorBlendFactor = 1
        nightSky.zPosition = Self.overlayZ + 3
        nightSky.alpha = 0
        addChild(nightSky)
        for (x, y, size, period, phase) in Self.starLayout {
            let node = SKSpriteNode(texture: EffectTextures.texture(named: "dot"))
            node.color = UIColor(red: 1.0, green: 0.98, blue: 0.9, alpha: 1)
            node.colorBlendFactor = 1
            node.blendMode = .add
            node.zPosition = Self.skyZ
            node.alpha = 0
            addChild(node)
            stars.append(Star(node: node, place: CGPoint(x: x, y: y), size: size, period: period, phase: phase))
        }
        moonGlow.texture = EffectTextures.texture(named: "moonglow")
        moonGlow.color = UIColor(red: 1.0, green: 0.95, blue: 0.75, alpha: 1)
        moonGlow.colorBlendFactor = 1
        moonGlow.blendMode = .add
        moonGlow.zPosition = Self.overlayZ + 4
        moonGlow.alpha = 0
        addChild(moonGlow)
        moon.texture = EffectTextures.texture(named: "moon")
        moon.color = UIColor(red: 1.0, green: 0.97, blue: 0.86, alpha: 1)
        moon.colorBlendFactor = 1
        moon.zPosition = Self.skyZ
        moon.alpha = 0
        addChild(moon)
    }

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
        skyGlow.texture = EffectTextures.texture(named: "skyglow")
        skyGlow.anchorPoint = CGPoint(x: 0.5, y: 1)  // hangs from the top edge
        skyGlow.color = UIColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1)
        skyGlow.colorBlendFactor = 1
        skyGlow.blendMode = .add
        skyGlow.zPosition = Self.overlayZ + 1
        skyGlow.alpha = 0
        addChild(skyGlow)
        let layout: [(CGFloat, CGFloat, CGFloat, Double, Double)] = [
            (0.10, 9, 0.16, 9.0, 0.0), (0.30, -5, 0.24, 11.0, 1.3), (0.50, 3, 0.18, 8.0, 2.9),
            (0.70, -8, 0.26, 12.5, 4.1), (0.90, 6, 0.16, 10.0, 0.7),
        ]
        for (x, degrees, width, period, phase) in layout {
            let node = SKSpriteNode(texture: EffectTextures.texture(named: "ray"))
            node.anchorPoint = CGPoint(x: 0.5, y: 1)
            node.color = UIColor(red: 1.0, green: 0.9, blue: 0.6, alpha: 1)
            node.colorBlendFactor = 1
            node.blendMode = .add
            node.zPosition = Self.overlayZ + 1
            node.alpha = 0
            addChild(node)
            shafts.append(Shaft(node: node, x: x, angle: degrees * .pi / 180, width: width, period: period, phase: phase))
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
        skyGlow.size = CGSize(width: w * 1.04, height: h * 0.6)
        skyGlow.position = CGPoint(x: world.midX, y: world.maxY + h * 0.01)
        for shaft in shafts {
            shaft.node.position = CGPoint(x: world.minX + w * shaft.x, y: world.maxY + h * 0.02)
            shaft.node.size = CGSize(width: h * shaft.width, height: h * 1.15)
        }

        // A wide arc sized by the height (so it sits at the same height on
        // the wide phone art) whose centre is below the scene: only the
        // top of it shows, peaking just under the top edge.
        let radius = h * 1.1
        let textureHeight = radius / 0.98  // the texture's outer edge is 98 % of its height
        rainbow.size = CGSize(width: textureHeight * 2, height: textureHeight)
        rainbow.position = CGPoint(x: world.midX, y: world.minY - h * 0.17)

        dim.size = CGSize(width: w * 1.04, height: h * 1.04)
        dim.position = center

        nightDim.size = dim.size
        nightDim.position = center
        nightSky.size = CGSize(width: w * 1.04, height: h * 0.7)
        nightSky.position = CGPoint(x: world.midX, y: world.maxY + h * 0.01)
        for star in stars {
            star.node.position = CGPoint(x: world.minX + w * star.place.x, y: world.minY + h * star.place.y)
            star.node.size = CGSize(width: h * star.size * 1.3, height: h * star.size * 1.3)
        }
        let moonAt = CGPoint(x: world.minX + w * Self.moonPlace.x, y: world.minY + h * Self.moonPlace.y)
        moon.size = CGSize(width: h * 0.13, height: h * 0.13)
        moon.position = moonAt
        moonGlow.size = CGSize(width: h * 0.55, height: h * 0.55)
        moonGlow.position = moonAt
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
        skyGlow.alpha = sunStrength * (0.24 + 0.04 * sin(2 * .pi * time / 7))
        for shaft in shafts {
            let sway = sin(2 * .pi * time / shaft.period + shaft.phase)
            shaft.node.zRotation = -(shaft.angle + 1.5 * .pi / 180 * sway)  // clockwise from straight down
            shaft.node.alpha = sunStrength * (0.3 + 0.08 * sway)
        }

        rainbow.alpha = (strengths[.rainbow] ?? 0) * 0.72
        dim.alpha = (strengths[.dimlight] ?? 0) * 0.66

        let nightStrength = strengths[.night] ?? 0
        nightDim.alpha = nightStrength * 0.66
        nightSky.alpha = nightStrength * 0.55
        for star in stars {
            // Brighter than they look: the washes above darken them again.
            let twinkle = 0.7 + 0.3 * sin(2 * .pi * time / star.period + star.phase)
            star.node.alpha = min(1, nightStrength * 1.4 * twinkle)
        }
        moon.alpha = nightStrength
        moonGlow.alpha = nightStrength * (0.55 + 0.06 * sin(2 * .pi * time / 6))
    }

    /// Everything off at once (playback cancelled); live raindrops are
    /// dropped too so nothing lingers into edit mode.
    func clearAll() {
        apply([:], at: lastTime)
        rain.resetSimulation()
    }
}
