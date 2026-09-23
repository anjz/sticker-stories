import Foundation
import SpriteKit
import StickerStoriesKit
import UIKit

/// A pre-rendered frame animation that brings a sticker to life for a
/// moment: a sprite sheet the tooling drew from the sticker's own art
/// (`tools/author/stickeranim`), every frame registered on the part that
/// stays still, bordered and finished like the sticker, plus the mapping
/// that lays its rest frame exactly over the placed sticker. The sidecar
/// contract is `docs/pack-format.md`, "Live animations"; the manifest
/// declares each sticker's sidecars and this reads them leniently (a
/// sidecar that does not decode is skipped).
///
/// Stories play them from their effects sidecar (`LiveAnimationTrigger`,
/// preloaded by `LiveAnimationLoader`); the developer gallery plays any.
struct StickerAnimation: Decodable, Identifiable, Sendable {
    /// A box as fractions of its image, top-left origin.
    struct UnitBox: Decodable, Sendable {
        var x, y, width, height: Double
        var centre: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    }

    struct FrameSize: Decodable, Sendable {
        var width, height: Int
    }

    var id: String
    var sticker: String
    /// Pack-relative path of the sheet PNG: `columns` frames per row,
    /// `count` frames read left to right, top to bottom.
    var sheet: String
    var frame: FrameSize
    var columns: Int
    var count: Int
    /// The first frame's bordered art within a frame, and the same art
    /// within the sticker image: the frames are scaled and offset so that
    /// `rest` lands on `stickerBox`.
    var rest: UnitBox
    var stickerBox: UnitBox
    /// Seconds each frame shows, one per frame.
    var hold: [Double]

    var key: String { "\(sticker).\(id)" }
    var liveKey: LiveAnimationKey { LiveAnimationKey(stickerID: sticker, animationID: id) }
    var rows: Int { (count + columns - 1) / columns }

    /// Every animation the pack's manifest declares, in manifest order.
    static func available(in pack: LoadedPack) -> [StickerAnimation] {
        let decoder = JSONDecoder()
        return pack.manifest.stickers.flatMap { sticker in
            sticker.animations.compactMap { path -> StickerAnimation? in
                guard let data = try? Data(contentsOf: pack.url(forAssetPath: path)),
                    let animation = try? decoder.decode(StickerAnimation.self, from: data),
                    animation.sticker == sticker.id, animation.count > 0, animation.columns > 0,
                    animation.hold.count == animation.count
                else {
                    print("StickerAnimation: skipping \(path) (undecodable or not \(sticker.id)'s)")
                    return nil
                }
                return animation
            }
        }
    }

    /// One `SKTexture` per frame, cut from the sheet.
    func frameTextures(from sheet: SKTexture) -> [SKTexture] {
        let width = 1 / CGFloat(columns), height = 1 / CGFloat(rows)
        return (0..<count).map { index in
            let column = index % columns, row = index / columns
            // Texture rects are unit, origin bottom-left; the sheet's first row is at the top.
            let rect = CGRect(x: CGFloat(column) * width, y: 1 - CGFloat(row + 1) * height, width: width, height: height)
            return SKTexture(rect: rect, in: sheet)
        }
    }
}

/// A live animation ready to play: its sheet and shadow sheet as textures.
struct LoadedLiveAnimation {
    let animation: StickerAnimation
    let sheet: SKTexture
    let shadowSheet: SKTexture?
}

/// Loads the live animations a story is about to play. A sheet is a large
/// texture (width × height × 4 bytes, ~35 MB for 16 frames), so a story
/// loads only the ones its triggers name for stickers on the canvas, off
/// the main thread while the music lead-in plays, and lets go of them when
/// the story ends.
enum LiveAnimationLoader {
    @MainActor
    static func load(
        _ keys: Set<LiveAnimationKey>, from available: [StickerAnimation], pack: LoadedPack
    ) async -> [LiveAnimationKey: LoadedLiveAnimation] {
        let wanted = available.filter { keys.contains($0.liveKey) }
        let decoded = await withTaskGroup(of: (StickerAnimation, CGImage?, CGImage?).self) { group in
            for animation in wanted {
                let url = pack.url(forAssetPath: animation.sheet)
                group.addTask {
                    guard let sheet = PackTextureLoader.decode(url) else { return (animation, nil, nil) }
                    return (animation, sheet, StickerShadowCache.shadowSheetImage(for: animation, sheet: sheet))
                }
            }
            var results: [(StickerAnimation, CGImage?, CGImage?)] = []
            for await result in group { results.append(result) }
            return results
        }
        var loaded: [LiveAnimationKey: LoadedLiveAnimation] = [:]
        for (animation, sheet, shadow) in decoded {
            guard let sheet else {
                print("LiveAnimationLoader: could not decode \(animation.sheet)")
                continue
            }
            loaded[animation.liveKey] = LoadedLiveAnimation(
                animation: animation, sheet: SKTexture(cgImage: sheet), shadowSheet: shadow.map(SKTexture.init(cgImage:)))
        }
        let textures = loaded.values.flatMap { [$0.sheet] + ($0.shadowSheet.map { [$0] } ?? []) }
        await withCheckedContinuation { continuation in
            SKTexture.preload(textures) { continuation.resume() }
        }
        return loaded
    }
}

