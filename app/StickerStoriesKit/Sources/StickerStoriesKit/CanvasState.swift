import Foundation

/// A serialisable snapshot of everything on the canvas, independent of
/// SpriteKit. This is what story selection consumes today and what a future
/// runtime story generator would receive as its prompt payload — keep it
/// cleanly Codable (see docs/architecture.md, "Future: runtime generation").
public struct CanvasState: Codable, Equatable, Sendable {
    public var packID: String
    public var stickers: [PlacedSticker]

    public init(packID: String, stickers: [PlacedSticker] = []) {
        self.packID = packID
        self.stickers = stickers
    }

    /// The distinct sticker types on the canvas — the input to story scoring.
    public var stickerIDs: Set<String> {
        Set(stickers.map(\.stickerID))
    }
}

/// One sticker instance placed on the canvas.
public struct PlacedSticker: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The sticker type, referencing `StickerDefinition.id` in the manifest.
    public var stickerID: String
    /// Position of the sticker's centre in normalized canvas space
    /// (0...1 on both axes, origin at bottom-left, SpriteKit-style).
    public var position: NormalizedPoint
    public var layer: CanvasLayer
    /// Stacking order within the layer; higher is closer to the viewer.
    public var zOrder: Int
    public var scale: Double
    /// Rotation in radians, counterclockwise.
    public var rotation: Double

    public init(
        id: UUID = UUID(), stickerID: String, position: NormalizedPoint,
        layer: CanvasLayer = .foreground, zOrder: Int = 0,
        scale: Double = 1.0, rotation: Double = 0
    ) {
        self.id = id
        self.stickerID = stickerID
        self.position = position
        self.layer = layer
        self.zOrder = zOrder
        self.scale = scale
        self.rotation = rotation
    }
}

/// Which of the two sticker planes a sticker lives on. Foreground stickers
/// render in front of the pack's foreground art; background stickers render
/// behind it (but in front of the background art).
public enum CanvasLayer: String, Codable, Sendable {
    case background
    case foreground
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
