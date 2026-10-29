import CoreImage
import SpriteKit
import StickerStoriesKit

/// Draws `wash` (`docs/effects.md`): for every running one on a sticker
/// with open water above it when it was cued, a big wave washing up the
/// whole beach and back — coming in from the left, running furthest where
/// the sticker is — a thin sheet of water with a lacy foam front, and the
/// sand it covered left dark and wet for a while. The beach (`Wash.Beach`)
/// is worked out once, when it is cued; the timing is the Kit's, a pure
/// function of the timeline. Drawn on the ground in art points mapped to
/// the scene — so it lies in the painted beach's plane — over the
/// background art and under every sticker and the scene's layers, clipped
/// to the land by the open water (never over the rocks or into a pool).
@MainActor
final class WashCoordinator {
    /// The beach a wash cued on a sticker at a time runs over; nil when
    /// there is no open water above it.
    var beach: (StickerNode, TimeInterval) -> Wash.Beach? = { _, _ in nil }
    /// The land the sea washes over, in scene points: the water and its
    /// foam are clipped to it. Nil: unclipped.
    var land: () -> CGPath? = { nil }
    /// The size of the base art in scene points: an art point (u, v) is at
    /// (u × width, v × height).
    var art: () -> CGSize = { .zero }
    /// Under the stickers and the scene's layers (`StoryStage.farZ`), over
    /// the background art.
    static let z: CGFloat = 259

    private var washes: [EffectHandle: (node: WashNode, beach: Wash.Beach)] = [:]
    private var dry: Set<EffectHandle> = []

    func reconcile(_ active: [ActiveEffect], at time: TimeInterval, nodes: [UUID: StickerNode], in scene: SKNode) {
        var shown = Set<EffectHandle>()
        for effect in active where effect.name == .wash && !dry.contains(effect.handle) {
            guard let sticker = nodes[effect.target], let frame = Wash.frame(of: effect, at: time) else { continue }
            if washes[effect.handle] == nil {
                guard let beach = beach(sticker, effect.startTime) else {
                    dry.insert(effect.handle)
                    continue
                }
                let node = WashNode(land: land())
                node.zPosition = Self.z
                scene.addChild(node)
                washes[effect.handle] = (node, beach)
            }
            guard let wash = washes[effect.handle] else { continue }
            shown.insert(effect.handle)
            wash.node.show(frame, on: wash.beach, art: art())
        }
        for (handle, wash) in washes where !shown.contains(handle) {
            wash.node.removeFromParent()
            washes[handle] = nil
        }
        dry = dry.intersection(Set(active.map(\.handle)))
    }

    /// Takes every wash away at once (playback over).
    func clearAll() {
        for wash in washes.values { wash.node.removeFromParent() }
        washes.removeAll()
        dry.removeAll()
    }
}

/// One wash: the wet sand, a faint sheet of water from the shore to its
/// front with a brighter film just behind the front (soft-edged, like wet
/// watercolour), and two lines of foam — the lacy front and a fainter one
/// trailing behind it.
@MainActor
final class WashNode: SKNode {
    private let crop = SKCropNode()
    private let wet = SKShapeNode()
    private let sheet = SKShapeNode()
    private let film = SKShapeNode()
    private let soft = SKEffectNode()
    private var foam: [SKSpriteNode] = []
    private var splashes: [SKSpriteNode] = []
    private let land: CGPath?

    // The sand it leaves a little darker; the water clear, a pale
    // turquoise film over the sand.
    private static let wetColor = UIColor(red: 0.47, green: 0.38, blue: 0.27, alpha: 1)
    private static let sheetColor = UIColor(red: 0.62, green: 0.88, blue: 0.90, alpha: 1)
    private static let filmColor = UIColor(red: 0.86, green: 0.97, blue: 0.98, alpha: 1)

