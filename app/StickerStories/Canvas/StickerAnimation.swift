import Foundation
import SpriteKit
import StickerStoriesKit
import UIKit

/// A moment of a sticker's life, played on its puppet: keyframes the
/// tooling (`tools/author/stickerrig`) wrote for the sticker's drawing cut
/// into parts on a skeleton, plus where the drawing sits in the sticker's
/// image. The sidecar contract is `docs/pack-format.md`, "Live
/// animations" and "Puppets"; the manifest declares each sticker's
/// sidecars and this reads them leniently (a sidecar that does not decode
/// is skipped). The puppet's keys are the animation's frames: `pause`,
/// `loop` and `particles` count keys.
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
    /// The sticker's drawing within its image.
    var stickerBox: UnitBox
    /// An action's pause frame (`{snail:live hold}`).
    var pause: Pause?
    /// A move's loop, the way its frames travel, how far one loop carries
    /// it (sticker widths), whether the loop hops or flies, where it
    /// comes in when a story brings it in this way, and whether it keeps
    /// going once it is there (the surfer out on the waves).
    var loop: FrameRange?
    var facing: StageMove.Facing?
    var stride: Double?
    var hops: Bool?
    var flies: Bool?
    /// The flight can hold still in the air (`StageMove.hovers`).
    var hovers: Bool?
    /// A move's features it lands on (above); an action's, the places it
    /// is done in (riding a wave: the sea) — in water a move keeps it in,
    /// any other action shows only its face (`StageActing.keepsToFace`).
    var on: [String]?
    /// A move's other move played while it goes away from the viewer
    /// (`StageMove.away`).
    var away: String?
    /// The way an action faces on screen while it plays (riding a wave:
    /// right); the whole puppet is mirrored to it and back
    /// (`StageActing.facing`). A move's: the way it faces whichever way it
    /// goes (`StageMove.faces`).
    var faces: StageMove.Facing?
    /// A move's other move played while it rests where it stays
    /// (`StageMove.rest`).
    var rest: String?
    /// How deep it floats in water among `on` (`StageMove.waterline`).
    var waterline: Double?
    var stays: Bool?
    /// An action that happens in one place: the features it needs (the
    /// woodpecker's tap: the trunks).
    var place: [String]?
    /// What an action holds out in its paused frame, by name, where it is
    /// then (fractions of the image, top-left origin, like `stickerBox`):
    /// a flyer a story sends to it goes up beside it (`GoTrigger.held`).
    var props: [String: Point]?
    /// A small, gentle action it plays now and then on its own while a
    /// story leaves it be (`IdleLife`).
    var idle: Bool
    /// Particle bursts the keys fire as they come on show (a landing's
    /// dust, a splash): stickers never draw particles themselves.
    var particles: [ParticleCue]
    /// Sticker effects the keys start on the character as they come on
    /// show (the wave behind a surfer standing up), unless one is running.
    var effects: [EffectCue]
    /// How an action done in the water carries it towards the shore while
    /// it plays (riding a wave in; `StageAction.Drift`).
    var drift: StageAction.Drift?
    /// The animation as keyframes for the sticker's puppet
    /// (`docs/pack-format.md`, "Puppets"), at least two.
    var puppet: Puppet

    struct Puppet: Decodable, Sendable {
        var rig: String
        var keys: [PuppetKey]
        /// The bones a flight keeps going while the character does
        /// anything else in the air (`PuppetPose.flying`).
        var wings: [String]?
    }

    /// One burst: when `frame` first shows, `effect` (`dust-puff`, `spray`,
    /// `sparks`, `bubble-puff`) from the point `x`, `y` of the sticker's image (fractions,
    /// top-left origin, like `stickerBox`).
    struct Point: Decodable, Equatable {
        var x: Double
        var y: Double
    }

    struct EffectCue: Decodable, Equatable {
        var frame: Int
        var effect: EffectName
        var intensity: Double?
    }

    struct ParticleCue: Decodable, Equatable {
        var frame: Int
        var effect: EffectName
        var x: Double
        var y: Double
        var intensity: Double?
        var color: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, sticker, kind, stickerBox, pause, loop, facing, stride, hops, flies, hovers, on, stays, waterline,
            place, idle, particles, puppet, away, faces, props, rest, effects, drift
    }

    /// An effect cue that decodes or is skipped, like a particle cue.
    private struct LenientEffect: Decodable {
        var cue: EffectCue?
        init(from decoder: any Decoder) throws { cue = try? EffectCue(from: decoder) }
    }

    /// A particle cue that decodes or is skipped (an effect this build
    /// does not know), never failing the animation.
    private struct LenientCue: Decodable {
        var cue: ParticleCue?
        init(from decoder: any Decoder) throws { cue = try? ParticleCue(from: decoder) }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sticker = try c.decode(String.self, forKey: .sticker)
        // An unknown kind is not an action a story may cue by mistake.
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .action
        stickerBox = try c.decode(UnitBox.self, forKey: .stickerBox)
        puppet = try c.decode(Puppet.self, forKey: .puppet)
        guard puppet.keys.count >= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .puppet, in: c, debugDescription: "fewer than two puppet keys")
        }
        pause = try? c.decodeIfPresent(Pause.self, forKey: .pause)
        loop = try? c.decodeIfPresent(FrameRange.self, forKey: .loop)
        facing = try? c.decodeIfPresent(StageMove.Facing.self, forKey: .facing)
        stride = try? c.decodeIfPresent(Double.self, forKey: .stride)
        hops = try? c.decodeIfPresent(Bool.self, forKey: .hops)
        flies = try? c.decodeIfPresent(Bool.self, forKey: .flies)
        hovers = try? c.decodeIfPresent(Bool.self, forKey: .hovers)
        on = try? c.decodeIfPresent([String].self, forKey: .on)
        away = kind == .move ? (try? c.decodeIfPresent(String.self, forKey: .away)) ?? nil : nil
        faces = (try? c.decodeIfPresent(StageMove.Facing.self, forKey: .faces)) ?? nil
        rest = kind == .move ? (try? c.decodeIfPresent(String.self, forKey: .rest)) ?? nil : nil
        stays = try? c.decodeIfPresent(Bool.self, forKey: .stays)
        waterline = try? c.decodeIfPresent(Double.self, forKey: .waterline)
        place = try? c.decodeIfPresent([String].self, forKey: .place)
        props = kind == .action ? (try? c.decodeIfPresent([String: Point].self, forKey: .props)) ?? nil : nil
        idle = kind == .action && ((try? c.decodeIfPresent(Bool.self, forKey: .idle)) ?? nil) == true
        let cues = (try? c.decodeIfPresent([LenientCue].self, forKey: .particles)) ?? nil
        let frames = puppet.keys.count
        particles = (cues ?? []).compactMap(\.cue).filter { $0.effect.firesFromFrames && $0.frame >= 0 && $0.frame < frames }
        let started = (try? c.decodeIfPresent([LenientEffect].self, forKey: .effects)) ?? nil
        effects = (started ?? []).compactMap(\.cue).filter { $0.effect == .surfWave && $0.frame >= 0 && $0.frame < frames }
        drift = kind == .action ? (try? c.decodeIfPresent(StageAction.Drift.self, forKey: .drift)) ?? nil : nil
    }

    var key: String { "\(sticker).\(id)" }
    var liveKey: LiveAnimationKey { LiveAnimationKey(stickerID: sticker, animationID: id) }

    /// The frame timing the timelines play (`LiveFrames`): each key's hold
    /// is the time from it to the next. A pause or loop outside the keys is
    /// dropped.
    var frames: LiveFrames {
        let count = puppet.keys.count
        let validPause = pause.map(\.frame).flatMap { (1..<max(count - 1, 1)).contains($0) ? $0 : nil }
        let validLoop = loop.flatMap { $0.from >= 0 && $0.from <= $0.to && $0.to < count ? $0.from...$0.to : nil }
        return LiveFrames(
            holds: puppet.keys.map(\.hold), pause: kind == .action ? validPause : nil, loop: kind == .move ? validLoop : nil)
    }

    /// The move as the stage planner needs it.
    var stageMove: StageMove? {
        guard kind == .move else { return nil }
        let timing = frames
        if timing.loop != nil {
            guard let stride, stride > 0 else { return nil }
            return StageMove(
                id: id, cycle: timing.loopDuration, stride: stride, hops: hops ?? false, flies: flies ?? false,
                hovers: hovers ?? false, on: on ?? [], stays: stays ?? false,
                waterline: min(max(waterline ?? 0, 0), 0.95), facing: facing, away: away,
                tail: timing.loop.map { timing.holds.dropFirst($0.upperBound + 1).reduce(0, +) } ?? 0, faces: faces, rest: rest)
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
                    animation.sticker == sticker.id
                else {
                    print("StickerAnimation: skipping \(path) (undecodable or not \(sticker.id)'s)")
                    return nil
                }
                return animation
            }
        }
    }
}

