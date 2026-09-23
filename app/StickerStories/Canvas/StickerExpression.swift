import SpriteKit
import StickerStoriesKit
import UIKit

extension StickerNode {
    private static let faceGhostName = "face-ghost"

    /// Shows another face: the new texture replaces the sprite's and the
    /// old one fades out over it, so the change reads as the character's
    /// expression changing rather than a cut. A variant has exactly the
    /// sticker's outline (`tools/author/stickerart`), so nothing moves.
    /// During a live animation the frames are on show; the face waits
    /// underneath and is there when they hand back.
    func showFace(_ expression: String, texture newTexture: SKTexture, fade: TimeInterval = 0.25) {
        face = expression
        if liveStillTexture != nil {
            liveStillTexture = newTexture
            (childNode(withName: "live-still") as? SKSpriteNode)?.texture = newTexture
            return
        }
        childNode(withName: Self.faceGhostName)?.removeFromParent()
        if let old = texture, fade > 0 {
            let ghost = SKSpriteNode(texture: old, size: unscaledSize)
            ghost.name = Self.faceGhostName
            ghost.zPosition = 0.45  // over the sprite's own art, under a live animation's frames
            addChild(ghost)
            ghost.run(.sequence([.fadeOut(withDuration: fade), .removeFromParent()]))
        }
        texture = newTexture
    }
}

/// Loads the face variants a story will show (`ExpressionTimeline`) for the
/// stickers on the canvas, off the main thread as play starts. Each is a
/// sticker-sized texture; a story needs a handful, never the pack's
/// hundred, and they are let go of when the story ends.
enum ExpressionLoader {
    @MainActor
    static func load(_ wanted: [String: Set<String>], pack: LoadedPack) async -> [String: [String: SKTexture]] {
        var jobs: [(sticker: String, expression: String, url: URL)] = []
        for (stickerID, expressions) in wanted {
            guard let definition = pack.sticker(withID: stickerID) else { continue }
            for expression in expressions {
                if let path = definition.expressions[expression] {
                    jobs.append((stickerID, expression, pack.url(forAssetPath: path)))
                }
            }
        }
        let decoded = await withTaskGroup(of: (String, String, CGImage?).self) { group in
            for job in jobs {
                group.addTask { (job.sticker, job.expression, PackTextureLoader.decode(job.url)) }
            }
            var results: [(String, String, CGImage?)] = []
            for await result in group { results.append(result) }
            return results
        }
        var out: [String: [String: SKTexture]] = [:]
        for (stickerID, expression, image) in decoded {
            guard let image else {
                print("ExpressionLoader: could not decode \(stickerID).\(expression)")
                continue
            }
            out[stickerID, default: [:]][expression] = SKTexture(cgImage: image)
        }
        let textures = out.values.flatMap(\.values)
        await withCheckedContinuation { continuation in
            SKTexture.preload(textures) { continuation.resume() }
        }
        return out
    }
}
