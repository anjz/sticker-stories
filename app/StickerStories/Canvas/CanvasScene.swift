import os
import CoreImage
import SpriteKit
import StickerStoriesKit
import UIKit

/// The full-screen sticker canvas. Owns all touch handling so that dragging a
/// sticker out of the tray and onto the canvas is one continuous gesture.
///
/// Node stack (accumulated zPosition, back to front):
///   background art (0) < rainbow, moon, stars (50) < background stickers (100)
///   < foreground art (200) < foreground stickers (300) < canvas effects
///   (500: rain, fog, sunshine, night, dimlight) < tray (1000); a dragged sticker
///   is lifted to its layer's z + 10000 so it floats above everything while
///   held.
///
/// World and camera: the pack art defines a fixed-aspect **world**, scaled
/// so it always covers the view (`worldSize`). Sticker positions live in
/// world points and are saved normalized to the art, so a fox on the hill
/// stays on the hill in every orientation and window size. Horizontal
/// overflow (portrait, Split View, narrow windows) can be panned with one
/// finger on empty space, camera clamped to the world. Vertical overflow
/// (a view wider than the art: every full-screen landscape case) is simply
/// centre-cropped, never panned. Packs can ship a wide rendition of the
/// art; the scene draws the rendition that lets a landscape window avoid
/// panning with the least crop (`ArtVariant`): iPads keep the base art,
/// tall phones get the wide art, and portrait pans the least
/// (docs/pack-format.md, "Art safe area"). The tray is a HUD that follows
/// the camera and always fits between the SwiftUI buttons.
final class CanvasScene: SKScene {
    /// Fired after every mutation (add, move, delete, layer change).
    var onCanvasChange: ((CanvasState) -> Void)?
    /// Fired whenever undo/redo/clear availability changes: (canUndo, canRedo, canClear).
    var onHistoryChange: ((Bool, Bool, Bool) -> Void)?

    private let pack: LoadedPack
    private let textures: PackTextures
    private let stateStore: any CanvasStateStore

    private let backgroundArt = SKSpriteNode()
    private let backgroundStickers = SKNode()
    /// The foreground plane's soft shadow, cast onto the background art and
    /// the background stickers: a blurred black copy of the foreground art,
    /// offset a little downwards. The one visible hint that the canvas is
    /// two sheets, not one picture.
    private let foregroundShadow = SKSpriteNode()
    private let foregroundShadowBlur = SKEffectNode()
    private let foregroundArt = SKSpriteNode()
    private let foregroundStickers = SKNode()
    /// Weather and light over the scene during play (`CanvasEffectLayer`);
    /// a permanent child whose children carry the z-positions above.
    private let canvasEffects = CanvasEffectLayer()
    private let tray = SKNode()
    private let cameraNode = SKCameraNode()
    /// The *base* art scaled to cover the view: the coordinate space stickers
    /// live in (origin at its bottom-left) and the reference for sizes.
    private var worldSize: CGSize = .zero
    /// The drawn art's frame in world coordinates. Equal to `worldSize` at
    /// the origin unless the pack ships wide art, which extends it sideways
    /// (negative x on the left). The camera and drops are clamped to this.
    private var worldExtent: CGRect = .zero
    /// Pixel size of the base art; wide art shares its height.
    private var baseArtPixelSize: CGSize = .zero
    private var baseArtTextures: (background: SKTexture?, foreground: SKTexture?) = (nil, nil)
    private var wideArtTextures: (background: SKTexture, foreground: SKTexture?)?
    /// Scrollable row of tray items; `position.x` is the scroll offset
    /// (0 = start, negative = scrolled left to reveal later items).
    private let trayContent = SKNode()
    /// Clips `trayContent` to the visible pill so off-screen items don't render.
    private let trayClip = SKCropNode()
    private let trayMask = SKShapeNode()
    private var maxTrayScrollOffset: CGFloat = 0
    /// Keeps the tray clear of the SwiftUI back button (top-leading) and the
    /// undo/redo/clear cluster (top-trailing) in StoryScreen.swift.
    private static let trayLeadingClearance: CGFloat = 100
    private static let trayTrailingClearance: CGFloat = 180
    /// The tray hangs `hudTopClearance` below the top safe-area inset, or
    /// below `hudMinimumTopInset` when the inset is smaller (iPhone in
    /// landscape has none): a sticker grabbed near the physical edge would
    /// otherwise pull Notification Centre down instead. StoryScreen's HUD
    /// buttons use the same two numbers so the row stays aligned.
    static let hudMinimumTopInset: CGFloat = 24
    static let hudTopClearance: CGFloat = 14

    private var stickerTextures: [String: SKTexture] = [:]
    /// The tray pill in view coordinates (the tray node is laid out in view
    /// space and follows the camera).
    private var trayRectInView: CGRect = .zero
    /// The tray pill in world coordinates, for sticker drop/hover tests.
    private var trayRect: CGRect { trayRectInView.offsetBy(dx: viewOrigin.x, dy: viewOrigin.y) }
    /// World coordinate of the view's bottom-left corner.
    private var viewOrigin: CGPoint {
        CGPoint(x: cameraNode.position.x - size.width / 2, y: cameraNode.position.y - size.height / 2)
    }
    /// The part of the world currently on screen.
    private var visibleRect: CGRect { CGRect(origin: viewOrigin, size: size) }
    /// Only horizontal overflow is pannable; vertical overflow is cropped.
    private var worldOverflows: Bool {
        worldExtent.width > size.width + 0.5
    }
    private var nextZOrder: CGFloat = 1

    private weak var selectedSticker: StickerNode?
    private var selectionBubble: SelectionBubbleNode?

    private struct DragInfo {
        let node: StickerNode
        let grabOffset: CGPoint
        let startLocation: CGPoint
        let startedFromTray: Bool
        let priorZ: CGFloat
        /// Canvas state before this gesture began — the undo step it commits.
        let beforeSnapshot: CanvasState
        var moved = false
    }
    private var drags: [UITouch: DragInfo] = [:]

    /// A touch that landed on a tray item but hasn't moved far enough yet to
    /// commit to either picking the sticker up or scrolling the tray.
    private struct PendingTrayTouch {
        let item: TrayItemNode
        let startLocation: CGPoint
    }
    private var pendingTrayTouches: [UITouch: PendingTrayTouch] = [:]