/// A live animation ready to play: its timing and the puppet that plays it.
struct LoadedLiveAnimation {
    let animation: StickerAnimation
    let timing: LiveFrames
    let puppet: LoadedPuppet

    init(animation: StickerAnimation, puppet: LoadedPuppet) {
        self.animation = animation
        timing = animation.frames
        self.puppet = puppet
    }
}

/// Loads the live animations a story is about to play: only the ones its
/// triggers name for stickers on the canvas and the moves of the stickers
/// it brings in, off the main thread while the music lead-in plays; the
/// story lets go of them when it ends. Each rig and its atlas is read
/// once, however many of its animations the story plays.
enum LiveAnimationLoader {
    @MainActor
    static func load(
        _ keys: Set<LiveAnimationKey>, from available: [StickerAnimation], pack: LoadedPack
    ) async -> [LiveAnimationKey: LoadedLiveAnimation] {
        let wanted = available.filter { keys.contains($0.liveKey) }
        let rigPaths = Set(wanted.map(\.puppet.rig))
        let rigs = await withTaskGroup(of: (String, PuppetRig?, CGImage?).self) { group in
            for path in rigPaths {
                let url = pack.url(forAssetPath: path)
                group.addTask {
                    guard let data = try? Data(contentsOf: url),
                        let rig = try? JSONDecoder().decode(PuppetRig.self, from: data), rig.isWellFormed
                    else { return (path, nil, nil) }
                    return (path, rig, PackTextureLoader.decode(pack.url(forAssetPath: rig.atlas)))
                }
            }
            var results: [String: (PuppetRig, CGImage)] = [:]
            for await (path, rig, atlas) in group {
                if let rig, let atlas { results[path] = (rig, atlas) } else { print("LiveAnimationLoader: could not load the puppet \(path)") }
            }
            return results
        }
        let atlases = rigs.mapValues { SKTexture(cgImage: $0.1) }
        await withCheckedContinuation { continuation in
            SKTexture.preload(Array(atlases.values)) { continuation.resume() }
        }
        var loaded: [LiveAnimationKey: LoadedLiveAnimation] = [:]
        for animation in wanted {
            guard let (rig, _) = rigs[animation.puppet.rig], let atlas = atlases[animation.puppet.rig] else { continue }
            loaded[animation.liveKey] = LoadedLiveAnimation(
                animation: animation, puppet: LoadedPuppet(rig: rig, keys: animation.puppet.keys, atlas: atlas))
        }
        return loaded
    }
}

