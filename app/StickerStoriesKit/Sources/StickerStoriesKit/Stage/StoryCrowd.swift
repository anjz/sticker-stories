import Foundation

/// At most `limit` stickers on the stage while a story plays: a crowded
/// canvas plays slowly and choppily. When the child's stickers and the
/// story's visitors would be more, copies of the same sticker rest through
/// the story (faded out, back as it ends) — from the sticker with the most
/// copies, its smallest copy first — never the last of a kind. Pure.
public enum StoryCrowd {
    public static let limit = 25

    /// One of the child's stickers on the canvas.
    public struct Member: Sendable {
        public var id: UUID
        public var stickerID: String
        /// How big the child made it: the smallest copies rest first.
        public var scale: Double

        public init(id: UUID, stickerID: String, scale: Double) {
            self.id = id
            self.stickerID = stickerID
            self.scale = scale
        }
    }

    /// The child's stickers that rest through the story, with `visitors`
    /// more coming in.
    public static func resting(_ placed: [Member], visitors: Int, limit: Int = limit) -> Set<UUID> {
        var excess = placed.count + visitors - limit
        guard excess > 0 else { return [] }
        // Each sticker's copies, the smallest last (to rest first).
        var copies = Dictionary(grouping: placed, by: \.stickerID).mapValues {
            $0.sorted { $0.scale != $1.scale ? $0.scale > $1.scale : $0.id.uuidString < $1.id.uuidString }
        }
        var out: Set<UUID> = []
        while excess > 0 {
            guard let most = copies.filter({ $0.value.count > 1 })
                .max(by: { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key })
            else { break }
            if let copy = copies[most.key]?.removeLast() { out.insert(copy.id) }
            excess -= 1
        }
        return out
    }
}
