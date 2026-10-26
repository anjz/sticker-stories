import CoreImage
import CoreImage.CIFilterBuiltins
import SpriteKit
import UIKit

/// Pre-blurred black silhouettes of sticker art for the drop shadow under
/// every placed sticker, built once per sticker on first use and cached
/// for the pack's lifetime (the same pattern as `GlowMaskCache`). A real
/// sticker's shadow is soft-edged; blurring live would cost a pass per
/// sticker per frame, so it is a texture whose offset and alpha the node
/// drives.
@MainActor
final class StickerShadowCache {
    struct Shadow {
        let texture: SKTexture
        /// How much larger than the sticker the shadow is (blur padding).
        let sizeMultiplier: CGFloat
    }

    /// Blur radius as a fraction of the sticker's larger dimension: soft,
    /// but tight enough to still read as the sticker's own outline.
    nonisolated static let blurFraction: CGFloat = 0.014

    private var shadows: [String: Shadow] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func shadow(for stickerID: String, image: () -> UIImage?) -> Shadow? {
        if let cached = shadows[stickerID] { return cached }
        guard let uiImage = image(), let shadow = build(from: uiImage) else { return nil }
        shadows[stickerID] = shadow
        return shadow
    }

    private func build(from image: UIImage) -> Shadow? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let radius = max(extent.width, extent.height) * Self.blurFraction
        let padded = extent.insetBy(dx: -radius * 2, dy: -radius * 2)
        guard let output = Self.blurredSilhouette(of: input, radius: radius),
            let cgImage = context.createCGImage(output, from: padded)
        else { return nil }
        return Shadow(texture: SKTexture(cgImage: cgImage), sizeMultiplier: padded.width / extent.width)
    }

    /// The image's alpha painted black and blurred.
    private nonisolated static func blurredSilhouette(of input: CIImage, radius: CGFloat) -> CIImage? {
        let black = CIFilter.colorMatrix()
        black.inputImage = input
        black.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        black.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        black.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        black.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = black.outputImage
        blur.radius = Float(radius)
        return blur.outputImage
    }
}