extension StickerNode {
    static let liveNodeName = "live-animation"
    static let liveStillName = "live-still"

    /// Shows one moment of a live animation over this sticker
    /// (`LiveFrames.state`): its puppet's pose, and how opaque the puppet
    /// and the still art under it are while one dissolves into the other
    /// (`beginPuppet`, `showPuppet`). The puppet is a child, so a pinched,
    /// turned, mirrored or effect-driven sticker animates in place.
    /// Returns the frame when it is a new one (it has just come on show),
    /// for what fires on a frame (`StickerAnimation.particles`).
    @discardableResult
    func showLive(
        _ loaded: LoadedLiveAnimation, state: LiveFrameState, tween: LiveTween? = nil, wings: PuppetNode.Wings? = nil,
        faceOver: PuppetNode.FaceOver? = nil
    ) -> Int? {
        if liveKey != loaded.animation.key, !continuePuppet(loaded) {
            stopLive()
            beginPuppet(loaded.puppet, key: loaded.animation.key)
            liveFrame = nil
        }
        return showPuppet(state: state, tween: tween, wings: wings, faceOver: faceOver)
    }

    /// The still art under a live animation, while one is on show (the
    /// tint reaches it there; `setTint`).
    var liveSprites: [SKSpriteNode] {
        [childNode(withName: Self.liveStillName) as? SKSpriteNode].compactMap { $0 }
    }

    /// Ends a live animation: the still art is back at once (with the face
    /// it should show now — it may have changed while the puppet played).
    func stopLive() {
        liveKey = nil
        liveFrame = nil
        stopPuppet()
    }
}
