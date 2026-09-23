import SpriteKit

/// A field of sprites drifting through the art frame — snowflakes,
/// confetti, bubbles, fireflies — each placed from the timeline time, so
/// the field needs no emitter and a seek or a pause looks right for free.
///
/// Every sprite gets a fixed random depth (near ones are bigger, faster and
/// brighter) and random phases from a seeded generator, so the field looks
/// the same every time a story plays. `strength` sets how many of them are
/// out: at 0.3 a third of the sprites show, and the envelope's ramp fades
/// them in one by one. Fields that `enter` start just beyond the edge they
/// come from when the effect begins, so snow falls in from the top rather
/// than appearing all over the scene.
@MainActor
final class DriftField {
    struct Style {
        var count: Int
        var texture: SKTexture
        /// Picked per sprite, in turn.
        var colors: [UIColor]
        var blendMode: SKBlendMode = .alpha
        var zPosition: CGFloat
        /// Sprite height as a fraction of the world height, far to near.
        var size: ClosedRange<Double>
        /// Width over height of a sprite.
        var aspect: Double = 1
        /// World heights per second at the nearest depth (x right, y up).
        var velocity: CGVector = .zero
        /// Speed multiplier from the farthest to the nearest sprite.
        var depthSpeed: ClosedRange<Double> = 0.5...1
        /// Side-to-side sway (fractions of the world height) and its period range.
        var sway: Double = 0
        var swayPeriod: ClosedRange<Double> = 3...6
        /// Up-and-down wander, for fields that hover rather than travel.
        var wander: Double = 0
        var wanderPeriod: ClosedRange<Double> = 4...8
        /// Radians per second, random sign.
        var spin: ClosedRange<Double> = 0...0
        /// Paper turning over: the sprite's width follows a cosine with a
        /// period in this range (nil: no flutter).
        var flutter: ClosedRange<Double>? = nil
        /// Alpha from far to near.
        var alpha: ClosedRange<Double> = 1...1
        /// A slow brightness pulse (0: steady) and its period range.
        var twinkle: Double = 0
        var twinklePeriod: ClosedRange<Double> = 2...4
        /// Where the sprites live, as fractions of the world (x, y, width,
        /// height; y up). They wrap around its edges plus `margin`.
        var region = CGRect(x: 0, y: 0, width: 1, height: 1)
        var margin: Double = 0.08
        /// Start beyond the edge the field travels in from when the effect
        /// begins, rather than all over the scene.
        var enters = true
        var seed: UInt64
    }

    private struct Sprite {
        let node: SKSpriteNode
        let x: Double, y: Double  // 0...1 inside the wrapped region
        let depth: Double
        let swayPeriod: Double, wanderPeriod: Double, twinklePeriod: Double
        let phase: Double
        let spin: Double
        let flutterPeriod: Double
    }

    let node = SKNode()
    private let style: Style
    private var sprites: [Sprite] = []
    private var world: CGRect = .zero
    /// When the effect began (sprites that `enter` count from here).
    private var began: TimeInterval?

    init(_ style: Style) {
        self.style = style
        var random = SeededRandom(seed: style.seed)
        for index in 0..<style.count {
            let sprite = SKSpriteNode(texture: style.texture)
            sprite.color = style.colors[index % style.colors.count]
            sprite.colorBlendFactor = 1
            sprite.blendMode = style.blendMode
            sprite.zPosition = style.zPosition
            sprite.alpha = 0
            node.addChild(sprite)
            let spinSign: Double = random.next() < 0.5 ? -1 : 1
            sprites.append(Sprite(
                node: sprite, x: random.next(), y: random.next(), depth: random.next(),
                swayPeriod: random.next(in: style.swayPeriod), wanderPeriod: random.next(in: style.wanderPeriod),
                twinklePeriod: random.next(in: style.twinklePeriod), phase: random.next() * 2 * .pi,
                spin: spinSign * random.next(in: style.spin), flutterPeriod: style.flutter.map { random.next(in: $0) } ?? 0))
        }
    }

    func layout(world: CGRect) {
        self.world = world
        for sprite in sprites {
            let height = world.height * Self.lerp(style.size, sprite.depth)
            sprite.node.size = CGSize(width: height * style.aspect, height: height)
        }
    }

    /// Forgets when the effect began: the next `apply` starts a new entry.
    func reset() { began = nil }

    func apply(strength: Double, at time: TimeInterval) {
        guard world.width > 0 else { return }
        if began == nil || time < began! { began = time }
        let elapsed = time - began!
        let w = world.width, h = world.height
        let margin = style.margin
        // The wrapped region in world units, margins included.
        let spanX = (style.region.width + 2 * margin * h / w) * w
        let spanY = (style.region.height + 2 * margin) * h
        let minX = world.minX + (style.region.minX * w) - margin * h
        let minY = world.minY + (style.region.minY * h) - margin * h
        let travelsX = abs(style.velocity.dx) > abs(style.velocity.dy)
        let enters = style.enters && (style.velocity.dx != 0 || style.velocity.dy != 0)
        let visible = strength * Double(sprites.count)

        for (index, sprite) in sprites.enumerated() {
            let share = min(1, max(0, visible - Double(index)))
            guard share > 0 else {
                sprite.node.alpha = 0
                continue
            }
            let speed = Self.lerp(style.depthSpeed, sprite.depth)
            var x = sprite.x * spanX + style.velocity.dx * speed * h * elapsed
            var y = sprite.y * spanY + style.velocity.dy * speed * h * elapsed
            // Entering: start one span back along the direction of travel,
            // and only wrap once the sprite has come in.
            if enters {
                if travelsX {
                    x -= style.velocity.dx > 0 ? spanX : -spanX
                } else {
                    y -= style.velocity.dy > 0 ? spanY : -spanY
                }
            }
            let outside = enters
                && (travelsX
                    ? (style.velocity.dx > 0 ? x < 0 : x > spanX)
                    : (style.velocity.dy > 0 ? y < 0 : y > spanY))
            if !outside {
                x = Self.wrap(x, spanX)
                y = Self.wrap(y, spanY)
            }
            x += style.sway * h * sin(2 * .pi * elapsed / sprite.swayPeriod + sprite.phase)
            y += style.wander * h * sin(2 * .pi * elapsed / sprite.wanderPeriod + sprite.phase * 1.7)
            sprite.node.position = CGPoint(x: minX + x, y: minY + y)
            sprite.node.zRotation = sprite.phase + sprite.spin * elapsed
            if sprite.flutterPeriod > 0 {
                sprite.node.xScale = max(0.15, abs(cos(2 * .pi * elapsed / sprite.flutterPeriod + sprite.phase)))
            }
            var alpha = Self.lerp(style.alpha, sprite.depth)
            if style.twinkle > 0 {
                alpha *= 1 - style.twinkle * (0.5 + 0.5 * sin(2 * .pi * elapsed / sprite.twinklePeriod + sprite.phase))
            }
            sprite.node.alpha = outside ? 0 : alpha * share
        }
    }

    private static func lerp(_ range: ClosedRange<Double>, _ t: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }

    private static func wrap(_ value: Double, _ span: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: span)
        return r < 0 ? r + span : r
    }
}

/// SplitMix64: a tiny deterministic generator, so a canvas effect's random
/// layout is the same on every play.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// A double in 0..<1.
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * next()
    }
}
