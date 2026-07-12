import SpriteKit
import StickerStoriesKit
import UIKit

/// The full-screen sticker canvas. Owns all touch handling so that dragging a
/// sticker out of the tray and onto the canvas is one continuous gesture.
///
/// Node stack (accumulated zPosition, back to front):
///   background art (0) < background stickers (100) < foreground art (200)
///   < foreground stickers (300) < tray (1000); a dragged sticker is lifted
///   to its layer's z + 10000 so it floats above everything while held.
final class CanvasScene: SKScene {
    /// Fired after every mutation (add, move, delete, layer change).
    var onCanvasChange: ((CanvasState) -> Void)?

    private let pack: LoadedPack

    private let backgroundArt = SKSpriteNode()
    private let backgroundStickers = SKNode()
    private let foregroundArt = SKSpriteNode()
    private let foregroundStickers = SKNode()
    private let tray = SKNode()

    private var stickerTextures: [String: SKTexture] = [:]
    private var trayRect: CGRect = .zero
    private var nextZOrder: CGFloat = 1

    private weak var selectedSticker: StickerNode?

    private struct DragInfo {
        let node: StickerNode
        let grabOffset: CGPoint
        let startLocation: CGPoint
        let startedFromTray: Bool
        let priorZ: CGFloat
        var moved = false
    }
    private var drags: [UITouch: DragInfo] = [:]

    /// A two-finger session on one sticker: pinch scales, twist rotates, and
    /// the midpoint moves it. Finger one holds the sticker; finger two may
    /// land anywhere (small hands are imprecise).
    private struct TransformInfo {
        let node: StickerNode
        let touchA: UITouch
        let touchB: UITouch
        let initialDistance: CGFloat
        let initialTouchAngle: CGFloat
        let initialScale: CGFloat
        let initialRotation: CGFloat
        let initialNodePosition: CGPoint
        let initialMidpoint: CGPoint
    }
    private var activeTransform: TransformInfo?

    private static let stickerScaleRange: ClosedRange<CGFloat> = 0.5...2.0

    private let softHaptic = UIImpactFeedbackGenerator(style: .light)
    private let firmHaptic = UIImpactFeedbackGenerator(style: .medium)

    // MARK: Setup

