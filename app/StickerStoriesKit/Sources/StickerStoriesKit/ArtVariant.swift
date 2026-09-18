import Foundation

/// Which rendition of a pack's art to draw for a given window shape.
public enum ArtVariant: Equatable, Sendable {
    case base
    case wide

    /// Picks the rendition whose aspect ratio is closest to the window's
    /// (compared on a log scale, so "twice as wide" and "half as wide" are
    /// equally far). The app then scales that art to cover the window:
    /// a small vertical remainder is cropped, a horizontal one is panned.
    /// Choosing the closest aspect keeps both to a minimum — landscape-ish
    /// windows get little or no panning, tall phones get the wide art, and
    /// portrait / narrow windows get the base art with the least sideways
    /// travel. Ties go to the base art.
    public static func select(viewAspect: Double, baseAspect: Double, wideAspect: Double?) -> ArtVariant {
        guard let wideAspect, wideAspect > 0, baseAspect > 0, viewAspect > 0 else { return .base }
        let baseDistance = abs(log(baseAspect / viewAspect))
        let wideDistance = abs(log(wideAspect / viewAspect))
        return wideDistance < baseDistance ? .wide : .base
    }
}
