import SpriteKit

/// How a sprite shows a `tint` (`docs/effects.md`): up to half, the colour
/// is blended over the art as SpriteKit colours a sprite (a blush, a cold
/// blue — the look at the usual intensities); past half it washes over
/// the art as a whole, keeping its light and dark, until at the full
/// strength the sticker is all that colour — a stone-grey octopus, still
/// with its eyes and its outline. The wash is a shader set only while a
/// tint goes past half.
extension SKSpriteNode {
    func showTint(_ color: UIColor, amount: CGFloat) {
        self.color = color
        colorBlendFactor = min(amount, 0.5)
        let wash = max(0, min((amount - 0.5) / 0.5, 1))
        guard wash > 0 else {
            if shader === TintWash.shader { shader = nil }
            return
        }
        if shader !== TintWash.shader { shader = TintWash.shader }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        setValue(SKAttributeValue(vectorFloat4: vector_float4(Float(r), Float(g), Float(b), Float(wash))), forAttribute: "a_wash")
    }

    /// Back to no tint at all.
    func clearTint(color: UIColor = .clear, factor: CGFloat = 0) {
        self.color = color
        colorBlendFactor = factor
        if shader === TintWash.shader { shader = nil }
    }
}

enum TintWash {
    /// The art's own light and dark in the tint's colour, mixed over the
    /// sprite's usual shading by the wash's strength. Its light is taken
    /// from the texture as drawn, scaled so the art's middle tones land on
    /// the colour itself.
    static let shader: SKShader = {
        let source = """
            void main() {
                vec4 shaded = SKDefaultShading();
                vec4 art = texture2D(u_texture, v_tex_coord);
                vec3 rgb = art.a > 0.001 ? art.rgb / art.a : vec3(0.0);
                float light = dot(rgb, vec3(0.299, 0.587, 0.114));
                vec3 washed = clamp(a_wash.rgb * (0.25 + 1.3 * light), 0.0, 1.0) * shaded.a;
                gl_FragColor = vec4(mix(shaded.rgb, washed, a_wash.a), shaded.a);
            }
            """
        let shader = SKShader(source: source)
        shader.attributes = [SKAttribute(name: "a_wash", type: .vectorFloat4)]
        return shader
    }()
}
