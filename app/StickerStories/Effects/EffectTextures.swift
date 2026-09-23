import SpriteKit
import UIKit

/// Particle and canvas-effect textures drawn once with CoreGraphics.
/// Placeholder-art era: swap for PNGs when real art lands, keeping the same
/// names (`star`, `dot`, `heart` for the emitters in `emitters.json`;
/// `drop`, `fog`, `ray`, `skyglow`, `rainbow`, `vignette`, `moon`, `moonglow`
/// for `CanvasEffectLayer`; `band` and the rest below for the painters in
/// `Canvas/`).
/// `dot` is kept as the generic soft particle even though no emitter uses
/// it today.
enum EffectTextures {
    private static var cache: [String: SKTexture] = [:]

    static func texture(named name: String) -> SKTexture {
        if let cached = cache[name] { return cached }
        let texture: SKTexture
        switch name {
        case "drop": texture = procedural(width: 6, height: 28, drop)
        case "fog": texture = procedural(width: 256, height: 128, fogBlob)
        case "ray": texture = procedural(width: 64, height: 256, ray)
        case "skyglow": texture = procedural(width: 4, height: 256, skyGlow)
        case "vignette": texture = procedural(width: 256, height: 256, vignette)
        case "moon": texture = procedural(width: 128, height: 128, moon)
        case "moonglow": texture = procedural(width: 256, height: 256, moonGlow)
        case "band": texture = procedural(width: 4, height: 256, band)
        case "cloud": texture = shaded(width: 320, height: 160, cloud)
        case "wisp": texture = procedural(width: 256, height: 16, wisp)
        case "rainbow": texture = drawn(size: CGSize(width: 1024, height: 512), scale: 1) { rect, cg in drawRainbow(in: rect, cg) }
        case "leaf": texture = drawn(size: CGSize(width: 44, height: 64), scale: 2) { rect, cg in drawLeaf(in: rect, cg) }
        default:
            texture = drawn(size: CGSize(width: 32, height: 32), scale: 3) { rect, cg in
                switch name {
                case "star": drawStar(in: rect, cg)
                case "heart": drawHeart(in: rect, cg)
                default: drawDot(in: rect, cg)
                }
            }
        }
        cache[name] = texture
        return texture
    }

