import Foundation
import SpriteKit
import StickerStoriesKit
import UIKit

/// A pre-rendered frame animation that brings a sticker to life for a
/// moment: a sprite sheet the tooling drew from the sticker's own art
/// (`tools/author/stickeranim`), every frame registered on the part that
/// stays still, bordered and finished like the sticker, plus the mapping
/// that lays its rest frame exactly over the placed sticker.
///
/// Prototype: animations are found by file in the pack's `anims/` folder
/// (`<sticker>.<id>.json` next to its sheet), not through the manifest, and
/// only the developer gallery plays them. Stories cannot trigger them yet.
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
    var rows: Int { (count + columns - 1) / columns }

    /// Every animation in the pack's `anims/` folder, by file.
    static func available(in pack: LoadedPack) -> [StickerAnimation] {
        let directory = pack.baseURL.appendingPathComponent("anims")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StickerAnimation? in
                guard let data = try? Data(contentsOf: url),
                    let animation = try? decoder.decode(StickerAnimation.self, from: data),
                    animation.count > 0, animation.columns > 0, animation.hold.count == animation.count
                else { return nil }
                return animation
            }
            .sorted { $0.key < $1.key }
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

extension StickerNode {
    private static let liveNodeName = "live-animation"
    private static let liveFade: TimeInterval = 0.15

    /// Plays a live animation over this sticker: the frames crossfade in
    /// over the still art at the rest pose, play through, and crossfade
    /// back out. The child inherits the sticker's placement, so a pinched,
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
        let fade = min(Self.liveFade, animation.hold[0], animation.hold[animation.count - 1])
        var steps: [SKAction] = [
            .fadeIn(withDuration: fade),
            .wait(forDuration: animation.hold[0] - fade),
            // From here the frames leave the rest pose, so the still art
            // must not show through them.
            .run { [weak self] in self?.texture = nil },
        ]
        for index in 1..<max(1, animation.count - 1) {
            steps.append(show(index))
            steps.append(.wait(forDuration: animation.hold[index]))
        }
        // The last frame is the rest pose again: bring the still art back
        // underneath and fade the frames out over it.
        let restore = SKAction.run { [weak self] in
            self?.texture = stillTexture
            self?.liveStillTexture = nil
        }
        if animation.count > 1 {
            steps.append(restore)
            steps.append(show(animation.count - 1))
            steps.append(.wait(forDuration: animation.hold[animation.count - 1] - fade))
        } else {
            steps.append(restore)
        }
        steps.append(.fadeOut(withDuration: fade))
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
        if let liveStillTexture { texture = liveStillTexture }
        liveStillTexture = nil
        endLiveShadow()
    }
}
