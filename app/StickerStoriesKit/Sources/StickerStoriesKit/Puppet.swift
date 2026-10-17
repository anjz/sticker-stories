import Foundation

/// A sticker's puppet (`docs/pack-format.md`, "Puppets"): its drawing cut
/// into parts hanging on a skeleton, so an animation is keyframes the app
/// poses the parts with rather than drawn frames. Coordinates are the
/// sticker image's pixels at `size` (top-left origin, y down) with the
/// puppet at rest, lying over the sticker's own drawing; turns are degrees
/// clockwise. `tools/author/stickerrig` makes it.
public struct PuppetRig: Decodable, Sendable {
    public struct Part: Decodable, Sendable {
        /// Where the art is in the atlas, and its border silhouette (the
        /// art grown by the sticker's die-cut border), `pad` px larger on
        /// every side; atlas px, top-left origin, `[x, y, width, height]`.
        public var rect: [Double]
        public var border: [Double]
        public var pad: Double
    }

    public struct Bone: Decodable, Sendable {
        public var id: String
        public var parent: String?
        public var x: Double
        public var y: Double
    }

    /// A part as a slot shows it: the box it fills at rest (turned
    /// `rotate` about its centre), mirrored with `flip`, darkened by
    /// `shade`.
    public struct Attachment: Decodable, Sendable {
        public var part: String
        public var x, y, w, h: Double
        public var rotate: Double
        public var flip: Bool
        public var shade: Double

        private enum CodingKeys: String, CodingKey { case part, x, y, w, h, rotate, flip, shade }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            part = try c.decode(String.self, forKey: .part)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
            w = try c.decode(Double.self, forKey: .w)
            h = try c.decode(Double.self, forKey: .h)
            rotate = try c.decodeIfPresent(Double.self, forKey: .rotate) ?? 0
            flip = try c.decodeIfPresent(Bool.self, forKey: .flip) ?? false
            shade = try c.decodeIfPresent(Double.self, forKey: .shade) ?? 0
        }
    }

    public struct Slot: Decodable, Sendable {
        public var id: String
        public var bone: String
        public var `default`: String
        public var attachments: [String: Attachment]
    }

    /// The attachment that shows nothing (the far wing until it opens).
    public static let hidden = "none"

    public var sticker: String
    public var atlas: String
    public var size: Double
    public var parts: [String: Part]
    /// Each after its parent; the first is the root.
    public var bones: [Bone]
    /// Back to front.
    public var slots: [Slot]
    /// Expressions as attachments: `{"sleeping": {"eyeL": "closed"}}`.
    public var faces: [String: [String: String]]
    /// How it keeps alive while a story has it on show between animations.
    public var idle: Idle?

    /// The puppet at rest, alive: the bone that `breathe`s (a slow swell)
    /// and the attachments a blink shows, now and then, when the face does
    /// not set those slots itself.
    public struct Idle: Decodable, Sendable {
        public var breathe: String?
        public var blink: [String: String]?
    }

    private enum CodingKeys: String, CodingKey { case sticker, atlas, size, parts, bones, slots, faces, idle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sticker = try c.decode(String.self, forKey: .sticker)
        atlas = try c.decode(String.self, forKey: .atlas)
        size = try c.decode(Double.self, forKey: .size)
        parts = try c.decode([String: Part].self, forKey: .parts)
        bones = try c.decode([Bone].self, forKey: .bones)
        slots = try c.decode([Slot].self, forKey: .slots)
        faces = try c.decodeIfPresent([String: [String: String]].self, forKey: .faces) ?? [:]
        idle = try? c.decodeIfPresent(Idle.self, forKey: .idle)
    }

    /// Whether the rig hangs together: every bone after its parent, every
    /// slot on a bone showing parts the rig has.
    public var isWellFormed: Bool {
        var seen: Set<String> = []
        for (index, bone) in bones.enumerated() {
            if index == 0 ? bone.parent != nil : !seen.contains(bone.parent ?? "") { return false }
            seen.insert(bone.id)
        }
        return size > 0 && slots.allSatisfy { slot in
            seen.contains(slot.bone)
                && slot.attachments.values.allSatisfy { parts[$0.part].map { $0.rect.count == 4 && $0.border.count == 4 } ?? false }
        }
    }
}

