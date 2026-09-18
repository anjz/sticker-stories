import Foundation
import SpriteKit
import StickerStoriesKit

/// Writes effect deltas onto sticker nodes each frame and guarantees the
/// child's placement comes back untouched (P4).
///
/// A sticker's base placement is captured on the node the first time an
/// effect touches it and written back verbatim when its last effect ends
/// or on `restoreAll()`. Stickers no effect ever touches are never written
/// to, so their transforms stay byte-identical to what editing set.
@MainActor
final class EffectApplier {
    private var owned: Set<UUID> = []

    /// Settles every sticker before effects start: in-flight landing
    /// animations are removed and the node put at the values they converge
    /// to, so a play tapped mid-"plop" cannot freeze a squash.
    func normalize(_ nodes: [StickerNode]) {
        for node in nodes {
            node.removeAllActions()
            node.setScale(node.baseScale)
            node.alpha = 1
        }
    }

    func apply(_ deltas: [UUID: EffectDelta], to nodes: [UUID: StickerNode]) {
        for id in owned where deltas[id] == nil {
            nodes[id]?.restoreFromEffects()
            owned.remove(id)
        }
        for (id, delta) in deltas {
            guard let node = nodes[id] else { continue }
            if node.effectBase == nil { node.effectBase = node.placement }
            owned.insert(id)
            let composed = EffectTransformMath.compose(
                node.effectBase!, with: delta,
                unscaledWidth: node.size.width, unscaledHeight: node.size.height)
            node.applyEffect(composed)
        }
    }

    func restoreAll(_ nodes: [UUID: StickerNode]) {
        for id in owned { nodes[id]?.restoreFromEffects() }
        owned.removeAll()
    }
}