    private struct TrayScrollInfo {
        let startLocation: CGPoint
        let startOffset: CGFloat
    }
    private var trayScrolls: [UITouch: TrayScrollInfo] = [:]

    /// One finger on empty space pans the camera over the world (only when
    /// the world overflows the view). Tracked in view coordinates because
    /// scene coordinates shift under the finger as the camera moves.
    private struct PanInfo {
        let startViewLocation: CGPoint
        let startCamera: CGPoint
    }
    private var pans: [UITouch: PanInfo] = [:]
    private static let panHintActionKey = "pan-hint"
    private static let trayFadeActionKey = "tray-fade"
    /// Same "has this become a real gesture yet" radius used for drags below.
    private static let moveThresholdSquared: CGFloat = 64

    private var undoStack: [CanvasState] = []
    private var redoStack: [CanvasState] = []
    private static let maxHistoryDepth = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canClear: Bool { !allStickerNodes().isEmpty }

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
        /// Canvas state before this gesture began — the undo step it commits.
        let beforeSnapshot: CanvasState
    }
    private var activeTransform: TransformInfo?

    private static let stickerScaleRange: ClosedRange<CGFloat> = 0.5...2.0

    private let softHaptic = UIImpactFeedbackGenerator(style: .light)
    private let firmHaptic = UIImpactFeedbackGenerator(style: .medium)

    /// Play mode: touches are ignored and the effects pipeline (created at
    /// play start, discarded at play end — P6) owns the sticker transforms.
    private(set) var isPlayLocked = false
    private struct PlaySession {
        let runner: StickerEffectsRunner
        let canvasRunner: CanvasEffectsRunner
        let applier: EffectApplier
        let emitters: EmitterCoordinator
        let clock: PlaybackClock
    }
    private var playSession: PlaySession?
    private let glowMasks = GlowMaskCache()
    private let shadows = StickerShadowCache()
    private static let effectsLog = Logger(subsystem: "com.anj.stickerstories", category: "effects")

    // MARK: Setup

    /// What the scene paints behind the art; `StoryScreen` shows it while
    /// the pack's textures load so the canvas fades in over the same blue.
    static let skyColor = UIColor(red: 0.49, green: 0.78, blue: 0.91, alpha: 1)

    /// `textures` come decoded and preloaded (`PackTextureLoader`) so that
    /// presenting the scene costs nothing on the main thread.
    init(pack: LoadedPack, textures: PackTextures, stateStore: any CanvasStateStore) {
        self.pack = pack
        self.textures = textures
        self.stateStore = stateStore
        super.init(size: CGSize(width: 1024, height: 768))
        scaleMode = .resizeFill
        backgroundColor = Self.skyColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMove(to view: SKView) {
        view.isMultipleTouchEnabled = true
        let isFirstLoad = backgroundArt.parent == nil
        if isFirstLoad {
            backgroundArt.zPosition = 0
            backgroundStickers.zPosition = 100
            foregroundShadowBlur.zPosition = 150
            foregroundArt.zPosition = 200
            foregroundStickers.zPosition = 300
            tray.zPosition = 1000
            foregroundShadow.color = .black
            foregroundShadow.colorBlendFactor = 1
            foregroundShadow.alpha = Self.foregroundShadowAlpha
            foregroundShadowBlur.shouldRasterize = true  // blurred once per layout, not per frame
            foregroundShadowBlur.shouldEnableEffects = true
            foregroundShadowBlur.addChild(foregroundShadow)
            addChild(backgroundArt)
            addChild(backgroundStickers)
            addChild(foregroundShadowBlur)
            addChild(foregroundArt)
            addChild(foregroundStickers)
            addChild(canvasEffects)
            addChild(cameraNode)
            camera = cameraNode
            // The tray is a HUD: a scene child (so its z-order and hit-testing
            // are the plain, reliable kind) that follows the camera every
            // frame rather than a camera child — SpriteKit draws camera
            // descendants below world content once the camera is off-centre.
            addChild(tray)
            loadPackContent()
        }
        layoutScene()
        if isFirstLoad {
            cameraNode.position = CGPoint(x: worldExtent.midX, y: worldExtent.midY)
            clampCamera()
            restorePersistedState()
            runTrayScrollHint()
            runPanHintIfNeeded()
        }
    }

    /// Runs after actions (the pan hint moves the camera with an action) and
    /// before rendering: keeps the camera on the art whatever moved it and
    /// keeps the HUD from lagging the camera by a frame.
    override func didFinishUpdate() {
        clampCamera()
    }

    private func syncHUDToCamera() {
        tray.position = viewOrigin
    }

    /// Loads any canvas saved for this pack from a prior visit. Runs once,
    /// after layout so `size` is settled for denormalizing positions.
    private func restorePersistedState() {
        if let restored = stateStore.load(packID: pack.id), !restored.stickers.isEmpty {
            apply(restored)
        }
        // Fire unconditionally so observers get the right initial state
        // whether or not `CanvasView.onAppear` has wired its closures yet —
        // it does its own manual sync call either way.
        onCanvasChange?(snapshot())
        reportHistory()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard oldSize != size, backgroundArt.parent != nil else { return }
        // A running hint would move the camera back to coordinates that no
        // longer mean anything (an iPhone launches portrait, then rotates).
        cameraNode.removeAction(forKey: Self.panHintActionKey)
        let oldWorld = worldSize
        let overflowedBefore = worldOverflows
        let cameraFraction = CGPoint(
            x: oldWorld.width > 0 ? cameraNode.position.x / oldWorld.width : 0.5,
            y: oldWorld.height > 0 ? cameraNode.position.y / oldWorld.height : 0.5)
        layoutScene()
        // The world keeps its aspect, so one uniform factor keeps every
        // sticker on the same spot of the art at the same relative size.
        if oldWorld.height > 0 {
            let ratio = worldSize.height / oldWorld.height
            for node in allStickerNodes() { node.rescale(by: ratio) }
        }
        cameraNode.position = CGPoint(
            x: cameraFraction.x * worldSize.width, y: cameraFraction.y * worldSize.height)
        clampCamera()
        refreshSelectionBubble()
        if !overflowedBefore { runPanHintIfNeeded() }
    }

    private func loadPackContent() {
        // Both renditions are kept; `layoutScene` draws whichever aspect is
        // closest to the window. The base art always defines the frame.
        baseArtTextures = (textures.background, textures.foreground)
        baseArtPixelSize = baseArtTextures.background?.size() ?? .zero
        wideArtTextures = textures.wide
        backgroundArt.texture = baseArtTextures.background
        foregroundArt.texture = baseArtTextures.foreground
        stickerTextures = textures.stickers
        buildTray()
    }

    // MARK: Layout

    private func layoutScene() {
        // Draw the rendition that lets a landscape window avoid panning with
        // the least crop, or pans least otherwise (ArtVariant).
        let viewAspect = size.height > 0 ? Double(size.width / size.height) : 1
        let baseAspect = baseArtPixelSize.height > 0 ? Double(baseArtPixelSize.width / baseArtPixelSize.height) : 1
        let wideAspect = wideArtTextures.map { Double($0.background.size().width / max($0.background.size().height, 1)) }
        if let wide = wideArtTextures,
            ArtVariant.select(viewAspect: viewAspect, baseAspect: baseAspect, wideAspect: wideAspect) == .wide {
            backgroundArt.texture = wide.background
            foregroundArt.texture = wide.foreground
        } else {
            backgroundArt.texture = baseArtTextures.background
            foregroundArt.texture = baseArtTextures.foreground
        }
        // Scale so the *drawn* art covers the view; the base frame is that
        // scale applied to the base art, centred on the drawn art.
        let drawnPixelSize = backgroundArt.texture?.size() ?? baseArtPixelSize
        let drawn = Self.worldSize(covering: size, artSize: drawnPixelSize)
        let scale = drawnPixelSize.height > 0 ? drawn.height / drawnPixelSize.height : 1
        let basePixel = baseArtPixelSize.width > 0 ? baseArtPixelSize : drawnPixelSize
        worldSize = CGSize(width: basePixel.width * scale, height: basePixel.height * scale)
        if worldSize == .zero { worldSize = size }
        worldExtent = CGRect(
            x: (worldSize.width - drawn.width) / 2, y: (worldSize.height - drawn.height) / 2,
            width: drawn.width, height: drawn.height)
        let center = CGPoint(x: worldExtent.midX, y: worldExtent.midY)
        for art in [backgroundArt, foregroundArt] {
            guard let textureSize = art.texture?.size(), textureSize.width > 0 else { continue }
            art.size = CGSize(width: textureSize.width * scale, height: textureSize.height * scale)
            art.position = center
        }
        layoutForegroundShadow(center: center)
        canvasEffects.layout(world: worldExtent)
        // The tray is laid out in view coordinates and pinned to the view's
        // bottom-left corner in world space (kept in step with the camera).
        syncHUDToCamera()
        layoutTray()
    }

    /// Shadow strength and geometry, as fractions of the world height so the
    /// look is the same on every device.
    /// An ambient halo rather than a directional shadow: no offset, a wide
    /// blur so the darkness spreads past every edge of the foreground art,
    /// and enough opacity to survive the blur.
    static let foregroundShadowAlpha: CGFloat = 0.9
    private static let foregroundShadowDrop: CGFloat = 0.0
    private static let foregroundShadowShift: CGFloat = 0.0
    private static let foregroundShadowBlurFraction: CGFloat = 0.011

    private func layoutForegroundShadow(center: CGPoint) {
        foregroundShadow.texture = foregroundArt.texture
        foregroundShadow.size = foregroundArt.size
        foregroundShadow.position = CGPoint(
            x: center.x + worldSize.height * Self.foregroundShadowShift,
            y: center.y - worldSize.height * Self.foregroundShadowDrop)
        let radius = max(2, worldSize.height * Self.foregroundShadowBlurFraction)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            foregroundShadowBlur.filter = blur
        }
        foregroundShadowBlur.isHidden = foregroundArt.texture == nil
    }

    /// The art scaled to cover the view: the smaller the view's aspect gap
    /// to the art, the less overflows. Without art, the world is the view.
    static func worldSize(covering view: CGSize, artSize: CGSize?) -> CGSize {
        guard let art = artSize, art.width > 0, art.height > 0 else { return view }
        let fill = max(view.width / art.width, view.height / art.height)
        return CGSize(width: art.width * fill, height: art.height * fill)
    }

    /// Sticker size is relative to the world, not the view, so a sticker
    /// covers the same amount of art whatever the window shape.
    private var stickerBaseSize: CGFloat {
        worldSize.height * 0.16
    }

    // MARK: Camera

    private func clampCamera() {
        var position = cameraNode.position
        if worldExtent.width <= size.width {
            position.x = worldExtent.midX
        } else {
            position.x = min(max(position.x, worldExtent.minX + size.width / 2), worldExtent.maxX - size.width / 2)
        }
        // Vertical overflow is centre-cropped, never panned.
        position.y = worldExtent.midY
        cameraNode.position = position
        syncHUDToCamera()
    }

    /// One-shot "there's more" hint when the world overflows the view
    /// sideways: the camera drifts a little toward the hidden part and eases
    /// back, the same idea as the tray's scroll hint. Cancelled by any touch.
    private func runPanHintIfNeeded() {
        guard worldOverflows else { return }
        let dx = min(worldExtent.width - size.width, size.width * 0.12)
        let start = cameraNode.position
        let out = SKAction.move(to: CGPoint(x: start.x + dx / 2, y: start.y), duration: 0.5)
        out.timingMode = .easeInEaseOut
        let back = SKAction.move(to: start, duration: 0.6)
        back.timingMode = .easeInEaseOut
        cameraNode.run(
            .sequence([.wait(forDuration: 1.0), out, .wait(forDuration: 0.2), back, .run { [weak self] in self?.clampCamera() }]),
            withKey: Self.panHintActionKey)
    }

    private func beginPan(_ touch: UITouch) {
        guard worldOverflows, let view else { return }
        cameraNode.removeAction(forKey: Self.panHintActionKey)
        pans[touch] = PanInfo(startViewLocation: touch.location(in: view), startCamera: cameraNode.position)
    }

    private func updatePan(for touch: UITouch) {
        guard let info = pans[touch], let view else { return }
        let location = touch.location(in: view)
        cameraNode.position = CGPoint(
            x: info.startCamera.x - (location.x - info.startViewLocation.x),
            y: info.startCamera.y)
        clampCamera()
    }

    // MARK: Tray

    private func buildTray() {
        tray.removeAllChildren()

        let bar = SKShapeNode()
        bar.name = "tray-bar"
        tray.addChild(bar)

        trayContent.removeAllChildren()
        for sticker in pack.manifest.stickers {
            guard let texture = stickerTextures[sticker.id] else { continue }
            // Sticker art comes on a square canvas with transparent margins
            // that vary per sticker, so a wide sticker would render short
            // if the whole texture were sized. Crop to the opaque art so
            // the tray sizes what's actually visible.
            let trayTexture = SKTexture(rect: Self.opaqueBounds(of: texture), in: texture)
            trayContent.addChild(TrayItemNode(stickerID: sticker.id, texture: trayTexture))
        }
        trayClip.maskNode = trayMask
        trayClip.addChild(trayContent)
        tray.addChild(trayClip)
    }

    private func layoutTray() {
        guard let bar = tray.childNode(withName: "tray-bar") as? SKShapeNode else { return }
        let items = trayContent.children.compactMap { $0 as? TrayItemNode }
        guard !items.isEmpty else { return }

        let barHeight: CGFloat = min(96, max(64, size.height * 0.15))
        var itemSize = barHeight * 0.78
        var spacing = itemSize * 0.35
        var sidePadding = spacing * 1.6

        // The tray must always be fully visible with the buttons clear on
        // both sides; it scrolls, so in a narrow window it simply shows
        // fewer stickers — and shrinks them if even 1.5 wouldn't fit.
        let insets = view?.safeAreaInsets ?? .zero
        let leading = Self.trayLeadingClearance + insets.left
        let trailing = Self.trayTrailingClearance + insets.right
        let availableWidth = max(size.width - leading - trailing, 40)
        let minimumWidth = itemSize * 1.5 + 2 * sidePadding
        if availableWidth < minimumWidth {
            let shrink = availableWidth / minimumWidth
            itemSize *= shrink
            spacing *= shrink
            sidePadding *= shrink
        }
        // Every item gets the same height so the shelf reads as one row; wide
        // stickers (a snail, a butterfly) take the width they need rather
        // than shrinking to fit a square.
        let itemSizes = items.map { heightFit(texture: $0.texture, height: itemSize) }
        let rowWidth = itemSizes.reduce(0) { $0 + $1.width } + CGFloat(items.count - 1) * spacing
        let naturalWidth = rowWidth + 2 * sidePadding
        let barWidth = min(naturalWidth, availableWidth)
        let barCenterX = leading + availableWidth / 2

        let barCenterY = size.height - max(insets.top, Self.hudMinimumTopInset) - Self.hudTopClearance - barHeight / 2
        trayRectInView = CGRect(
            x: barCenterX - barWidth / 2, y: barCenterY - barHeight / 2,
            width: barWidth, height: barHeight)

        let barPath = CGPath(
            roundedRect: CGRect(x: -barWidth / 2, y: -barHeight / 2, width: barWidth, height: barHeight),
            cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
        bar.path = barPath
        // Mostly opaque: a glassier pill let white clouds behind it read as if
        // they were in front of it.
        bar.fillColor = UIColor.white.withAlphaComponent(0.86)
        // A faint dark edge (not white) so the pill keeps its shape over the
        // art's white clouds.
        bar.strokeColor = UIColor(red: 0.2, green: 0.3, blue: 0.25, alpha: 0.22)
        bar.lineWidth = 2
        bar.position = CGPoint(x: barCenterX, y: barCenterY)

        trayMask.path = barPath
        trayMask.fillColor = .white
        trayMask.strokeColor = .clear
        trayMask.position = CGPoint(x: barCenterX, y: barCenterY)

        maxTrayScrollOffset = max(0, naturalWidth - barWidth)

        let x0: CGFloat
        if maxTrayScrollOffset == 0 {
            // Everything fits — center the row, same look as before scrolling existed.
            x0 = barCenterX - rowWidth / 2
        } else {
            // Flush against the viewport's left edge; scrolling reveals the rest.
            x0 = barCenterX - barWidth / 2 + sidePadding
        }
        var x = x0
        for (item, itemSize) in zip(items, itemSizes) {
            // `size` is read and written through the node's current scale,
            // and the edge fade leaves off-screen items at 0.7 — assign
            // with the scale reset or those items come back 1/0.7 too big.
            item.setScale(1)
            item.size = itemSize
            item.position = CGPoint(x: x + itemSize.width / 2, y: barCenterY)
            item.zPosition = 1
            x += itemSize.width + spacing
        }

        // Preserve scroll position across re-layout (e.g. rotation), clamped
        // to whatever range is still valid.
        trayContent.position.x = min(0, max(-maxTrayScrollOffset, trayContent.position.x))

        updateTrayEdgeEffects()
    }

    /// One-shot "you can scroll" hint, played shortly after the tray appears
    /// when its content overflows: the shelf slides about one sticker's width
    /// and eases back, demonstrating the gesture itself — motion reads better
    /// than a chevron for pre-readers. Cancelled the moment a finger lands on
    /// the tray (touchesBegan), leaving the shelf wherever it was.
    private func runTrayScrollHint() {
        guard maxTrayScrollOffset > 0 else { return }
        let distance = min(maxTrayScrollOffset, trayRectInView.height * 0.85)
        let out = SKAction.moveTo(x: -distance, duration: 0.5)
        out.timingMode = .easeInEaseOut
        let back = SKAction.moveTo(x: 0, duration: 0.6)
        back.timingMode = .easeInEaseOut
        let slide = SKAction.sequence([.wait(forDuration: 0.8), out, .wait(forDuration: 0.2), back])
        // The edge fade tracks the shelf position, so refresh it every frame
        // for the hint's full 2.1s.
        let refreshEdges = SKAction.customAction(withDuration: 2.1) { [weak self] _, _ in
            self?.updateTrayEdgeEffects()
        }
        trayContent.run(.group([slide, refreshEdges]), withKey: Self.trayHintActionKey)
    }

    private static let trayHintActionKey = "tray-scroll-hint"

    /// Dissolves tray items out as they approach the pill's ends — alpha and
    /// a slight shrink, eased with smoothstep — instead of letting the crop
    /// chop them off. The half-faded sticker peeking from an edge doubles as
    /// the "there's more to scroll" hint, and it vanishes exactly when there
    /// isn't. Items are full-size whenever everything fits.
    private func updateTrayEdgeEffects() {
        let items = trayContent.children.compactMap { $0 as? TrayItemNode }
        guard maxTrayScrollOffset > 0 else {
            for item in items {
                item.alpha = 1
                item.setScale(1)
            }
            return
        }
        let fadeZone = trayRectInView.height * 0.72  // ≈ one item width
        for item in items {
            let sceneX = item.position.x + trayContent.position.x
            let edgeDistance = min(sceneX - trayRectInView.minX, trayRectInView.maxX - sceneX)
            let t = min(max(edgeDistance / fadeZone, 0), 1)
            let eased = t * t * (3 - 2 * t)
            item.alpha = eased
            item.setScale(0.7 + 0.3 * eased)
        }
    }

    /// The texture's non-transparent bounding box as a unit rect (origin
    /// bottom-left, like SpriteKit texture coordinates), measured on a
    /// coarse downsample so it costs nothing at load. Falls back to the
    /// whole texture when it can't be read or is fully transparent.
    private static func opaqueBounds(of texture: SKTexture) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let samples = 128
        var alpha = [UInt8](repeating: 0, count: samples * samples)
        guard let context = CGContext(
            data: &alpha, width: samples, height: samples, bitsPerComponent: 8, bytesPerRow: samples,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
        else { return full }
        context.draw(texture.cgImage(), in: CGRect(x: 0, y: 0, width: samples, height: samples))
        var minX = samples, minY = samples, maxX = -1, maxY = -1
        for y in 0..<samples {
            for x in 0..<samples where alpha[y * samples + x] > 16 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return full }
        // One sample of slack on each side so soft edges aren't clipped.
        let x0 = max(minX - 1, 0), y0 = max(minY - 1, 0)
        let x1 = min(maxX + 2, samples), y1 = min(maxY + 2, samples)
        let n = CGFloat(samples)
        return CGRect(x: CGFloat(x0) / n, y: CGFloat(y0) / n, width: CGFloat(x1 - x0) / n, height: CGFloat(y1 - y0) / n)
    }

    /// Scales the texture to a fixed height, keeping its aspect ratio.
    private func heightFit(texture: SKTexture?, height: CGFloat) -> CGSize {
        guard let texture, texture.size().width > 0, texture.size().height > 0 else {
            return CGSize(width: height, height: height)
        }
        let ts = texture.size()
        return CGSize(width: ts.width * height / ts.height, height: height)
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
        cameraNode.removeAction(forKey: Self.panHintActionKey)
        guard !isPlayLocked else {
            // Editing is locked while a story plays, but looking around is
            // fine: any touch pans.
            for touch in touches { beginPan(touch) }
            return
        }
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
            } else if hits.contains(where: { self.ancestor(of: $0, as: SelectionBubbleNode.self) != nil }) {
                // Tap on the bubble's chrome (not a button): ignore, so a
                // near-miss doesn't deselect or drop a sticker behind it.
            } else if let trayItem = hits.lazy.compactMap({ self.ancestor(of: $0, as: TrayItemNode.self) }).first {
                // A finger on the tray takes over from the scroll hint.
                trayContent.removeAction(forKey: Self.trayHintActionKey)
                // Defer: a horizontal move scrolls the tray, a vertical move
                // picks the sticker up, and no move at all is a tap-to-place.
                pendingTrayTouches[touch] = PendingTrayTouch(item: trayItem, startLocation: location)
            } else if hits.contains(where: { $0 === self.tray || $0.inParentHierarchy(self.tray) }) {
                // On the pill but between stickers: scroll the tray, never
                // the world behind it.
                trayContent.removeAction(forKey: Self.trayHintActionKey)
                trayScrolls[touch] = TrayScrollInfo(startLocation: location, startOffset: trayContent.position.x)
            } else if let sticker = topSticker(in: hits) {
                if activeTransform == nil,
                    let held = drags.first(where: { $0.value.node === sticker }) {
                    // Second finger on an already-held sticker → transform it.
                    // Inherit the drag's beforeSnapshot so the whole
                    // drag-then-pinch session commits as one undo step.
                    beginTransform(
                        of: sticker, touchA: held.key, touchB: touch,
                        beforeSnapshot: held.value.beforeSnapshot)
                } else {
                    beginDrag(
                        of: sticker, touch: touch, at: location, fromTray: false,
                        beforeSnapshot: snapshot())
                    select(sticker)
                }
            } else if activeTransform == nil, drags.count == 1, let held = drags.first {
                // Second finger on empty space while one sticker is held →
                // transform that sticker (forgiving for small hands).
                beginTransform(
                    of: held.value.node, touchA: held.key, touchB: touch,
                    beforeSnapshot: held.value.beforeSnapshot)
            } else {
                select(nil)
                beginPan(touch)
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
        for touch in touches where pans[touch] != nil { updatePan(for: touch) }
        guard !isPlayLocked else { return }
        for touch in touches {
            if let pending = pendingTrayTouches[touch] {
                resolvePendingTrayTouch(pending, touch: touch)
            } else if trayScrolls[touch] != nil {
                updateTrayScroll(for: touch)
            }
        }

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
                // A tap only settles back; a real move is the sticker lifting off.
                if !info.startedFromTray { UISounds.shared.play(.stickerUp) }
            }
            if info.moved { updateTrayHover(for: info.node) }
            drags[touch] = info
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { pans.removeValue(forKey: touch) }
        guard !isPlayLocked else { return }
        for touch in touches {
            if let pending = pendingTrayTouches.removeValue(forKey: touch) {
                // Never crossed the move threshold — a tap: place directly,
                // reusing the existing tap-to-place path unchanged (start
                // and current location match, so it "hops" onto the canvas).
                spawnSticker(from: pending.item, touch: touch, at: touch.location(in: self))
                endDrag(for: touch, cancelled: false)
                continue
            }
            trayScrolls.removeValue(forKey: touch)
            if endTransform(for: touch, cancelled: false) { continue }
            endDrag(for: touch, cancelled: false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { pans.removeValue(forKey: touch) }
        guard !isPlayLocked else { return }
        for touch in touches {
            pendingTrayTouches.removeValue(forKey: touch)
            trayScrolls.removeValue(forKey: touch)
            if endTransform(for: touch, cancelled: true) { continue }
            endDrag(for: touch, cancelled: true)
        }
    }

    /// Resolves a touch that started on a tray item once it's moved enough to
    /// mean something: whichever axis moved further wins — mostly-horizontal
    /// scrolls the tray, mostly-vertical-or-tied picks the sticker up (ties
    /// favor picking up, since that's the pre-existing, more common gesture).
    private func resolvePendingTrayTouch(_ pending: PendingTrayTouch, touch: UITouch) {
        let location = touch.location(in: self)
        let dx = location.x - pending.startLocation.x
        let dy = location.y - pending.startLocation.y
        guard dx * dx + dy * dy > Self.moveThresholdSquared else { return }
        pendingTrayTouches.removeValue(forKey: touch)
        if abs(dx) > abs(dy) {
            trayScrolls[touch] = TrayScrollInfo(startLocation: pending.startLocation, startOffset: trayContent.position.x)
            updateTrayScroll(for: touch)
        } else {
            spawnSticker(from: pending.item, touch: touch, at: location)
        }
    }

    private func updateTrayScroll(for touch: UITouch) {
        guard let info = trayScrolls[touch] else { return }
        let dx = touch.location(in: self).x - info.startLocation.x
        trayContent.position.x = min(0, max(-maxTrayScrollOffset, info.startOffset + dx))
        updateTrayEdgeEffects()
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
                name.hasPrefix(SelectionBubbleNode.ControlName.prefix),
                let bubble = ancestor(of: node, as: SelectionBubbleNode.self),
                let sticker = bubble.target {
                return (name, sticker)
            }
        }
        return nil
    }

    // MARK: Dragging

    private func spawnSticker(from trayItem: TrayItemNode, touch: UITouch, at location: CGPoint) {
        guard let texture = stickerTextures[trayItem.stickerID] else { return }
        // Captured before the node exists, so undoing a placement removes it
        // entirely rather than reverting to "no sticker at this spot".
        let before = snapshot()
        let node = StickerNode(
            stickerID: trayItem.stickerID, texture: texture,
            size: squareFit(texture: texture, side: stickerBaseSize),
            shadow: shadow(for: trayItem.stickerID))
        node.position = location
        node.setScale(0.3)
        foregroundStickers.addChild(node)
        node.run(.scale(to: 1.12, duration: 0.12))
        trayItem.pulse()
        softHaptic.impactOccurred()
        beginDrag(of: node, touch: touch, at: location, fromTray: true, beforeSnapshot: before)
    }

    private func beginDrag(
        of node: StickerNode, touch: UITouch, at location: CGPoint, fromTray: Bool,
        beforeSnapshot: CanvasState
    ) {
        let offset = CGPoint(x: node.position.x - location.x, y: node.position.y - location.y)
        drags[touch] = DragInfo(
            node: node, grabOffset: offset, startLocation: location,
            startedFromTray: fromTray, priorZ: node.zPosition, beforeSnapshot: beforeSnapshot)
        node.zPosition = 10000  // float above everything while held
        node.setLifted(true)
        if fromTray {
            UISounds.shared.play(.stickerUp)  // the sticker leaves the tray
        } else {
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
                    x: min(max(node.position.x, visibleRect.minX + stickerBaseSize), visibleRect.maxX - stickerBaseSize),
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
                UISounds.shared.play(.stickerPlace)
                notifyCanvasChanged(before: info.beforeSnapshot)
            } else {
                // Dropped on the tray: put the sticker away.
                removeSticker(node, haptic: !cancelled, before: info.beforeSnapshot)
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
        if !cancelled {
            firmHaptic.impactOccurred()
            UISounds.shared.play(.stickerPlace)
        }
        notifyCanvasChanged(before: info.beforeSnapshot)
    }

    /// Nudges a sticker back inside the world if dropped half off its edge,
    /// and keeps it out from under the tray. Anywhere along the art is fine,
    /// including parts currently panned out of view; vertically it stays in
    /// the visible band, since that is never panned.
    private func keepOnCanvas(_ node: StickerNode) {
        let margin = stickerBaseSize * 0.35
        node.position = CGPoint(
            x: min(max(node.position.x, worldExtent.minX + margin), worldExtent.maxX - margin),
            y: min(max(node.position.y, max(worldExtent.minY + margin, visibleRect.minY + margin)), trayRect.minY - margin * 0.6))
    }

    private func nextZ() -> CGFloat {
        nextZOrder += 1
        return nextZOrder
    }

    // MARK: Selection & controls

    private func select(_ node: StickerNode?) {
        guard selectedSticker !== node else { return }
        selectedSticker?.setSelected(false)
        selectionBubble?.removeFromParent()
        selectionBubble = nil
        selectedSticker = node
        if let node {
            node.setSelected(true)
            showSelectionBubble(for: node, animated: true)
        }
    }

    private func showSelectionBubble(for node: StickerNode, animated: Bool) {
        let bubble = SelectionBubbleNode(target: node)
        bubble.zPosition = 900  // above both sticker layers, below the tray
        bubble.position = bubblePosition(around: node.calculateAccumulatedFrame())
        addChild(bubble)
        if animated { bubble.popIn() }
        selectionBubble = bubble
    }

    /// Rebuilds the bubble (fresh layer glyph, fresh position) for the
    /// currently selected sticker.
    private func refreshSelectionBubble() {
        guard let selectedSticker else { return }
        selectionBubble?.removeFromParent()
        selectionBubble = nil
        showSelectionBubble(for: selectedSticker, animated: false)
    }

    /// Picks a spot for the fixed-size bubble near the sticker: above, below,
    /// right, then left — the first that fits inside the canvas and clear of
    /// the tray. Falls back to a clamped position above the sticker.
    private func bubblePosition(around frame: CGRect) -> CGPoint {
        let bubble = SelectionBubbleNode.size
        let gap: CGFloat = 12
        let usable = visibleRect.insetBy(dx: 8, dy: 8)
        let candidates = [
            CGPoint(x: frame.midX, y: frame.maxY + gap + bubble.height / 2),  // above
            CGPoint(x: frame.midX, y: frame.minY - gap - bubble.height / 2),  // below
            CGPoint(x: frame.maxX + gap + bubble.width / 2, y: frame.midY),  // right
            CGPoint(x: frame.minX - gap - bubble.width / 2, y: frame.midY),  // left
        ]
        func rect(at center: CGPoint) -> CGRect {
            CGRect(
                x: center.x - bubble.width / 2, y: center.y - bubble.height / 2,
                width: bubble.width, height: bubble.height)
        }
        for candidate in candidates {
            let candidateRect = rect(at: candidate)
            if usable.contains(candidateRect),
                !candidateRect.intersects(trayRect.insetBy(dx: -8, dy: -8)) {
                return candidate
            }
        }
        var fallback = candidates[0]
        fallback.x = min(max(fallback.x, usable.minX + bubble.width / 2), usable.maxX - bubble.width / 2)
        fallback.y = min(fallback.y, trayRect.minY - gap - bubble.height / 2)
        fallback.y = min(max(fallback.y, usable.minY + bubble.height / 2), usable.maxY - bubble.height / 2)
        return fallback
    }

    private func handleControlTap(_ control: String, on sticker: StickerNode) {
        switch control {
        case SelectionBubbleNode.ControlName.delete:
            let before = snapshot()
            select(nil)
            removeSticker(sticker, haptic: true, before: before)
        case SelectionBubbleNode.ControlName.layer:
            toggleLayer(of: sticker)
        default:
            break
        }
    }

    // MARK: Two-finger transform (pinch to scale, twist to rotate)

    private func beginTransform(
        of node: StickerNode, touchA: UITouch, touchB: UITouch, beforeSnapshot: CanvasState
    ) {
        // A drag that had already moved has played the lift; a resting finger
        // or a fresh pinch has not.
        let alreadyLifted = (drags[touchA]?.moved ?? false) || (drags[touchB]?.moved ?? false)
        drags.removeValue(forKey: touchA)
        drags.removeValue(forKey: touchB)
        if node.isSelected { select(nil) }  // hide controls while transforming
        if !alreadyLifted { UISounds.shared.play(.stickerUp) }

        let a = touchA.location(in: self)
        let b = touchB.location(in: self)
        activeTransform = TransformInfo(
            node: node, touchA: touchA, touchB: touchB,
            initialDistance: max(a.distance(to: b), 1),
            initialTouchAngle: atan2(b.y - a.y, b.x - a.x),
            initialScale: node.baseScale,
            initialRotation: node.zRotation,
            initialNodePosition: node.position,
            initialMidpoint: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
            beforeSnapshot: beforeSnapshot)
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

        // If the other finger is still down, hand the sticker back to a drag.
        let remaining = touch === transform.touchA ? transform.touchB : transform.touchA
        if !cancelled, remaining.phase == .began || remaining.phase == .moved || remaining.phase == .stationary {
            drags[remaining] = DragInfo(
                node: node,
                grabOffset: CGPoint(
                    x: node.position.x - remaining.location(in: self).x,
                    y: node.position.y - remaining.location(in: self).y),
                startLocation: remaining.location(in: self),
                startedFromTray: false, priorZ: node.zPosition,
                beforeSnapshot: transform.beforeSnapshot, moved: true)
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
        if !cancelled {
            firmHaptic.impactOccurred()
            UISounds.shared.play(.stickerPlace)
        }
        notifyCanvasChanged(before: transform.beforeSnapshot)
        return true
    }

    private func toggleLayer(of sticker: StickerNode) {
        let before = snapshot()
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
        refreshSelectionBubble()  // fresh layer glyph
        // A quick dip-and-return sells the "went behind / came forward" change.
        sticker.run(.sequence([
            .scale(to: sticker.baseScale * 0.9, duration: 0.1),
            .scale(to: sticker.baseScale, duration: 0.12),
        ]))
        softHaptic.impactOccurred()
        notifyCanvasChanged(before: before)
    }

    private func removeSticker(_ node: StickerNode, haptic: Bool, before: CanvasState) {
        if selectedSticker === node { select(nil) }
        node.run(.sequence([
            .group([.scale(to: 0.01, duration: 0.16), .fadeOut(withDuration: 0.16)]),
            .removeFromParent(),
        ]))
        if haptic { firmHaptic.impactOccurred() }
        notifyCanvasChanged(before: before)
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
                // `placement` is the child's base even mid-effect (play mode).
                let placement = node.placement
                placed.append(
                    PlacedSticker(
                        id: node.instanceID,
                        stickerID: node.stickerID,
                        position: NormalizedPoint(
                            x: placement.x / max(worldSize.width, 1),
                            y: placement.y / max(worldSize.height, 1)),
                        layer: layer,
                        zOrder: Int(node.zPosition),
                        scale: placement.scale,
                        rotation: placement.rotation))
            }
        }
        return CanvasState(packID: pack.id, stickers: placed)
    }

    private func notifyCanvasChanged(before: CanvasState) {
        // Removal animations complete in ~0.16s; snapshot after they settle.
        run(.sequence([
            .wait(forDuration: 0.2),
            .run { [weak self] in
                guard let self else { return }
                self.commitChange(before: before)
            },
        ]))
    }

    // MARK: Play mode (sticker effects)

    /// Locks or unlocks editing. Locking ends any gesture in flight as
    /// cancelled and hides the selection bubble, so nothing from edit mode
    /// can fight the effects. The tray fades out while locked — nothing can
    /// be placed during a story — and back in when the story ends or is
    /// stopped.
    func setPlayLocked(_ locked: Bool) {
        guard locked != isPlayLocked else { return }
        if locked {
            if let transform = activeTransform {
                _ = endTransform(for: transform.touchA, cancelled: true)
            }
            for touch in Array(drags.keys) { endDrag(for: touch, cancelled: true) }
            pendingTrayTouches.removeAll()
            trayScrolls.removeAll()
            pans.removeAll()
            select(nil)
        }
        isPlayLocked = locked
        // The items sit inside an SKCropNode, which does not pass its
        // parent's alpha on to what it clips (they would snap in and out
        // while the pill fades), so the pill and the clipped content are
        // faded individually rather than the tray as a whole.
        let fade = SKAction.fadeAlpha(to: locked ? 0 : 1, duration: locked ? 0.35 : 0.45)
        for node in [tray.childNode(withName: "tray-bar"), trayContent].compactMap({ $0 }) {
            node.run(fade, withKey: Self.trayFadeActionKey)
        }
    }

    /// Starts the effects pipeline for one story. Effects only exist between
    /// this call and `endPlayMode()`; leaving play mode is a hard reset.
    func beginPlayMode(story: Story, clock: PlaybackClock, policy: EffectPolicy) {
        endPlayMode()
        setPlayLocked(true)
        let nodes = allStickerNodes()
        let targets = Dictionary(grouping: nodes, by: \.stickerID).mapValues { $0.map(\.instanceID) }
        let triggers = loadTriggers(for: story)
        let runner = StickerEffectsRunner(triggers: triggers.sticker, targets: targets, policy: policy)
        let canvasRunner = CanvasEffectsRunner(
            triggers: triggers.canvas, setting: pack.manifest.setting, policy: policy)
        let applier = EffectApplier { [weak self] node in self?.glowMask(for: node) }
        applier.normalize(nodes)
        playSession = PlaySession(
            runner: runner, canvasRunner: canvasRunner, applier: applier, emitters: EmitterCoordinator(), clock: clock)
    }

    /// Restores the child's exact arrangement (P4) and tears the pipeline down.
    func endPlayMode() {
        if let session = playSession {
            session.runner.stopAll()
            session.canvasRunner.stopAll()
            session.emitters.clearAll()
            canvasEffects.clearAll()
            session.applier.restoreAll(stickerNodesByID())
            playSession = nil
        }
        setPlayLocked(false)
    }

    /// Reduce Motion / calm mode can change mid-story; applies to effects
    /// that start from now on.
    func setEffectPolicy(_ policy: EffectPolicy) {
        playSession?.runner.policy = policy
        playSession?.canvasRunner.policy = policy
    }

    /// The runner, for the debug gallery and tests; `nil` outside play mode.
    var effects: (any StickerEffects)? { playSession?.runner }

    override func update(_ currentTime: TimeInterval) {
        guard let session = playSession else { return }
        let time = session.clock.now()
        let nodes = stickerNodesByID()
        let deltas = session.runner.tick(time)
        session.applier.apply(deltas, to: nodes)
        session.emitters.reconcile(session.runner.active, at: time, nodes: nodes)
        canvasEffects.apply(session.canvasRunner.tick(time), at: time)
    }

    /// The sticker's blurred bloom mask, built once per sticker per pack.
    private func glowMask(for node: StickerNode) -> GlowMaskCache.Mask? {
        glowMasks.mask(for: node.stickerID) {
            guard let sticker = pack.sticker(withID: node.stickerID) else { return nil }
            return UIImage(contentsOfFile: pack.url(forAssetPath: sticker.image).path)
        }
    }

    /// The sticker's blurred drop shadow, built once per sticker per pack.
    private func shadow(for stickerID: String) -> StickerShadowCache.Shadow? {
        shadows.shadow(for: stickerID) {
            guard let sticker = pack.sticker(withID: stickerID) else { return nil }
            return UIImage(contentsOfFile: pack.url(forAssetPath: sticker.image).path)
        }
    }

    private func stickerNodesByID() -> [UUID: StickerNode] {
        Dictionary(uniqueKeysWithValues: allStickerNodes().map { ($0.instanceID, $0) })
    }

    /// Decodes the story's trigger sidecar. Problems are logged, never
    /// surfaced: a story with a broken sidecar plays with no effects.
    private func loadTriggers(for story: Story) -> (sticker: [EffectTrigger], canvas: [CanvasEffectTrigger]) {
        guard let path = story.effectsPath else { return ([], []) }
        do {
            let file = try EffectTriggerFile.load(from: pack.url(forAssetPath: path))
            for warning in file.warnings {
                Self.effectsLog.notice("\(story.id, privacy: .public): \(warning, privacy: .public)")
            }
            return (file.triggers, file.canvasTriggers)
        } catch {
            Self.effectsLog.error("\(story.id, privacy: .public): effects file unusable: \(String(describing: error), privacy: .public)")
            return ([], [])
        }
    }

    // MARK: History (undo/redo) & persistence

    /// Compares the settled canvas against the gesture's starting point; a
    /// tray item picked up and dropped straight back nets no change, so it's
    /// skipped entirely rather than logging a no-op undo step.
    private func commitChange(before: CanvasState) {
        let after = snapshot()
        guard after != before else { return }
        undoStack.append(before)
        if undoStack.count > Self.maxHistoryDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        stateStore.save(after)
        onCanvasChange?(after)
        reportHistory()
    }

    /// Rebuilds the sticker layers from a snapshot — shared by restore-on-load,
    /// undo, and redo. No landing animation; the change should read as instant.
    private func apply(_ state: CanvasState) {
        select(nil)
        backgroundStickers.removeAllChildren()
        foregroundStickers.removeAllChildren()
        for placed in state.stickers {
            guard let texture = stickerTextures[placed.stickerID] else { continue }
            let node = StickerNode(
                stickerID: placed.stickerID, texture: texture,
                size: squareFit(texture: texture, side: stickerBaseSize),
                shadow: shadow(for: placed.stickerID))
            node.position = CGPoint(x: placed.position.x * worldSize.width, y: placed.position.y * worldSize.height)
            node.baseScale = CGFloat(placed.scale)
            node.setScale(node.baseScale)
            node.zRotation = CGFloat(placed.rotation)
            node.zPosition = CGFloat(placed.zOrder)
            node.canvasLayer = placed.layer
            let parent = placed.layer == .foreground ? foregroundStickers : backgroundStickers
            parent.addChild(node)
        }
        nextZOrder = CGFloat((state.stickers.map(\.zOrder).max() ?? 0) + 1)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(previous)
        stateStore.save(previous)
        onCanvasChange?(previous)
        reportHistory()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
        stateStore.save(next)
        onCanvasChange?(next)
        reportHistory()
    }

    /// Wipes every sticker and the undo/redo history — a deliberate,
    /// non-undoable reset (the confirmation dialog is the only safety net).
    func clearCanvas() {
        guard !allStickerNodes().isEmpty else { return }
        select(nil)
        backgroundStickers.removeAllChildren()
        foregroundStickers.removeAllChildren()
        undoStack.removeAll()
        redoStack.removeAll()
        let empty = CanvasState(packID: pack.id)
        stateStore.save(empty)
        onCanvasChange?(empty)
        reportHistory()
    }

    private func reportHistory() {
        onHistoryChange?(canUndo, canRedo, canClear)
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
        // Relative to the resting scale — edge-faded items pulse at their size.
        let resting = xScale
        run(.sequence([.scale(to: resting * 0.85, duration: 0.08), .scale(to: resting, duration: 0.12)]))
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
