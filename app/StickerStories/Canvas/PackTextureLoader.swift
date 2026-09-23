import ImageIO
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
    /// Reads every image of the pack concurrently off the main thread, wraps
    /// them as textures and preloads those (SpriteKit decodes and uploads on
    /// its own queue), so the scene's first frame has nothing left to do but
    /// draw.
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

        let images = await withTaskGroup(of: (String, CGImage?).self) { group in
            for (key, path) in paths {
                let url = pack.url(forAssetPath: path)
                group.addTask { (key, decode(url)) }
            }
            var decoded: [String: CGImage] = [:]
            for await (key, image) in group {
                if let image { decoded[key] = image }
            }
            return decoded
        }

        var textures = PackTextures(
            background: images["background"].map(SKTexture.init(cgImage:)),
            foreground: images["foreground"].map(SKTexture.init(cgImage:)),
            wide: nil,
            stickers: [:])
        if let wideBackground = images["background-wide"] {
            textures.wide = (SKTexture(cgImage: wideBackground), images["foreground-wide"].map(SKTexture.init(cgImage:)))
        }
        for sticker in pack.manifest.stickers {
            if let image = images["sticker:" + sticker.id] {
                textures.stickers[sticker.id] = SKTexture(cgImage: image)
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

    /// Decodes one image into a plain bitmap on a background thread with
    /// ImageIO (no UIKit decompressor involved).
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