extension StickerNode {
    private static let liveNodeName = "live-animation"
    private static let liveStillName = "live-still"
    /// How long the frames take to fade in over the still art (and out at
    /// the end), capped at two thirds of the first and last frames' holds;
    /// the rest of those holds dissolves the still art out underneath (and
    /// back in). Long enough that where the first frame is the generator's
    /// drawing rather than the sticker's own art, the difference dissolves
    /// instead of popping.
    private static let liveFade: TimeInterval = 0.3

    /// Plays a live animation over this sticker. At the rest pose the frames
    /// fade in over the still art, which stays opaque underneath (two
    /// half-faded layers would let the background show through), and then
    /// the still art dissolves away beneath them, so the first frame need
    /// not be the sticker's exact drawing: where the two differ, the edge
    /// dissolves. The frames play through and the same happens in reverse. The child inherits the sticker's placement, so a pinched,
    /// turned or effect-driven sticker animates in place. With a shadow
    /// sheet (`StickerShadowCache.shadowSheet`) the drop shadow follows
    /// the frames; without one it keeps the still art's silhouette.
    func playLive(
        _ animation: StickerAnimation, sheet: SKTexture, shadowSheet: SKTexture? = nil,
        completion: (() -> Void)? = nil
    ) {
        stopLive()
        let frames = animation.frameTextures(from: sheet)
        let shadows = shadowSheet.map { animation.frameTextures(from: $0) }
        guard let first = frames.first, let stillTexture = texture else { return }

        // Scale the frame so the rest art is as wide as the sticker's art,
        // then offset it so the two arts' centres coincide (in the sprite's
        // own, unscaled space, y up).
        let base = unscaledSize
        let frameW = CGFloat(animation.frame.width), frameH = CGFloat(animation.frame.height)
        let scale = (animation.stickerBox.width * base.width) / (animation.rest.width * frameW)
        let restCentre = animation.rest.centre, stickerCentre = animation.stickerBox.centre
        let live = SKSpriteNode(texture: first)
        live.name = Self.liveNodeName
        live.size = CGSize(width: frameW * scale, height: frameH * scale)
        live.position = CGPoint(
            x: (stickerCentre.x - 0.5) * base.width - (restCentre.x - 0.5) * frameW * scale,
            y: (0.5 - stickerCentre.y) * base.height - (0.5 - restCentre.y) * frameH * scale)
        live.zPosition = 0.5  // over the sprite's own art, under nothing else of the node's
        live.alpha = 0
        addChild(live)
        // The still art moves to a child of its own for the crossfade: a
        // node's own texture cannot fade separately from its children.
        let still = SKSpriteNode(texture: stillTexture, size: base)
        still.name = Self.liveStillName
        still.zPosition = 0.4
        addChild(still)
        texture = nil
        if let shadows {
            beginLiveShadow(size: live.size, anchor: live.position)
            setLiveShadow(shadows[0])
        }

        let show: (Int) -> SKAction = { [weak self, weak live] index in
            .run {
                live?.texture = frames[index]
                if let shadows { self?.setLiveShadow(shadows[index]) }
            }
        }
        let firstHold = animation.hold[0], lastHold = animation.hold[animation.count - 1]
        let fade = min(Self.liveFade, min(firstHold, lastHold) * 2 / 3)
        let stillAction: (SKAction) -> SKAction = { [weak still] action in
            .run { still?.run(action) }
        }
        var steps: [SKAction] = [
            .fadeIn(withDuration: fade),
            stillAction(.fadeOut(withDuration: firstHold - fade)),
            .wait(forDuration: firstHold - fade),
        ]
        for index in 1..<max(1, animation.count - 1) {
            steps.append(show(index))
            steps.append(.wait(forDuration: animation.hold[index]))
        }
        // The last frame is the rest pose again: crossfade back to the still
        // art, then hand it back to the sprite itself.
        let restore = SKAction.run { [weak self] in
            // The face may have changed while the frames played.
            self?.texture = self?.liveStillTexture ?? stillTexture
            self?.liveStillTexture = nil
            self?.childNode(withName: Self.liveStillName)?.removeFromParent()
        }
        if animation.count > 1 {
            steps.append(show(animation.count - 1))
        }
        steps.append(stillAction(.fadeIn(withDuration: lastHold - fade)))
        steps.append(.wait(forDuration: lastHold - fade))
        steps.append(.fadeOut(withDuration: fade))
        steps.append(restore)
        steps.append(.run { [weak self] in self?.endLiveShadow() })
        if let completion {
            // Before the removal: a removed node runs no more actions.
            steps.append(.run(completion))
        }
        steps.append(.removeFromParent())
        live.run(.sequence(steps), withKey: Self.liveNodeName)
        liveStillTexture = stillTexture
    }

    /// Cuts a live animation short: the still art is back at once.
    func stopLive() {
        guard let live = childNode(withName: Self.liveNodeName) else { return }
        live.removeAllActions()
        live.removeFromParent()
        childNode(withName: Self.liveStillName)?.removeFromParent()
        if let liveStillTexture { texture = liveStillTexture }
        liveStillTexture = nil
        endLiveShadow()
    }
}