    init(land: CGPath?) {
        self.land = land
        super.init()
        addChild(crop)
        if let land {
            let mask = SKShapeNode(path: land)
            mask.fillColor = .white
            mask.strokeColor = .clear
            crop.maskNode = mask
        }
        for (shape, color) in [(wet, Self.wetColor), (sheet, Self.sheetColor), (film, Self.filmColor)] {
            shape.fillColor = color
            shape.strokeColor = .clear
        }
        crop.addChild(wet)
        soft.filter = CIFilter(name: "CIGaussianBlur")
        soft.shouldEnableEffects = true
        soft.zPosition = 0.1
        soft.addChild(sheet)
        film.zPosition = 0.1
        soft.addChild(film)
        crop.addChild(soft)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ frame: Wash.Frame, on beach: Wash.Beach, art: CGSize) {
        guard art.width > 0, !beach.shore.isEmpty else { return }
        // A gentle one to a full one (default 0.6 and up: full).
        let opacity = CGFloat(frame.opacity * min(1, 0.4 + frame.intensity))
        func point(_ u: Double, _ v: Double) -> CGPoint { CGPoint(x: u * art.width, y: v * art.height) }

        // Column by column: the shore, how far the water is up the beach
        // now, how far it has been.
        struct Column { var u, shore, front, film, reached, up: Double }
        let columns = beach.shore.map { s -> Column in
            let local = Wash.local(frame.phase, across: s.u)
            let depth = beach.depth(at: s.u, shore: s.v)
            let up = Wash.front(at: local)
            let front = s.v - depth * up
            return Column(
                u: s.u, shore: s.v, front: front, film: front + (s.v - front) * 0.35,
                reached: s.v - depth * Wash.reached(at: local), up: up)
        }
        func band(_ top: (Column) -> Double, _ bottom: (Column) -> Double) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: columns.map { point($0.u, top($0)) } + columns.reversed().map { point($0.u, bottom($0)) })
            path.closeSubpath()
            return path
        }
        // (A little way out into the sea, so the sheet melts into it.)
        let out = 0.012
        wet.path = band({ $0.shore }, { $0.reached })
        let local = Wash.local(frame.phase, across: beach.reach.u)
        wet.alpha = CGFloat(0.22 * Wash.wet(at: local)) * opacity
        sheet.path = band({ $0.shore + out }, { $0.front })
        sheet.alpha = 0.22 * opacity
        film.path = band({ $0.film }, { $0.front })
        film.alpha = 0.42 * opacity
        soft.filter?.setValue(max(1.5, 0.004 * art.height), forKey: kCIInputRadiusKey)

        // Foam: the lacy front, and a fainter line trailing behind it; on
        // the beach only, smaller further back like the painted foam.
        let rows: [(fraction: Double, alpha: CGFloat, scale: CGFloat)] = [(0, 0.9, 1), (0.12, 0.5, 0.75), (0.35, 0.25, 0.6)]
        var shown = 0
        for row in rows {
            for (k, c) in columns.enumerated() where c.up > 0.03 {
                let lace = sin(c.u * 140 + frame.phase * 7 + Double(k) * 0.7) * cos(c.u * 37 + row.fraction * 9)
                let v = c.front + (c.shore - c.front) * row.fraction + 0.0025 * lace
                let p = point(c.u, v)
                guard land?.contains(p) ?? true else { continue }
                if shown == foam.count {
                    let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "foam"))
                    sprite.color = .white
                    sprite.colorBlendFactor = 1
                    sprite.zPosition = 0.2
                    addChild(sprite)
                    foam.append(sprite)
                }
                let sprite = foam[shown]
                shown += 1
                sprite.isHidden = false
                sprite.position = p
                let d = art.height * CGFloat(0.009 * (1.3 - v)) * row.scale * CGFloat(1 + 0.3 * abs(lace))
                sprite.size = CGSize(width: d * 3.4, height: d)
                sprite.alpha = row.alpha * opacity * CGFloat(min(c.up / 0.15, 1))
            }
        }
        for sprite in foam.dropFirst(shown) { sprite.isHidden = true }
        splash(frame, on: beach, art: art, opacity: opacity)
    }

    /// Where the water runs out of beach on its way to the sticker (the
    /// rocks round a pool): it breaks over them in a burst of foam that
    /// rises and falls back, into the pool beyond, as the water gets
    /// there. Nothing where it reaches the sticker on the beach.
    private func splash(_ frame: Wash.Frame, on beach: Wash.Beach, art: CGSize, opacity: CGFloat) {
        let u = beach.reach.u
        let local = Wash.local(frame.phase, across: u)
        guard let land, let top = beach.edge(at: u) else { return }
        func point(_ v: Double) -> CGPoint { CGPoint(x: u * art.width, y: v * art.height) }
        // The last of the beach down the sticker's column.
        var rim = top
        while rim - 0.002 > beach.reach.v, land.contains(point(rim - 0.002)) { rim -= 0.002 }
        let depth = beach.depth(at: u, shore: top)
        guard rim - beach.reach.v > 0.02, depth > 0 else {
            for sprite in splashes { sprite.isHidden = true }
            return
        }
        // From when the front gets to the rim till a little after.
        let there = (top - rim) / depth
        var start = 0.0
        while start < 0.35, Wash.front(at: start) < there { start += 0.005 }
        let t = (local - start) / 0.3
        while splashes.count < 14 {
            let sprite = SKSpriteNode(texture: EffectTextures.texture(named: "foam"))
            sprite.color = .white
            sprite.colorBlendFactor = 1
            sprite.zPosition = 0.3
            addChild(sprite)
            splashes.append(sprite)
        }
        let size = art.height * CGFloat(0.02 * (1.3 - rim))
        for (k, sprite) in splashes.enumerated() {
            guard t > 0, t < 1 else {
                sprite.isHidden = true
                continue
            }
            sprite.isHidden = false
            let spread = Double(k) / 13 - 0.5
            let rise = sin(.pi * t) * (0.6 + 0.4 * cos(Double(k) * 2.3))
            let base = point(rim - 0.01 * t)
            sprite.position = CGPoint(
                x: base.x + CGFloat(spread) * size * 4 + CGFloat(t) * size * 0.8,
                y: base.y + CGFloat(rise) * size * 1.6)
            let d = size * CGFloat(0.6 + 0.4 * abs(cos(Double(k) * 1.7))) * CGFloat(1 - 0.4 * t)
            sprite.size = CGSize(width: d * 1.8, height: d)
            sprite.alpha = 0.85 * opacity * CGFloat(min(1, (1 - t) * 3))
        }
    }
}
