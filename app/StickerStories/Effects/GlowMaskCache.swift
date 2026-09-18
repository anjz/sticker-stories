import CoreImage
import CoreImage.CIFilterBuiltins
import SpriteKit
import UIKit

/// Pre-blurred white silhouettes of sticker art for the `glow` effect,
/// built once per sticker on first use and cached for the pack's lifetime.
/// Never blurs live: the bloom is a cached texture whose alpha and colour
/// the applier drives per frame.
@MainActor
final class GlowMaskCache {
    struct Mask {
        let texture: SKTexture
        /// How much larger than the sticker the mask is (blur padding).
        let sizeMultiplier: CGFloat
    }

    private var masks: [String: Mask] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func mask(for stickerID: String, image: () -> UIImage?) -> Mask? {
        if let cached = masks[stickerID] { return cached }
        guard let uiImage = image(), let mask = build(from: uiImage) else { return nil }
        masks[stickerID] = mask
        return mask
    }

    private func build(from image: UIImage) -> Mask? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let radius = max(extent.width, extent.height) * 0.06

        // Alpha only, painted white — the sprite's colour blend tints it.
        let white = CIFilter.colorMatrix()
        white.inputImage = input
        white.rVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        white.gVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        white.bVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        white.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = white.outputImage
        blur.radius = Float(radius)

        let padded = extent.insetBy(dx: -radius * 2, dy: -radius * 2)
        guard let output = blur.outputImage, let cgImage = context.createCGImage(output, from: padded) else { return nil }
        return Mask(texture: SKTexture(cgImage: cgImage), sizeMultiplier: padded.width / extent.width)
    }
}