    init(pack: LoadedPack) {
        self.pack = pack
        super.init(size: CGSize(width: 1024, height: 768))
        scaleMode = .resizeFill
        backgroundColor = UIColor(red: 0.49, green: 0.78, blue: 0.91, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        if backgroundArt.parent == nil {
            backgroundArt.zPosition = 0
            backgroundStickers.zPosition = 100
            foregroundArt.zPosition = 200
            foregroundStickers.zPosition = 300
            tray.zPosition = 1000
            addChild(backgroundArt)
            addChild(backgroundStickers)
            addChild(foregroundArt)
            addChild(foregroundStickers)
            addChild(tray)
            loadPackContent()
        }
        layoutScene()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard oldSize != size, backgroundArt.parent != nil else { return }
        layoutScene()
        // Keep placed stickers at the same relative spot.
        if oldSize.width > 0, oldSize.height > 0 {
            let sx = size.width / oldSize.width
            let sy = size.height / oldSize.height
            for node in allStickerNodes() {
                node.position = CGPoint(x: node.position.x * sx, y: node.position.y * sy)
            }
        }
    }

    private func loadPackContent() {
        backgroundArt.texture = texture(forAssetPath: pack.manifest.background)
        foregroundArt.texture = texture(forAssetPath: pack.manifest.foreground)
        for sticker in pack.manifest.stickers {
            stickerTextures[sticker.id] = texture(forAssetPath: sticker.image)
        }
        buildTray()
    }

    private func texture(forAssetPath path: String) -> SKTexture? {
        guard let image = UIImage(contentsOfFile: pack.url(forAssetPath: path).path) else { return nil }
        return SKTexture(image: image)
    }

    // MARK: Layout

    private func layoutScene() {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for art in [backgroundArt, foregroundArt] {
            guard let textureSize = art.texture?.size(), textureSize.width > 0 else { continue }
            let fill = max(size.width / textureSize.width, size.height / textureSize.height)
            art.size = CGSize(width: textureSize.width * fill, height: textureSize.height * fill)
            art.position = center
        }
        layoutTray()
    }

    private var stickerBaseSize: CGFloat {
        min(150, max(64, size.height * 0.17))
    }

    // MARK: Tray

    private func buildTray() {
        tray.removeAllChildren()
        let bar = SKShapeNode()
        bar.name = "tray-bar"
        tray.addChild(bar)
        for sticker in pack.manifest.stickers {
            guard let texture = stickerTextures[sticker.id] else { continue }
            let item = TrayItemNode(stickerID: sticker.id, texture: texture)
            tray.addChild(item)
        }
    }

    private func layoutTray() {
        guard let bar = tray.childNode(withName: "tray-bar") as? SKShapeNode else { return }
        let items = tray.children.compactMap { $0 as? TrayItemNode }
        guard !items.isEmpty else { return }

        let barHeight: CGFloat = min(96, max(64, size.height * 0.15))
        let itemSize = barHeight * 0.72
        let spacing = itemSize * 0.35
        let sidePadding = spacing * 1.6
        let naturalWidth =
            CGFloat(items.count) * itemSize + CGFloat(items.count - 1) * spacing + 2 * sidePadding
        let barWidth = min(naturalWidth, size.width - 24)
        // Squeeze items if the natural width doesn't fit (small iPhones).
        let fit = min(1, (barWidth - 2 * sidePadding + spacing) / (CGFloat(items.count) * (itemSize + spacing)))
        let finalItem = itemSize * fit
        let finalSpacing = spacing * fit

        let topInset = view?.safeAreaInsets.top ?? 0
        let barCenterY = size.height - topInset - 10 - barHeight / 2
        trayRect = CGRect(
            x: size.width / 2 - barWidth / 2, y: barCenterY - barHeight / 2,
            width: barWidth, height: barHeight)

        bar.path = CGPath(
            roundedRect: CGRect(x: -barWidth / 2, y: -barHeight / 2, width: barWidth, height: barHeight),
            cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
        bar.fillColor = UIColor.white.withAlphaComponent(0.55)
        bar.strokeColor = UIColor.white.withAlphaComponent(0.9)
        bar.lineWidth = 2
        bar.position = CGPoint(x: size.width / 2, y: barCenterY)

        let rowWidth = CGFloat(items.count) * finalItem + CGFloat(items.count - 1) * finalSpacing
        var x = size.width / 2 - rowWidth / 2 + finalItem / 2
        for item in items {
            item.size = squareFit(texture: item.texture, side: finalItem)
            item.position = CGPoint(x: x, y: barCenterY)
            item.zPosition = 1
            x += finalItem + finalSpacing
        }
    }

    private func squareFit(texture: SKTexture?, side: CGFloat) -> CGSize {
        guard let texture, texture.size().width > 0, texture.size().height > 0 else {
            return CGSize(width: side, height: side)
        }
        let ts = texture.size()
        let scale = side / max(ts.width, ts.height)
        return CGSize(width: ts.width * scale, height: ts.height * scale)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let location = touch.location(in: self)
            // `atPoint` would return only the topmost node — and the
            // foreground art plane covers the whole scene, swallowing taps
            // meant for background-layer stickers. Inspect everything under
            // the touch instead: controls first, then tray, then the topmost
            // sticker on either layer.
            let hits = nodes(at: location)

            if let (control, sticker) = controlHit(in: hits) {
                handleControlTap(control, on: sticker)
            } else if let trayItem = hits.lazy.compactMap({ self.ancestor(of: $0, as: TrayItemNode.self) }).first {
                spawnSticker(from: trayItem, touch: touch, at: location)
            } else if let sticker = topSticker(in: hits) {
                if activeTransform == nil,
                    let held = drags.first(where: { $0.value.node === sticker }) {
                    // Second finger on an already-held sticker → transform it.
                    beginTransform(of: sticker, touchA: held.key, touchB: touch)
                } else {
                    beginDrag(of: sticker, touch: touch, at: location, fromTray: false)
                    select(sticker)
                }
            } else if activeTransform == nil, drags.count == 1, let held = drags.first {
                // Second finger on empty space while one sticker is held →
                // transform that sticker (forgiving for small hands).
                beginTransform(of: held.value.node, touchA: held.key, touchB: touch)
            } else {
                select(nil)
            }
        }
    }

    /// The sticker closest to the viewer among the hit nodes, comparing
    /// accumulated z (layer zPosition + node zPosition).
    private func topSticker(in hits: [SKNode]) -> StickerNode? {
        var best: StickerNode?
        var bestZ = -CGFloat.infinity
        for node in hits {
            guard let sticker = ancestor(of: node, as: StickerNode.self) else { continue }
            let z = (sticker.parent?.zPosition ?? 0) + sticker.zPosition
            if z > bestZ {
                bestZ = z
                best = sticker
            }
        }
        return best
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let transform = activeTransform,
            touches.contains(transform.touchA) || touches.contains(transform.touchB) {
            updateTransform(transform)
        }
        for touch in touches {
            if let transform = activeTransform,
                touch === transform.touchA || touch === transform.touchB {
                continue
            }
            guard var info = drags[touch] else { continue }
            let location = touch.location(in: self)
            info.node.position = CGPoint(
                x: location.x + info.grabOffset.x, y: location.y + info.grabOffset.y)
            if !info.moved, info.startLocation.distanceSquared(to: location) > 64 {
                info.moved = true
                if info.node.isSelected { select(nil) }  // hide controls while dragging
            }
            if info.moved { updateTrayHover(for: info.node) }
            drags[touch] = info
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if endTransform(for: touch, cancelled: false) { continue }
            endDrag(for: touch, cancelled: false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if endTransform(for: touch, cancelled: true) { continue }
            endDrag(for: touch, cancelled: true)
        }
    }

    private func ancestor<T: SKNode>(of node: SKNode, as type: T.Type) -> T? {
        var current: SKNode? = node
        while let candidate = current {
            if let match = candidate as? T { return match }
            current = candidate.parent
        }
        return nil
    }

    private func controlHit(in hits: [SKNode]) -> (name: String, sticker: StickerNode)? {
        for node in hits {
            if let name = node.name,
                name.hasPrefix(StickerNode.ControlName.prefix),
                let sticker = ancestor(of: node, as: StickerNode.self) {
                return (name, sticker)
            }
        }
        return nil
    }

    // MARK: Dragging

    private func spawnSticker(from trayItem: TrayItemNode, touch: UITouch, at location: CGPoint) {
        guard let texture = stickerTextures[trayItem.stickerID] else { return }
        let node = StickerNode(
            stickerID: trayItem.stickerID, texture: texture,
            size: squareFit(texture: texture, side: stickerBaseSize))
        node.position = location
        node.setScale(0.3)
        foregroundStickers.addChild(node)
        node.run(.scale(to: 1.12, duration: 0.12))
        trayItem.pulse()
        softHaptic.impactOccurred()
        beginDrag(of: node, touch: touch, at: location, fromTray: true)
    }

    private func beginDrag(of node: StickerNode, touch: UITouch, at location: CGPoint, fromTray: Bool) {
        let offset = CGPoint(x: node.position.x - location.x, y: node.position.y - location.y)
        drags[touch] = DragInfo(
            node: node, grabOffset: offset, startLocation: location,
            startedFromTray: fromTray, priorZ: node.zPosition)
        node.zPosition = 10000  // float above everything while held
        node.setLifted(true)
        if !fromTray {
            node.run(.scale(to: node.baseScale * 1.12, duration: 0.1))
        }
    }

    private func updateTrayHover(for node: StickerNode) {
        let overTray = trayRect.contains(node.position)
        let target: CGFloat = overTray ? 0.55 : node.baseScale * 1.12
        if abs(node.xScale - target) > 0.01 {
            node.run(.group([
                .scale(to: target, duration: 0.12),
                .fadeAlpha(to: overTray ? 0.6 : 1, duration: 0.12),
            ]))
        }
    }

    private func endDrag(for touch: UITouch, cancelled: Bool) {
        guard let info = drags.removeValue(forKey: touch) else { return }
        let node = info.node
        node.setLifted(false)

        if !info.moved && !info.startedFromTray {
            // A tap on an existing sticker: selection already happened in
            // touchesBegan; don't reorder, just settle.
            node.run(.scale(to: node.baseScale, duration: 0.1))
            node.zPosition = info.priorZ
            return
        }

        if trayRect.contains(node.position) {
            if info.startedFromTray && !cancelled,
                info.startLocation.distanceSquared(to: node.position) < 400 {
                // A tap on a tray item: hop the new sticker onto the canvas.
                node.alpha = 1
                node.zPosition = nextZ()
                let drop = CGPoint(
                    x: min(max(node.position.x, stickerBaseSize), size.width - stickerBaseSize),
                    y: trayRect.minY - stickerBaseSize * 0.9)
                node.run(.group([
                    .move(to: drop, duration: 0.22),
                    .sequence([
                        .scale(to: 1.08, duration: 0.12),
                        .scale(to: 0.95, duration: 0.08),
                        .scale(to: 1.0, duration: 0.07),
                    ]),
                ]))
                firmHaptic.impactOccurred()
                notifyCanvasChanged()
            } else {
                // Dropped on the tray: put the sticker away.
                removeSticker(node, haptic: !cancelled)
            }
            return
        }

        keepOnCanvas(node)
        node.zPosition = nextZ()
        node.alpha = 1
        // The landing "plop": squash, overshoot, settle.
        node.run(.sequence([
            .scale(to: node.baseScale * 0.92, duration: 0.08),
            .scale(to: node.baseScale * 1.05, duration: 0.09),
            .scale(to: node.baseScale, duration: 0.07),
        ]))
        if !cancelled { firmHaptic.impactOccurred() }
        notifyCanvasChanged()
    }

    /// Nudges a sticker back inside the visible canvas if dropped half off-screen.
    private func keepOnCanvas(_ node: StickerNode) {
        let margin = stickerBaseSize * 0.35
        node.position = CGPoint(
            x: min(max(node.position.x, margin), size.width - margin),
            y: min(max(node.position.y, margin), trayRect.minY - margin * 0.6))
    }

    private func nextZ() -> CGFloat {
        nextZOrder += 1
        return nextZOrder
    }

    // MARK: Selection & controls

    private func select(_ node: StickerNode?) {
        guard selectedSticker !== node else { return }
        selectedSticker?.setSelected(false)
        selectedSticker = node
        node?.setSelected(true)
    }

    private func handleControlTap(_ control: String, on sticker: StickerNode) {
        switch control {
        case StickerNode.ControlName.delete:
            select(nil)
            removeSticker(sticker, haptic: true)
        case StickerNode.ControlName.layer:
            toggleLayer(of: sticker)
        default:
            break
        }
    }

    // MARK: Two-finger transform (pinch to scale, twist to rotate)

    private func beginTransform(of node: StickerNode, touchA: UITouch, touchB: UITouch) {
        drags.removeValue(forKey: touchA)
        drags.removeValue(forKey: touchB)
        if node.isSelected { select(nil) }  // hide controls while transforming

        let a = touchA.location(in: self)
        let b = touchB.location(in: self)
        activeTransform = TransformInfo(
            node: node, touchA: touchA, touchB: touchB,
            initialDistance: max(a.distance(to: b), 1),
            initialTouchAngle: atan2(b.y - a.y, b.x - a.x),
            initialScale: node.baseScale,
            initialRotation: node.zRotation,
            initialNodePosition: node.position,
            initialMidpoint: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        node.zPosition = 10000
        node.setLifted(true)
        softHaptic.impactOccurred()
    }

    private func updateTransform(_ transform: TransformInfo) {
        let a = transform.touchA.location(in: self)
        let b = transform.touchB.location(in: self)
        let node = transform.node

        let distance = max(a.distance(to: b), 1)
        node.baseScale = min(
            max(transform.initialScale * distance / transform.initialDistance,
                Self.stickerScaleRange.lowerBound),
            Self.stickerScaleRange.upperBound)
        node.setScale(node.baseScale * 1.12)  // keep the lifted emphasis

        let angle = atan2(b.y - a.y, b.x - a.x)
        node.zRotation = transform.initialRotation + (angle - transform.initialTouchAngle)

        let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        node.position = CGPoint(
            x: transform.initialNodePosition.x + midpoint.x - transform.initialMidpoint.x,
            y: transform.initialNodePosition.y + midpoint.y - transform.initialMidpoint.y)
    }

    /// Returns true when the touch belonged to the active transform.
    private func endTransform(for touch: UITouch, cancelled: Bool) -> Bool {
        guard let transform = activeTransform,
            touch === transform.touchA || touch === transform.touchB
        else { return false }
        activeTransform = nil
        let node = transform.node

        // Snap near-upright rotation and near-1 scale — easy tidiness.
        var remainder = node.zRotation.truncatingRemainder(dividingBy: 2 * .pi)
        if remainder > .pi { remainder -= 2 * .pi }
        if remainder < -.pi { remainder += 2 * .pi }
        if abs(remainder) < 0.12 { node.zRotation = 0 }
        if abs(node.baseScale - 1) < 0.08 { node.baseScale = 1 }
        node.keepControlsUpright()

        // If the other finger is still down, hand the sticker back to a drag.
        let remaining = touch === transform.touchA ? transform.touchB : transform.touchA
        if !cancelled, remaining.phase == .began || remaining.phase == .moved || remaining.phase == .stationary {
            drags[remaining] = DragInfo(
                node: node,
                grabOffset: CGPoint(
                    x: node.position.x - remaining.location(in: self).x,
                    y: node.position.y - remaining.location(in: self).y),
                startLocation: remaining.location(in: self),
                startedFromTray: false, priorZ: node.zPosition, moved: true)
            node.run(.scale(to: node.baseScale * 1.12, duration: 0.1))
            return true
        }

        keepOnCanvas(node)
        node.zPosition = nextZ()
        node.setLifted(false)
        node.run(.sequence([
            .scale(to: node.baseScale * 0.95, duration: 0.08),
            .scale(to: node.baseScale, duration: 0.09),
        ]))
        if !cancelled { firmHaptic.impactOccurred() }
        notifyCanvasChanged()
        return true
    }

    private func toggleLayer(of sticker: StickerNode) {
        let targetLayer: SKNode
        if sticker.canvasLayer == .foreground {
            sticker.canvasLayer = .background
            targetLayer = backgroundStickers
        } else {
            sticker.canvasLayer = .foreground
            targetLayer = foregroundStickers
        }
        // Both layer nodes sit at the scene origin, so position carries over.
        sticker.move(toParent: targetLayer)
        sticker.zPosition = nextZ()
        sticker.refreshSelectionOverlay()
        // A quick dip-and-return sells the "went behind / came forward" change.
        sticker.run(.sequence([
            .scale(to: sticker.baseScale * 0.9, duration: 0.1),
            .scale(to: sticker.baseScale, duration: 0.12),
        ]))
        softHaptic.impactOccurred()
        notifyCanvasChanged()
    }

    private func removeSticker(_ node: StickerNode, haptic: Bool) {
        if selectedSticker === node { select(nil) }
        node.run(.sequence([
            .group([.scale(to: 0.01, duration: 0.16), .fadeOut(withDuration: 0.16)]),
            .removeFromParent(),
        ]))
        if haptic { firmHaptic.impactOccurred() }
        notifyCanvasChanged()
    }

    // MARK: Canvas state

    private func allStickerNodes() -> [StickerNode] {
        (backgroundStickers.children + foregroundStickers.children).compactMap { $0 as? StickerNode }
    }

    /// Serialisable snapshot of the canvas — see docs/architecture.md.
    func snapshot() -> CanvasState {
        var placed: [PlacedSticker] = []
        for (layerNode, layer) in [(backgroundStickers, CanvasLayer.background), (foregroundStickers, .foreground)] {
            for case let node as StickerNode in layerNode.children {
                placed.append(
                    PlacedSticker(
                        id: node.instanceID,
                        stickerID: node.stickerID,
                        position: NormalizedPoint(
                            x: node.position.x / max(size.width, 1),
                            y: node.position.y / max(size.height, 1)),
                        layer: layer,
                        zOrder: Int(node.zPosition),
                        scale: node.baseScale,
                        rotation: Double(node.zRotation)))
            }
        }
        return CanvasState(packID: pack.id, stickers: placed)
    }

    private func notifyCanvasChanged() {
        // Removal animations complete in ~0.16s; snapshot after they settle.
        run(.sequence([
            .wait(forDuration: 0.2),
            .run { [weak self] in
                guard let self else { return }
                self.onCanvasChange?(self.snapshot())
            },
        ]))
    }
}

/// One sticker type in the tray. Touching it spawns a draggable sticker.
final class TrayItemNode: SKSpriteNode {
    let stickerID: String

    init(stickerID: String, texture: SKTexture) {
        self.stickerID = stickerID
        super.init(texture: texture, color: .clear, size: texture.size())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func pulse() {
        run(.sequence([.scale(to: 0.85, duration: 0.08), .scale(to: 1.0, duration: 0.12)]))
    }
}

extension CGPoint {
    fileprivate func distanceSquared(to other: CGPoint) -> CGFloat {
        (x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)
    }

    fileprivate func distance(to other: CGPoint) -> CGFloat {
        distanceSquared(to: other).squareRoot()
    }
}
