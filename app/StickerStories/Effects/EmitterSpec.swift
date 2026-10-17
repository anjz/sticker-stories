import Foundation
import StickerStoriesKit

/// One emitter's tuning, decoded from `emitters.json`. See that file for the
/// conventions. These are the only knobs that exist; content never sees them.
struct EmitterSpec: Decodable {
    struct Varied: Decodable {
        var value: Double
        var variance: Double
    }
    struct Angle: Decodable {
        var value: Double
        var range: Double
    }
    struct Scale: Decodable {
        var start: Double
        var end: Double
        var variance: Double
    }
    struct Alpha: Decodable {
        var start: Double
        var peak: Double
        var end: Double
        var peakAt: Double
    }

    var texture: String
    var blend: String
    var birthRate: Double
    var lifetime: Varied
    var speed: Varied
    var emissionAngle: Angle
    var gravity: [Double]
    var positionSpread: [Double]
    var scale: Scale
    var alpha: Alpha
    var rotationSpeed: Double
    var defaultColor: String
    var maxParticles: Int
    var inFront: Bool
    /// Tuned for Earth: gravity scales with the pack world's and particles
    /// live longer where it is weak (`PackWorld`).
    var worldGravity: Bool?
    /// Drawn as a pair: itself and its mirror image across the vertical
    /// (angle and sideways gravity flipped) — a cloud billowing both ways.
    var mirrored: Bool?
    /// Emitters that fire along with it, at the same spot, intensity and
    /// colour (the dust cloud's grains).
    var with: [String]?
    /// Each particle sways side to side as it goes: amplitude in points at
    /// the reference height, seconds per sway (bubbles rising).
    var wobble: [Double]?

    var color: RGBA { RGBA(hex: defaultColor) ?? .white }

    /// Which emitter each particle effect uses.
    static func name(for effect: EffectName) -> String? {
        switch effect {
        case .sparkle: "sparkles"
        case .hearts: "hearts"
        case .dustPuff: "dust"
        case .spray: "spray"
        case .sparks: "sparks"
        case .bubblePuff: "bubbles"
        default: nil
        }
    }

    /// The shape of `emitters.json`: the emitters (plus a `_comment` that
    /// is not decoded).
    private struct File: Decodable {
        var sparkles: EmitterSpec
        var hearts: EmitterSpec
        var dust: EmitterSpec
        var dustGrains: EmitterSpec
        var spray: EmitterSpec
        var sparks: EmitterSpec
        var bubbles: EmitterSpec
    }

    /// All emitters from the bundled data file, keyed by name.
    static let bundled: [String: EmitterSpec] = {
        guard let url = Bundle.main.url(forResource: "emitters", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("emitters.json missing from the app bundle")
            return [:]
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return ["sparkles": file.sparkles, "hearts": file.hearts, "dust": file.dust, "dustGrains": file.dustGrains, "spray": file.spray, "sparks": file.sparks, "bubbles": file.bubbles]
        } catch {
            assertionFailure("emitters.json undecodable: \(error)")
            return [:]
        }
    }()
}
