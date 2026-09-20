import Foundation

/// The closed library of sticker effects — see `docs/effects.md`. Canvas
/// effects (weather and light over the whole scene) are a separate, equally
/// closed list: `CanvasEffectName`.
///
/// Exactly twelve. Adding one later is easy (unknown names are skipped by
/// older builds, so it is not a breaking change); removing one from shipped
/// content is not, so do not add casually and never repurpose a name.
/// `sway`, `blink` and `puff` were removed in 2026-09 — do not reuse them.
public enum EffectName: String, CaseIterable, Codable, Sendable, Hashable {
    // Motion (6)
    case pulse
    case wobble
    case shake
    case hop
    case spin
    case float
    // Opacity and colour (4)
    case fadeIn = "fade-in"
    case fadeOut = "fade-out"
    case glow
    case tint
    // Particles (2)
    case sparkle
    case hearts

    public enum Category: String, Sendable, Codable {
        case motion
        case opacityAndColor = "opacity-and-color"
        case particle
    }

    public var category: Category {
        switch self {
        case .pulse, .wobble, .shake, .hop, .spin, .float: .motion
        case .fadeIn, .fadeOut, .glow, .tint: .opacityAndColor
        case .sparkle, .hearts: .particle
        }
    }

    /// `fade-in` and `fade-out` do not end where they started: `repeat` is
    /// ignored for them and `hold` keeps their end state.
    public var isOneWay: Bool { self == .fadeIn || self == .fadeOut }

    /// Effects for which `hold` means something (keep the end state / the
    /// bloom or wash on until playback ends).
    public var supportsHold: Bool {
        switch self {
        case .fadeIn, .fadeOut, .glow, .tint: true
        default: false
        }
    }

    /// Effects that read the `color` parameter; it is ignored elsewhere.
    public var readsColor: Bool { self == .glow || self == .tint || self == .sparkle }

    /// `tint` has no sensible default colour; a trigger without one is skipped.
    public var requiresColor: Bool { self == .tint }
}
