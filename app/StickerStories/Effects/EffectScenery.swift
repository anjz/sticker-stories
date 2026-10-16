import ImageIO
import SpriteKit
import StickerStoriesKit

/// What the canvas effects know of the scene's art, worked out once when
/// the pack loads (`PackTextureLoader`), for the base art and the wide
/// art: where the background is open sky — the pack's sky mask
/// (`docs/pack-format.md`, "Sky"), which clips everything drawn in the sky
/// — and where snow settles on the ground (`SnowScenery.ground`). The snow
/// caps on the scene's layers travel with the layers (`LayerTextures`).
struct EffectScenery {
    struct Plane {
        /// The open sky as a crop mask: opaque in the sky, a hard edge
        /// halfway through the mask's soft one (`SKCropNode` keeps what
        /// is over alpha 0.05).
        var sky: SKTexture?
        /// The snow field of the ground (`SnowScenery`), drawn with
        /// `CanvasEffectLayer.snowShader`.
        var ground: SKTexture?
        var flakes: [SnowScenery.Flake] = []

        init() {}

        init(_ images: Images.Plane) {
            sky = images.sky.map(SKTexture.init(cgImage:))
            ground = images.ground.map(SKTexture.init(cgImage:))
            flakes = images.flakes
        }
    }

    var base = Plane()
    var wide: Plane?

    func plane(wide: Bool) -> Plane { wide ? (self.wide ?? base) : base }

    init() {}

    init(_ images: Images) {
        base = Plane(images.base)
        wide = images.wide.map(Plane.init)
    }

    /// The scenery of a pack's base art, made right away (the effects
    /// gallery, which draws only the background).
    static func load(_ pack: LoadedPack) -> EffectScenery {
        EffectScenery(images(
            sky: pack.manifest.sky.map { pack.url(forAssetPath: $0.image) }, skyWide: nil,
            space: pack.manifest.space, aspect: 4.0 / 3))
    }

    /// The images behind the textures, made off the main actor.
    struct Images: @unchecked Sendable {
        struct Plane {
            var sky: CGImage?
            var ground: CGImage?
            var flakes: [SnowScenery.Flake] = []
        }
        var base = Plane()
        var wide: Plane?
    }

    /// The scenery of a pack: from its sky masks and its space. Without
    /// masks there is no sky to clip by, and the snow lies on the ground
    /// of the space alone (or along the bottom, without one either).
    nonisolated static func images(sky: URL?, skyWide: URL?, space: SceneSpace?, aspect: Double) -> Images {
        var images = Images()
        let masks = [sky, skyWide].map { url in
            url.flatMap(PackTextureLoader.decode).flatMap { BytePlane.alpha(of: $0, width: $0.width, height: $0.height) }
        }
        // The base art's shape and the wide art's frame on it, from the
        // masks (each is its background's shape).
        let aspect = masks[0].map { Double($0.width) / Double(max($0.height, 1)) } ?? aspect
        var wideFrame = (minX: 0.0, width: 1.0)
        if let base = masks[0], let wide = masks[1], base.height > 0, wide.height > 0 {
            let ratio = (Double(wide.width) / Double(wide.height)) / (Double(base.width) / Double(base.height))
            wideFrame = (minX: -(ratio - 1) / 2, width: ratio)
        }
        func plane(_ mask: BytePlane?, frame: (minX: Double, width: Double)) -> Images.Plane {
            var plane = Images.Plane()
            // The crop is hard: put its edge where the soft one is half-way.
            plane.sky = mask?.mapped { UInt8(min(255, max(0, (Int($0) - 116) * 10))) }.maskImage()
            // The snow field at the mask's resolution (half the art's): the
            // cap along the treeline stays crisp enough.
            let height = max(1, mask?.height ?? 768)
            let width = max(1, Int((Double(height) * aspect * frame.width).rounded()))
            let (field, flakes) = SnowScenery.ground(
                width: width, height: height, frame: frame, aspect: aspect, space: space, sky: mask)
            plane.ground = field.image()
            plane.flakes = flakes
            return plane
        }
        images.base = plane(masks[0], frame: (0, 1))
        if skyWide != nil || masks[1] != nil {
            images.wide = plane(masks[1], frame: wideFrame)
        }
        return images
    }

    /// The snow cap of a plane with alpha (a layer's piece, the
    /// foreground), at half its resolution; `artHeight` is the art's
    /// height in the plane's pixels.
    nonisolated static func snowCap(of image: CGImage, artHeight: Int) -> CGImage? {
        let width = max(1, image.width / 2), height = max(1, image.height / 2)
        guard let alpha = BytePlane.alpha(of: image, width: width, height: height) else { return nil }
        return SnowScenery.caps(of: alpha, thickness: SnowScenery.capThickness * Double(artHeight) / 2).image()
    }
}