/// A bone's change from rest: a turn (degrees clockwise), a shift (px, y
/// down) and a stretch.
public struct BonePose: Decodable, Equatable, Sendable {
    public var r, x, y, sx, sy: Double

    public static let rest = BonePose(r: 0, x: 0, y: 0, sx: 1, sy: 1)

    public init(r: Double = 0, x: Double = 0, y: Double = 0, sx: Double = 1, sy: Double = 1) {
        self.r = r
        self.x = x
        self.y = y
        self.sx = sx
        self.sy = sy
    }

    private enum CodingKeys: String, CodingKey { case r, x, y, sx, sy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        r = try c.decodeIfPresent(Double.self, forKey: .r) ?? 0
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        sx = try c.decodeIfPresent(Double.self, forKey: .sx) ?? 1
        sy = try c.decodeIfPresent(Double.self, forKey: .sy) ?? 1
    }

    public func mixed(with other: BonePose, _ t: Double) -> BonePose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return BonePose(r: mix(r, other.r), x: mix(x, other.x), y: mix(y, other.y), sx: mix(sx, other.sx), sy: mix(sy, other.sy))
    }
}

/// One keyframe of a puppet animation: bones not named stay at rest,
/// slots not named show the face's attachment or their default. `hold` is
/// the time from this pose to the next; `ease` how it gets there.
public struct PuppetKey: Decodable, Sendable {
    public enum Ease: String, Decodable, Sendable {
        case inOut, `in`, out, linear, step

        public func apply(_ t: Double) -> Double {
            let t = min(max(t, 0), 1)
            switch self {
            case .inOut: return t * t * (3 - 2 * t)
            case .in: return t * t
            case .out: return 1 - (1 - t) * (1 - t)
            case .linear: return t
            case .step: return t < 1 ? 0 : 1
            }
        }
    }

    public var hold: Double
    public var ease: Ease
    public var bones: [String: BonePose]
    public var slots: [String: String]

    public init(hold: Double, ease: Ease = .inOut, bones: [String: BonePose] = [:], slots: [String: String] = [:]) {
        self.hold = hold
        self.ease = ease
        self.bones = bones
        self.slots = slots
    }

    private enum CodingKeys: String, CodingKey { case hold, ease, bones, slots }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hold = try c.decode(Double.self, forKey: .hold)
        // An ease this build does not know moves smoothly.
        ease = (try? c.decodeIfPresent(Ease.self, forKey: .ease)) ?? .inOut
        bones = try c.decodeIfPresent([String: BonePose].self, forKey: .bones) ?? [:]
        slots = try c.decodeIfPresent([String: String].self, forKey: .slots) ?? [:]
    }
}

/// The puppet's whole pose at one moment: every bone, and what every slot
/// shows (`PuppetRig.hidden` for nothing).
public struct PuppetPose: Equatable, Sendable {
    public var bones: [String: BonePose]
    public var slots: [String: String]

    public init(bones: [String: BonePose], slots: [String: String]) {
        self.bones = bones
        self.slots = slots
    }

    /// The pose between two keys (`LiveTween`): bones eased from one to the
    /// other, slots as the first says — a swap happens on its key — then
    /// the face's, then each slot's default. `wrapping`: `to` is a loop's
    /// start after its end, where whole turns count for nothing, so a roll
    /// (0°, 120°, 240°, round again) keeps rolling on instead of unwinding.
    public static func between(
        _ from: PuppetKey, _ to: PuppetKey, progress: Double, face: String, rig: PuppetRig, wrapping: Bool = false
    ) -> PuppetPose {
        let t = from.ease.apply(progress)
        var bones: [String: BonePose] = [:]
        for bone in rig.bones {
            let a = from.bones[bone.id] ?? .rest
            var b = to.bones[bone.id] ?? .rest
            if wrapping { b.r += 360 * ((a.r - b.r) / 360).rounded() }
            bones[bone.id] = a.mixed(with: b, t)
        }
        return PuppetPose(bones: bones, slots: slots(for: from, face: face, rig: rig))
    }

