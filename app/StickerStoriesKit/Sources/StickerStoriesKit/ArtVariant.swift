import Foundation

/// Which rendition of a pack's art to draw for a given window shape.
public enum ArtVariant: Equatable, Sendable {
    case base
    case wide

    /// The most of the art's height the app will crop (top + bottom
    /// together) before it prefers a wider rendition that needs panning.
    public static let maxCropFraction = 0.3

    /// Picks the rendition to draw. The app scales the chosen art to cover
    /// the window: an art narrower than the window crops top and bottom
    /// (no panning); an art wider than the window pans sideways.
    ///
    /// Preference order:
    /// 1. **No panning**: among renditions no wider than the window, the one
    ///    that crops least — as long as that crop stays within
    ///    `maxCropFraction`. This is every full-screen landscape case on
    ///    iPhone and iPad.
    /// 2. Otherwise the rendition that pans least (portrait, narrow windows,
    ///    or a landscape window every rendition is far too narrow for).
    public static func select(
        viewAspect: Double, baseAspect: Double, wideAspect: Double?,
        maxCropFraction: Double = ArtVariant.maxCropFraction
    ) -> ArtVariant {
        guard viewAspect > 0, baseAspect > 0 else { return .base }
        var candidates: [(variant: ArtVariant, aspect: Double)] = [(.base, baseAspect)]
        if let wideAspect, wideAspect > 0 { candidates.append((.wide, wideAspect)) }

        // Renditions the window is at least as wide as: cover → vertical crop only.
        let cropping = candidates
            .filter { $0.aspect <= viewAspect }
            .map { (variant: $0.variant, crop: 1 - $0.aspect / viewAspect) }
            .sorted { $0.crop < $1.crop }
        if let best = cropping.first, best.crop <= maxCropFraction {
            return best.variant
        }

        // Otherwise: the rendition that pans least (or, if all crop too much,
        // the one that crops least — there is nothing better to do).
        let panning = candidates
            .filter { $0.aspect > viewAspect }
            .map { (variant: $0.variant, pan: 1 - viewAspect / $0.aspect) }
            .sorted { $0.pan < $1.pan }
        return panning.first?.variant ?? cropping.first?.variant ?? .base
    }
}
