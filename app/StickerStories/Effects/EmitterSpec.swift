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

    var color: RGBA { RGBA(hex: defaultColor) ?? .white }

    /// Which emitter each particle effect uses.
    static func name(for effect: EffectName) -> String? {
        switch effect {
        case .sparkle: "sparkles"
        case .puff: "smoke"
        case .hearts: "hearts"
        default: nil
        }
    }

    /// The shape of `emitters.json`: the three emitters (plus a `_comment`
    /// that is not decoded).
    private struct File: Decodable {
        var sparkles: EmitterSpec
        var smoke: EmitterSpec
        var hearts: EmitterSpec
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
            return ["sparkles": file.sparkles, "smoke": file.smoke, "hearts": file.hearts]
        } catch {
            assertionFailure("emitters.json undecodable: \(error)")
            return [:]
        }
    }()
}