    /// The rig at rest with a face on.
    public static func rest(face: String, rig: PuppetRig) -> PuppetPose {
        PuppetPose(
            bones: Dictionary(uniqueKeysWithValues: rig.bones.map { ($0.id, BonePose.rest) }),
            slots: slots(for: PuppetKey(hold: 0), face: face, rig: rig))
    }

    /// Seconds between breaths and between blinks, and how long a blink
    /// shows.
    public static let breath: TimeInterval = 3.2
    public static let blinkEvery: TimeInterval = 4.3
    public static let blinkFor: TimeInterval = 0.13

    /// The rig at rest, alive (`PuppetRig.idle`), `time` seconds into
    /// its idling: breathing and blinking.
    public static func idle(at time: TimeInterval, face: String, rig: PuppetRig) -> PuppetPose {
        var pose = rest(face: face, rig: rig)
        guard let idle = rig.idle else { return pose }
        if let bone = idle.breathe, pose.bones[bone] != nil {
            let swell = sin(time / breath * 2 * .pi)
            pose.bones[bone] = BonePose(sx: 1 - 0.006 * swell, sy: 1 + 0.012 * swell)
        }
        let faceSlots = rig.faces[face] ?? [:]
        if let blink = idle.blink, blink.keys.allSatisfy({ faceSlots[$0] == nil }),
            time.truncatingRemainder(dividingBy: blinkEvery) > blinkEvery - blinkFor
        {
            for (slot, attachment) in blink { pose.slots[slot] = attachment }
        }
        return pose
    }

    private static func slots(for key: PuppetKey, face: String, rig: PuppetRig) -> [String: String] {
        let faceSlots = rig.faces[face] ?? [:]
        return Dictionary(uniqueKeysWithValues: rig.slots.map { slot in
            (slot.id, key.slots[slot.id] ?? faceSlots[slot.id] ?? slot.default)
        })
    }

    /// This pose with `wings` — those bones, every bone hanging on them,
    /// and the slots they carry — as `flight` has them: a flyer up in the
    /// air keeps its wings going whatever else it does
    /// (`docs/pack-format.md`, "Live animations", `wings`).
    public func flying(_ wings: [String], as flight: PuppetPose, rig: PuppetRig) -> PuppetPose {
        guard !wings.isEmpty else { return self }
        var kept = Set(wings)
        // Bones come after their parents.
        for bone in rig.bones where bone.parent.map(kept.contains) == true { kept.insert(bone.id) }
        var pose = self
        for id in kept { pose.bones[id] = flight.bones[id] ?? pose.bones[id] }
        for slot in rig.slots where kept.contains(slot.bone) {
            if let shown = flight.slots[slot.id] { pose.slots[slot.id] = shown }
        }
        return pose
    }

    /// This pose part of the way to another, for smoothing over a jump
    /// (a move's loop cut short as the character arrives).
    public func mixed(with other: PuppetPose, _ t: Double) -> PuppetPose {
        var bones = self.bones
        for (id, pose) in other.bones { bones[id] = (bones[id] ?? .rest).mixed(with: pose, t) }
        return PuppetPose(bones: bones, slots: t < 0.5 ? slots : other.slots)
    }
}

extension PuppetRig {
    /// The slots a face sets — every slot any of its faces swaps (the
    /// eyes, the mouth, the brows) and those its blink does.
    public var faceSlots: Set<String> {
        Set(faces.values.flatMap(\.keys)).union(idle?.blink?.keys.map { $0 } ?? [])
    }
}

extension PuppetPose {
    /// This pose wearing `action`'s face: the face slots
    /// (`PuppetRig.faceSlots`) as the action shows them, wherever this
    /// pose shows them at all — the surfer laughing as he paddles on,
    /// his body still paddling. The other way round from `flying`: the
    /// move keeps the body, the action gives the face. A slot this pose
    /// hides (a back view's eyes) stays hidden.
    public func wearingFace(of action: PuppetPose, rig: PuppetRig) -> PuppetPose {
        var pose = self
        for slot in rig.faceSlots where slots[slot] != PuppetRig.hidden {
            if let shown = action.slots[slot] { pose.slots[slot] = shown }
        }
        return pose
    }
}
