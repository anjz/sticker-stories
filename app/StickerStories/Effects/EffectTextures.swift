import SpriteKit
import UIKit

/// Particle textures drawn once with CoreGraphics. Placeholder-art era:
/// swap for PNGs when real art lands, keeping the same names
/// (`star`, `dot`, `heart`) so `emitters.json` does not change. `dot` is
/// kept as the generic soft particle even though no emitter uses it today.
enum EffectTextures {
    private static var cache: [String: SKTexture] = [:]

    static func texture(named name: String) -> SKTexture {
        if let cached = cache[name] { return cached }
        let side: CGFloat = 32
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            switch name {
            case "star": drawStar(in: rect, cg)
            case "heart": drawHeart(in: rect, cg)
            default: drawDot(in: rect, cg)
            }
        }
        let texture = SKTexture(image: image)
        cache[name] = texture
        return texture
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
