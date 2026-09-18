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

    /// All emitters from the bundled data file, keyed by name.
    static let bundled: [String: EmitterSpec] = {
        guard let url = Bundle.main.url(forResource: "emitters", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("emitters.json missing from the app bundle")
            return [:]
        }
        do {
            var specs = try JSONDecoder().decode([String: EmitterSpec].self, from: data)
            specs["_comment"] = nil
            return specs
        } catch {
            assertionFailure("emitters.json undecodable: \(error)")
            return [:]
        }
    }()
}

extension EmitterSpec {
    /// `_comment` is a string, not a spec; tolerate it when decoding the map.
    private enum CodingKeys: String, CodingKey {
        case texture, blend, birthRate, lifetime, speed, emissionAngle, gravity, positionSpread
        case scale, alpha, rotationSpeed, defaultColor, maxParticles, inFront
    }
}
