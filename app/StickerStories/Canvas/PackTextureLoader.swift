import SpriteKit
import StickerStoriesKit
import UIKit

/// A pack's art and sticker images as textures, decoded and uploaded to
/// the GPU before the canvas is shown. Decoding ~40 megapixels of PNG on
/// the main thread is what used to make opening a pack stall mid-transition.
struct PackTextures {
    var background: SKTexture?
    var foreground: SKTexture?
    /// The wide renditions, both or neither (docs/pack-format.md).
    var wide: (background: SKTexture, foreground: SKTexture?)?
    var stickers: [String: SKTexture]
}

enum PackTextureLoader {
    /// Decodes every image of the pack concurrently off the main thread,
    /// wraps them as textures and preloads those, so the scene's first frame
    /// has nothing left to do but draw.
    @MainActor
    static func load(_ pack: LoadedPack) async -> PackTextures {
        var paths: [String: String] = [
            "background": pack.manifest.background,
            "foreground": pack.manifest.foreground,
        ]
        if let wideBackground = pack.manifest.backgroundWide, let wideForeground = pack.manifest.foregroundWide {
            paths["background-wide"] = wideBackground
            paths["foreground-wide"] = wideForeground
        }
        for sticker in pack.manifest.stickers {
            paths["sticker:" + sticker.id] = sticker.image
        }

        let images = await withTaskGroup(of: (String, UIImage?).self) { group in
            for (key, path) in paths {
                let url = pack.url(forAssetPath: path)
                group.addTask { (key, await decode(url)) }
            }
            var decoded: [String: UIImage] = [:]
            for await (key, image) in group {
                if let image { decoded[key] = image }
            }
            return decoded
        }

        var textures = PackTextures(
            background: images["background"].map(SKTexture.init(image:)),
            foreground: images["foreground"].map(SKTexture.init(image:)),
            wide: nil,
            stickers: [:])
        if let wideBackground = images["background-wide"] {
            textures.wide = (SKTexture(image: wideBackground), images["foreground-wide"].map(SKTexture.init(image:)))
        }
        for sticker in pack.manifest.stickers {
            if let image = images["sticker:" + sticker.id] {
                textures.stickers[sticker.id] = SKTexture(image: image)
            }
        }

        var all = Array(textures.stickers.values)
        for texture in [textures.background, textures.foreground, textures.wide?.background, textures.wide?.foreground] {
            if let texture { all.append(texture) }
        }
        await withCheckedContinuation { continuation in
            SKTexture.preload(all) { continuation.resume() }
        }
        return textures
    }

    /// Reads and fully decodes one image on a background thread.
    private nonisolated static func decode(_ url: URL) async -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }
}