    private static func drawn(size: CGSize, scale: CGFloat, _ draw: (CGRect, CGContext) -> Void) -> SKTexture {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(CGRect(origin: .zero, size: size), context.cgContext)
        }
        return SKTexture(image: image)
    }

    // MARK: Procedural (white, per-pixel alpha)

    /// A white texture whose alpha is `alpha(u, v)` with `u`, `v` in 0...1,
    /// `v` running top to bottom. Tinted at use with `colorBlendFactor`.
    private static func procedural(width: Int, height: Int, _ alpha: (Double, Double) -> Double) -> SKTexture {
        shaded(width: width, height: height) { u, v in (1, alpha(u, v)) }
    }

    /// Like `procedural`, with a grey level per pixel as well: `shade(u, v)`
    /// returns (grey, alpha). Used as it is (`colorBlendFactor` 0) or tinted.
    private static func shaded(width: Int, height: Int, _ shade: (Double, Double) -> (Double, Double)) -> SKTexture {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let (grey, alpha) = shade(u, v)
                let a = alpha.clamped(to: 0...1)
                let c = UInt8((grey.clamped(to: 0...1) * a * 255).rounded())  // premultiplied
                let i = y * bytesPerRow + x * 4
                bytes[i] = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = UInt8((a * 255).rounded())
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return SKTexture() }
        return SKTexture(cgImage: image)
    }

    private static func bell(_ t: Double) -> Double {
        let x = (t * 2 - 1).clamped(to: -1...1)
        return (1 - x * x) * (1 - x * x)
    }

    /// A thin vertical streak, brightest toward its lower end.
    private static func drop(_ u: Double, _ v: Double) -> Double {
        bell(u) * (0.35 + 0.65 * v) * bell(v * 0.5 + 0.25)
    }

    /// A soft elliptical blob — several overlap into mist.
    private static func fogBlob(_ u: Double, _ v: Double) -> Double {
        let dx = (u - 0.5) * 2, dy = (v - 0.5) * 2
        let d = min(1, dx * dx + dy * dy)
        return (1 - d) * (1 - d)
    }

    /// A light ray: a soft band across, fading along its length (top = source).
    private static func ray(_ u: Double, _ v: Double) -> Double {
        bell(u) * pow(1 - v, 1.5)
    }

    /// Light along the whole top edge, fading downward.
    private static func skyGlow(_ u: Double, _ v: Double) -> Double {
        pow(1 - v, 2.5)
    }

    /// A soft horizontal band, brightest along its middle: a glow on the horizon.
    private static func band(_ u: Double, _ v: Double) -> Double {
        let x = (v - 0.5) * 2
        return exp(-4 * x * x)
    }

    /// A puffy cloud twice as wide as it is tall: soft domes that melt into
    /// one shape (their fields add up, like metaballs) on a flatter base,
    /// white on top and faintly shaded underneath.
    private static func cloud(_ u: Double, _ v: Double) -> (Double, Double) {
        let puffs: [(Double, Double, Double)] = [
            (0.30, 0.56, 0.17), (0.50, 0.44, 0.22), (0.68, 0.54, 0.17),
            (0.16, 0.66, 0.11), (0.84, 0.66, 0.11), (0.40, 0.64, 0.15), (0.60, 0.64, 0.15),
        ]
        var field = 0.0
        for (cu, cv, r) in puffs {
            let dx = (u - cu) * 2, dy = v - cv  // the texture is 2:1
            field += exp(-(dx * dx + dy * dy) / (r * r))
        }
        var alpha = smoothstep(0.25, 0.75, field)
        alpha *= 1 - smoothstep(0.68, 0.8, v)  // the flat underside
        return (1 - 0.1 * smoothstep(0.4, 0.8, v), alpha)
    }

    /// A long, thin streak of air: fullest a little behind its middle,
    /// tapering to nothing at both ends.
    private static func wisp(_ u: Double, _ v: Double) -> Double {
        bell(v) * pow(sin(.pi * u), 1.6) * (0.55 + 0.45 * u)
    }

    /// Opaque at the edges, thinner in the middle: a dimmed room.
    private static func vignette(_ u: Double, _ v: Double) -> Double {
        let dx = (u - 0.5) * 2, dy = (v - 0.5) * 2
        let d = min(1, (dx * dx + dy * dy).squareRoot() / 1.2)
        return 0.5 + 0.5 * d * d
    }

    /// A full moon: a solid disc with a soft edge.
    private static func moon(_ u: Double, _ v: Double) -> Double {
        let dx = (u - 0.5) * 2, dy = (v - 0.5) * 2
        let d = (dx * dx + dy * dy).squareRoot()
        return 1 - smoothstep(0.88, 0.96, d)
    }

    /// The moon's halo: brightest at the centre, gone at the edge, on a
    /// steep curve so it reads as glow rather than a bright square.
    private static func moonGlow(_ u: Double, _ v: Double) -> Double {
        let dx = (u - 0.5) * 2, dy = (v - 0.5) * 2
        let d = min(1, (dx * dx + dy * dy).squareRoot())
        return pow(1 - d, 2.6)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// Seven soft bands, an upper semicircle whose centre is the bottom
    /// middle and whose outer edge touches the texture's edges; the bands
    /// take about a tenth of the radius.
    private static func drawRainbow(in rect: CGRect, _ cg: CGContext) {
        let colors: [UIColor] = [
            UIColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1),
            UIColor(red: 1.0, green: 0.62, blue: 0.3, alpha: 1),
            UIColor(red: 1.0, green: 0.9, blue: 0.4, alpha: 1),
            UIColor(red: 0.45, green: 0.85, blue: 0.45, alpha: 1),
            UIColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1),
            UIColor(red: 0.45, green: 0.5, blue: 0.95, alpha: 1),
            UIColor(red: 0.7, green: 0.5, blue: 0.9, alpha: 1),
        ]
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        let outer = rect.height * 0.98
        let band = rect.height * 0.017
        cg.setLineCap(.butt)
        for (index, color) in colors.enumerated() {
            let radius = outer - band * (CGFloat(index) + 0.5)
            let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: .pi, endAngle: 2 * .pi, clockwise: true)
            cg.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
            cg.setLineWidth(band * 1.05)
            cg.addPath(path.cgPath)
            cg.strokePath()
        }
        // Feather the outer and inner edges.
        for (radius, width) in [(outer, band * 0.9), (outer - band * CGFloat(colors.count), band * 0.9)] {
            let path = UIBezierPath(arcCenter: center, radius: radius, startAngle: .pi, endAngle: 2 * .pi, clockwise: true)
            cg.setBlendMode(.destinationOut)
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            cg.setLineWidth(width)
            cg.addPath(path.cgPath)
            cg.strokePath()
            cg.setBlendMode(.normal)
        }
    }

    /// A soft radial dot — glows, generic sparks.
    private static func drawDot(in rect: CGRect, _ cg: CGContext) {
        let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.6).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: rect.width / 2, options: [])
    }

    /// A four-point twinkle with a faint core glow.
    private static func drawStar(in rect: CGRect, _ cg: CGContext) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width / 2, inner = rect.width * 0.09
        let path = UIBezierPath()
        for i in 0..<8 {
            let radius = i % 2 == 0 ? outer : inner
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        cg.setFillColor(UIColor.white.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
        let colors = [UIColor.white.withAlphaComponent(0.7).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: rect.width * 0.3, options: [])
        }
    }

    /// A pointed leaf with a short stem and a darker midrib, white so each
    /// falling leaf can be tinted its own autumn colour.
    private static func drawLeaf(in rect: CGRect, _ cg: CGContext) {
        let w = rect.width, h = rect.height
        let blade = UIBezierPath()
        blade.move(to: CGPoint(x: w / 2, y: h * 0.04))
        blade.addCurve(to: CGPoint(x: w / 2, y: h * 0.86), controlPoint1: CGPoint(x: w * 1.02, y: h * 0.28), controlPoint2: CGPoint(x: w * 0.9, y: h * 0.7))
        blade.addCurve(to: CGPoint(x: w / 2, y: h * 0.04), controlPoint1: CGPoint(x: w * 0.1, y: h * 0.7), controlPoint2: CGPoint(x: -w * 0.02, y: h * 0.28))
        blade.close()
        cg.setFillColor(UIColor.white.cgColor)
        cg.addPath(blade.cgPath)
        cg.fillPath()
        let rib = UIBezierPath()
        rib.move(to: CGPoint(x: w / 2, y: h * 0.12))
        rib.addLine(to: CGPoint(x: w / 2, y: h * 0.98))
        cg.setStrokeColor(UIColor(white: 0.62, alpha: 1).cgColor)
        cg.setLineWidth(w * 0.06)
        cg.setLineCap(.round)
        cg.addPath(rib.cgPath)
        cg.strokePath()
    }

    private static func drawHeart(in rect: CGRect, _ cg: CGContext) {
        let w = rect.width, h = rect.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: w / 2, y: h * 0.92))
        path.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.36), controlPoint1: CGPoint(x: w * 0.2, y: h * 0.72), controlPoint2: CGPoint(x: w * 0.04, y: h * 0.56))
        path.addArc(withCenter: CGPoint(x: w * 0.27, y: h * 0.3), radius: w * 0.23, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(withCenter: CGPoint(x: w * 0.73, y: h * 0.3), radius: w * 0.23, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addCurve(to: CGPoint(x: w / 2, y: h * 0.92), controlPoint1: CGPoint(x: w * 0.96, y: h * 0.56), controlPoint2: CGPoint(x: w * 0.8, y: h * 0.72))
        path.close()
        cg.setFillColor(UIColor.white.cgColor)
        cg.addPath(path.cgPath)
        cg.fillPath()
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
