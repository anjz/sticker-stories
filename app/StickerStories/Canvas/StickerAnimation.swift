import Foundation
import SpriteKit
import StickerStoriesKit
import UIKit

/// A pre-rendered frame animation that brings a sticker to life: a sprite
/// sheet the tooling drew from the sticker's own art
/// (`tools/author/stickeranim`), every frame registered on the part that
/// stays still, bordered and finished like the sticker, plus the mapping
/// that lays its rest frame exactly over the placed sticker. The sidecar
/// contract is `docs/pack-format.md`, "Live animations"; the manifest
/// declares each sticker's sidecars and this reads them leniently (a
/// sidecar that does not decode is skipped).
///
/// An **action** is a moment a story cues (`LiveTimeline`: whole, or held
/// on its pause frame and resumed); a **move** is how the character gets
/// about — its walk, hop, flight or sprout — played while a story brings
/// it into the scene (`EntrancePlan`). Both are loaded per story by
/// `LiveAnimationLoader`; the developer gallery plays any.
struct StickerAnimation: Decodable, Identifiable, Sendable {
    /// A box as fractions of its image, top-left origin.
    struct UnitBox: Decodable, Sendable {
        var x, y, width, height: Double
        var centre: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    }

    struct FrameSize: Decodable, Sendable {
        var width, height: Int
    }

    struct Pause: Decodable, Sendable {
        var frame: Int
    }

    struct FrameRange: Decodable, Sendable {
        var from, to: Int
    }

    enum Kind: String, Decodable, Sendable {
        case action, move
    }

    var id: String
    var sticker: String
    var kind: Kind
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
    /// An action's pause frame (`{snail:live hold}`).
    var pause: Pause?
    /// A move's loop, the way its frames travel, how far one loop carries
    /// it (sticker widths), whether the loop hops or flies, and where it
    /// comes in when a story brings it in this way.
    var loop: FrameRange?
    var facing: StageMove.Facing?
    var stride: Double?
    var hops: Bool?
    var flies: Bool?
    var on: [String]?
    /// An action that happens in one place: the features it needs (the
    /// woodpecker's tap: the trunks).
    var place: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, sticker, kind, sheet, frame, columns, count, rest, stickerBox, hold, pause, loop, facing, stride, hops,
            flies, on, place
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sticker = try c.decode(String.self, forKey: .sticker)
        // An unknown kind is not an action a story may cue by mistake.
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .action
        sheet = try c.decode(String.self, forKey: .sheet)
        frame = try c.decode(FrameSize.self, forKey: .frame)
        columns = try c.decode(Int.self, forKey: .columns)
        count = try c.decode(Int.self, forKey: .count)
        rest = try c.decode(UnitBox.self, forKey: .rest)
        stickerBox = try c.decode(UnitBox.self, forKey: .stickerBox)
        hold = try c.decode([Double].self, forKey: .hold)
        pause = try? c.decodeIfPresent(Pause.self, forKey: .pause)
        loop = try? c.decodeIfPresent(FrameRange.self, forKey: .loop)
        facing = try? c.decodeIfPresent(StageMove.Facing.self, forKey: .facing)
        stride = try? c.decodeIfPresent(Double.self, forKey: .stride)
        hops = try? c.decodeIfPresent(Bool.self, forKey: .hops)
        flies = try? c.decodeIfPresent(Bool.self, forKey: .flies)
        on = try? c.decodeIfPresent([String].self, forKey: .on)
        place = try? c.decodeIfPresent([String].self, forKey: .place)
    }

    var key: String { "\(sticker).\(id)" }
    var liveKey: LiveAnimationKey { LiveAnimationKey(stickerID: sticker, animationID: id) }
    var rows: Int { (count + columns - 1) / columns }

    /// The frame timing the timelines play (`LiveFrames`); a pause or loop
    /// outside the frames is dropped.
    var frames: LiveFrames {
        let validPause = pause.map(\.frame).flatMap { (1..<max(count - 1, 1)).contains($0) ? $0 : nil }
        let validLoop = loop.flatMap { $0.from >= 0 && $0.from <= $0.to && $0.to < count ? $0.from...$0.to : nil }
        return LiveFrames(holds: hold, pause: kind == .action ? validPause : nil, loop: kind == .move ? validLoop : nil)
    }

    /// The move as the stage planner needs it.
    var stageMove: StageMove? {
        guard kind == .move else { return nil }
        let timing = frames
        if timing.loop != nil {
            guard let stride, stride > 0 else { return nil }
            return StageMove(
                id: id, cycle: timing.loopDuration, stride: stride, hops: hops ?? false, flies: flies ?? false,
                on: on ?? [], facing: facing)
        }
        return StageMove(id: id, seconds: timing.duration(.move(travel: 0)) ?? 0)
    }

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

