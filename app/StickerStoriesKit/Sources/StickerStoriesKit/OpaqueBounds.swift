import CoreGraphics

/// Where an image is painted: the box around its pixels that are at least
/// a little opaque. A sticker's size is the height of its drawing
/// (`SceneSpace.sizes`), not of its image; a scene layer is mostly empty
/// (the reeds at the pond) and is kept as the part that is painted.
public enum OpaqueBounds {
    /// The box in fractions of the image, origin bottom-left (like every
    /// other position in a pack), or nil when nothing is painted. The image
    /// is measured at most `maxSide` pixels on its longer side.
    public static func of(_ image: CGImage, threshold: UInt8 = 40, maxSide: Int = 512) -> CGRect? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height, 1)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var minX = w, maxX = -1, minRow = h, maxRow = -1
        for row in 0..<h {
            for x in 0..<w where alpha[row * w + x] >= threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // The bitmap's first row is the top of the image.
        return CGRect(
            x: Double(minX) / Double(w), y: 1 - Double(maxRow + 1) / Double(h),
            width: Double(maxX + 1 - minX) / Double(w), height: Double(maxRow + 1 - minRow) / Double(h))
    }
}
