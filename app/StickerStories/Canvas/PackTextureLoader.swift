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
    /// The scene's layers (`SceneLayer`), far to near, each cropped to the
    /// part that is painted.
    var layers: [LayerTextures] = []
    /// Where each sticker's drawing sits in its image (fractions, origin
    /// bottom-left) — measured for a pack with a space, whose sizes are the
    /// drawings' (`SceneSpace.sizes`).
    var drawings: [String: CGRect] = [:]
    /// What each plane in front of the background hides — "foreground" and
    /// the layers' ids — on the base art and the wide art, for a pack with
    /// a space (`StageWorld.covers`).
    var covers: [String: (base: OpaqueGrid?, wide: OpaqueGrid?)] = [:]
}

/// A scene layer's painted part, on the base art and on the wide art.
struct LayerTextures {
    struct Piece {
        var texture: SKTexture
        /// Where the piece sits on its art, in fractions, origin bottom-left.
        var frame: CGRect
    }

    var id: String
    var base: Piece
    var wide: Piece?
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
        for layer in pack.manifest.layers {
            paths["layer:" + layer.id] = layer.image
            if let wide = layer.imageWide { paths["layer-wide:" + layer.id] = wide }
        }

        // A layer is cropped to its painted part (most of a plane is
        // empty); with a space, every sticker's drawing is measured.
        let measureDrawings = pack.manifest.space != nil
        let (images, bounds, grids) = await withTaskGroup(of: (String, CGImage?, CGRect?, OpaqueGrid?).self) { group in
            for (key, path) in paths {
                let url = pack.url(forAssetPath: path)
                let isLayer = key.hasPrefix("layer")
                let measure = isLayer || (measureDrawings && key.hasPrefix("sticker:"))
                let gridded = measureDrawings && (isLayer || key.hasPrefix("foreground"))
                group.addTask {
                    guard let image = decode(url) else { return (key, nil, nil, nil) }
                    let grid = gridded ? OpaqueGrid.of(image) : nil
                    guard measure else { return (key, image, nil, grid) }
                    guard let box = OpaqueBounds.of(image, maxSide: isLayer ? 1024 : 512) else { return (key, image, nil, grid) }
                    if isLayer {
                        let (cropped, frame) = crop(image, to: box)
                        return (key, cropped, frame, grid)
                    }
                    return (key, image, box, grid)
                }
            }
            var decoded: [String: CGImage] = [:]
            var measured: [String: CGRect] = [:]
            var grids: [String: OpaqueGrid] = [:]
            for await (key, image, box, grid) in group {
                if let image { decoded[key] = image }
                if let box { measured[key] = box }
                if let grid { grids[key] = grid }
            }
            return (decoded, measured, grids)
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
            textures.drawings[sticker.id] = bounds["sticker:" + sticker.id]
        }
        for layer in pack.manifest.layers {
            func piece(_ key: String) -> LayerTextures.Piece? {
                guard let image = images[key], let frame = bounds[key] else { return nil }
                return .init(texture: SKTexture(cgImage: image), frame: frame)
            }
            if let base = piece("layer:" + layer.id) {
                textures.layers.append(.init(id: layer.id, base: base, wide: piece("layer-wide:" + layer.id)))
            }
        }

        if measureDrawings {
            textures.covers[SceneSpace.Layer.foreground] = (grids["foreground"], grids["foreground-wide"])
            for layer in pack.manifest.layers {
                textures.covers[layer.id] = (grids["layer:" + layer.id], grids["layer-wide:" + layer.id])
            }
        }

        var all = Array(textures.stickers.values)
        all += textures.layers.flatMap { [$0.base.texture, $0.wide?.texture].compactMap { $0 } }
        for texture in [textures.background, textures.foreground, textures.wide?.background, textures.wide?.foreground] {
            if let texture { all.append(texture) }
        }
        await withCheckedContinuation { continuation in
            SKTexture.preload(all) { continuation.resume() }
        }
        return textures
    }

    /// The part of an image inside a box (fractions, origin bottom-left),
    /// a couple of pixels wider for what measuring it rounded away, and
    /// where that part sits.
    nonisolated static func crop(_ image: CGImage, to box: CGRect) -> (CGImage, CGRect) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // CGImage pixels run from the top.
        let pixels = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
            .insetBy(dx: -2, dy: -2).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        // Copied into a bitmap of its own: a cropped image keeps the whole
        // one alive behind it.
        guard let cropped = image.cropping(to: pixels),
            let context = CGContext(
                data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                // Its own colours, exactly: the layer must match the art around it.
                space: cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (image, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let copy = context.makeImage() else { return (image, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        return (copy, CGRect(x: pixels.minX / w, y: 1 - pixels.maxY / h, width: pixels.width / w, height: pixels.height / h))
    }

    /// Decodes one image into a plain bitmap on a background thread with
    /// ImageIO (no UIKit decompressor involved).
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