/// A live animation ready to play: its frames and their shadows as
/// textures, cut from the sheet and the shadow sheet once.
struct LoadedLiveAnimation {
    let animation: StickerAnimation
    let timing: LiveFrames
    let frames: [SKTexture]
    let shadowFrames: [SKTexture]?

    init(animation: StickerAnimation, sheet: SKTexture, shadowSheet: SKTexture?) {
        self.animation = animation
        timing = animation.frames
        frames = animation.frameTextures(from: sheet)
        shadowFrames = shadowSheet.map { animation.frameTextures(from: $0) }
    }
}

/// Loads the live animations a story is about to play. A sheet is a large
/// texture (width × height × 4 bytes), so a story loads only the ones its
/// triggers name for stickers on the canvas and the moves of the stickers
/// it brings in, off the main thread while the music lead-in plays, and
/// lets go of them when the story ends.
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
        var textures: [SKTexture] = []
        for (animation, sheet, shadow) in decoded {
            guard let sheet else {
                print("LiveAnimationLoader: could not decode \(animation.sheet)")
                continue
            }
            let sheetTexture = SKTexture(cgImage: sheet)
            let shadowTexture = shadow.map(SKTexture.init(cgImage:))
            textures.append(sheetTexture)
            if let shadowTexture { textures.append(shadowTexture) }
            loaded[animation.liveKey] = LoadedLiveAnimation(
                animation: animation, sheet: sheetTexture, shadowSheet: shadowTexture)
        }
        await withCheckedContinuation { continuation in
            SKTexture.preload(textures) { continuation.resume() }
        }
        return loaded
    }
}

extension StickerNode {
    private static let liveNodeName = "live-animation"
    private static let liveStillName = "live-still"

    /// Shows one moment of a live animation over this sticker
    /// (`LiveFrames.state`): its frame, and how opaque the frames and the
    /// still art under them are while one dissolves into the other. The
    /// frames fade in over the still art, which stays opaque underneath
    /// (two half-faded layers would let the background show through), and
    /// then the still art dissolves away beneath them, so the first frame
    /// need not be the sticker's exact drawing; the end is the same in
    /// reverse. The frames are a child, so a pinched, turned, mirrored or
    /// effect-driven sticker animates in place. With shadow frames the
    /// drop shadow follows the frames.
    func showLive(_ loaded: LoadedLiveAnimation, state: LiveFrameState) {
        if liveKey != loaded.animation.key {
            stopLive()
            beginLive(loaded)
        }
        guard let live = childNode(withName: Self.liveNodeName) as? SKSpriteNode else { return }
        let index = min(max(state.frame, 0), loaded.frames.count - 1)
        if live.texture !== loaded.frames[index] {
            live.texture = loaded.frames[index]
            if let shadows = loaded.shadowFrames { setLiveShadow(shadows[index]) }
        }
        live.alpha = CGFloat(state.liveAlpha)
        childNode(withName: Self.liveStillName)?.alpha = CGFloat(state.stillAlpha)
    }

    /// The live frames and the still art under them, while they are on
    /// show (the tint reaches them there; `setTint`).
    var liveSprites: [SKSpriteNode] {
        [Self.liveNodeName, Self.liveStillName].compactMap { childNode(withName: $0) as? SKSpriteNode }
    }

    private func beginLive(_ loaded: LoadedLiveAnimation) {
        let animation = loaded.animation
        guard let first = loaded.frames.first, let stillTexture = texture else { return }
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
        // The frames and the still art take over the sprite's tint; the
        // sprite, now without a texture, must stay clear or it draws a
        // solid box in its colour.
        for sprite in [live, still] {
            sprite.color = color
            sprite.colorBlendFactor = colorBlendFactor
        }
        texture = nil
        color = .clear
        colorBlendFactor = 0
        liveStillTexture = stillTexture
        liveKey = animation.key
        if let shadows = loaded.shadowFrames {
            beginLiveShadow(size: live.size, anchor: live.position)
            setLiveShadow(shadows[0])
        }
    }

    /// Ends a live animation: the still art is back at once (with the face
    /// it should show now — it may have changed while the frames played).
    func stopLive() {
        liveKey = nil
        guard let live = childNode(withName: Self.liveNodeName) else { return }
        live.removeFromParent()
        childNode(withName: Self.liveStillName)?.removeFromParent()
        if let liveStillTexture { texture = liveStillTexture }
        // The sprite's own art is back: a running tint returns to it.
        if let frames = live as? SKSpriteNode, frames.colorBlendFactor > 0 {
            color = frames.color
            colorBlendFactor = frames.colorBlendFactor
        }
        liveStillTexture = nil
        endLiveShadow()
    }
}
