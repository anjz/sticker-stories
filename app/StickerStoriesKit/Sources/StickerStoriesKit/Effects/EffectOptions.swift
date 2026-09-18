import Foundation

/// A colour as four 0...1 components. Parsed from `"#RRGGBB"` (alpha 1) or
/// `"#RRGGBBAA"`; anything else is rejected so malformed content is ignored.
public struct RGBA: Equatable, Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init?(hex: String) {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6 || digits.count == 8,
            digits.allSatisfy(\.isHexDigit),
            let value = UInt32(digits, radix: 16)
        else { return nil }
        let hasAlpha = digits.count == 8
        let shifted = hasAlpha ? value : (value << 8) | 0xFF
        red = Double((shifted >> 24) & 0xFF) / 255
        green = Double((shifted >> 16) & 0xFF) / 255
        blue = Double((shifted >> 8) & 0xFF) / 255
        alpha = Double(shifted & 0xFF) / 255
    }

    /// `"#RRGGBB"` (alpha omitted when it is 1).
    public var hexString: String {
        func byte(_ v: Double) -> String { String(format: "%02X", Int((v.clamped(to: 0...1) * 255).rounded())) }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return alpha >= 1 ? rgb : rgb + byte(alpha)
    }

    public static let white = RGBA(red: 1, green: 1, blue: 1)
    /// True when the colour is (near) white — used for the flash rate cap.
    public var isWhite: Bool { red > 0.95 && green > 0.95 && blue > 0.95 }
}

/// How many cycles an effect runs.
public enum RepeatCount: Equatable, Sendable, Hashable {
    case times(Int)
    case loop

    /// Cycles are capped at 50; anything below 1 becomes 1.
    public static let maxTimes = 50

    var clamped: RepeatCount {
        switch self {
        case .times(let n): .times(min(max(n, 1), Self.maxTimes))
        case .loop: .loop
        }
    }
}

/// The whole tuning surface content gets: five keys (see `docs/effects.md`).
public struct EffectOptions: Equatable, Sendable, Hashable {
    public static let defaultIntensity = 0.6
    public static let durationRange: ClosedRange<TimeInterval> = 0.05...30

    public var repeatCount: RepeatCount = .times(1)
    /// Seconds for one cycle; `nil` = the effect's default.
    public var duration: TimeInterval? = nil
    /// 0...1. Scales amplitude, never speed.
    public var intensity: Double = EffectOptions.defaultIntensity
    /// Read by `glow`, `tint` and `sparkle` only.
    public var color: RGBA? = nil
    /// Meaningful for `fade-in`, `fade-out`, `glow`, `tint` only.
    public var hold: Bool = false

    public init(
        repeatCount: RepeatCount = .times(1), duration: TimeInterval? = nil,
        intensity: Double = EffectOptions.defaultIntensity, color: RGBA? = nil, hold: Bool = false
    ) {
        self.repeatCount = repeatCount
        self.duration = duration
        self.intensity = intensity
        self.color = color
        self.hold = hold
    }

    /// Options with every value inside the documented ranges.
    public var clamped: EffectOptions {
        var copy = self
        copy.repeatCount = repeatCount.clamped
        copy.duration = duration.map { $0.clamped(to: Self.durationRange) }
        copy.intensity = intensity.isFinite ? intensity.clamped(to: 0...1) : Self.defaultIntensity
        return copy
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
