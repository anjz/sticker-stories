import SpriteKit
import StickerStoriesKit
import UIKit

/// A short, wordless demo of a canvas gesture a child has never used,
/// played on a sample sticker that is not part of their canvas: a hand's
/// fingertips pinch it bigger and turn it (`pinch`), or a hand taps it and
/// then the layer button so it slips behind the scenery and comes back
/// (`layer`). About six seconds each; `CanvasScene` decides when
/// (`CanvasHintSchedule`) and where, and cancels it the moment the child
/// touches the screen.
@MainActor
final class CanvasHintDemo {
    /// What the demo draws with and on, from the scene.
    struct Stage {
        /// The sticker layers: the sample starts in front and the layer
        /// demo moves it to the back one and returns it.
        let front: SKNode
        let back: SKNode
        /// Where the hands, touch rings and bubble go (the scene: world
        /// coordinates, like the sticker layers).
        let overlay: SKNode
        let hand: SKTexture
        /// The index fingertip in the hand art, as its anchor point.
        let handTip: CGPoint
        let handHeight: CGFloat
        /// Where the scene would show the selection bubble for a sticker.
        let bubblePosition: (CGRect) -> CGPoint
    }

    static let pinchDuration: TimeInterval = 6.0
    static let layerDuration: TimeInterval = 6.2

    private let stage: Stage
    private var nodes: [SKNode] = []
    private let driver = SKNode()
    private var bubble: SelectionBubbleNode?
    /// Where the layer demo's bubble will open, worked out before the
    /// sticker pops in (its frame is only its real size before that).
    private var pendingBubblePosition: CGPoint?

    init(stage: Stage) {
        self.stage = stage
    }

    /// Plays `hint` on `sticker` (a fresh node, not yet in the tree) at
    /// `spot`, then calls `completion` — unless cancelled first.
    func play(_ hint: CanvasHint, sticker: StickerNode, at spot: CGPoint, completion: @escaping () -> Void) {
        cancel()
        sticker.isVisitor = true  // never part of the child's canvas
        sticker.position = spot
        sticker.zPosition = Self.onTopZ
        sticker.alpha = 0
        stage.front.addChild(sticker)
        nodes.append(sticker)
        stage.overlay.addChild(driver)
        switch hint {
        case .pinch: playPinch(sticker, completion: completion)
        case .layer: playLayer(sticker, completion: completion)
        }
    }

    /// Removes everything at once; the completion never runs.
    func cancel() {
        driver.removeAllActions()
        driver.removeFromParent()
        for node in nodes {
            node.removeAllActions()
            node.removeFromParent()
        }
        nodes.removeAll()
        bubble = nil
        pendingBubblePosition = nil
    }

    // MARK: Pinch

    /// Two hands from below put a fingertip on each side of the sticker,
    /// spread (it grows), turn together (it turns), come back, lift off.
    private func playPinch(_ sticker: StickerNode, completion: @escaping () -> Void) {
        let left = makeHand(mirrored: false), right = makeHand(mirrored: true)
        let leftRing = makeRing(), rightRing = makeRing()
        let centre = sticker.position
        let width = sticker.size.width
        let turn: CGFloat = .pi * 35 / 180
        let maxScale: CGFloat = 1.55

        let step = SKAction.customAction(withDuration: Self.pinchDuration) { _, elapsed in
            let t = Double(elapsed)
            // Keyframes: appear, press, spread, turn, back, release, leave.
            let appear = Self.ease(t, 0.0, 0.45)
            let spread = Self.ease(t, 0.9, 2.3) - Self.ease(t, 3.7, 4.8)
            let twist = Self.ease(t, 2.4, 3.6) - Self.ease(t, 3.7, 4.8)
            let pressed = Self.ease(t, 0.7, 0.85) - Self.ease(t, 4.85, 5.0)
            let leave = Self.ease(t, 5.1, 5.8)

            let scale = 1 + (maxScale - 1) * CGFloat(spread)
            let angle = turn * CGFloat(twist)
            sticker.alpha = CGFloat(appear * (1 - leave))
            sticker.setScale(CGFloat(Self.popIn(appear)) * scale * CGFloat(1 - 0.4 * leave))
            sticker.zRotation = angle

            let half = width * 0.3 * scale
            let tips = [
                CGPoint(x: centre.x - half * cos(angle), y: centre.y - half * sin(angle)),
                CGPoint(x: centre.x + half * cos(angle), y: centre.y + half * sin(angle)),
            ]
            let drop = self.stage.handHeight * 0.35 * CGFloat((1 - appear) + leave)
            for (hand, tip) in zip([left, right], tips) {
                hand.position = CGPoint(x: tip.x, y: tip.y - drop)
                hand.alpha = CGFloat(appear * (1 - leave))
                Self.press(hand, by: 0.07 * CGFloat(pressed))
            }
            for (ring, tip) in zip([leftRing, rightRing], tips) {
                ring.position = tip
                ring.alpha = CGFloat(pressed) * 0.9
            }
        }
        driver.run(.sequence([step, .run { [weak self] in
            self?.cancel()
            completion()
        }]))
    }

    // MARK: Layer

    /// A hand taps the sticker (its bubble opens), taps the layer button
    /// (the sticker slips behind the scenery), taps it again (it comes
    /// back to the front) and leaves.
    private func playLayer(_ sticker: StickerNode, completion: @escaping () -> Void) {
        let centre = sticker.position
        let size = sticker.size.width
        // The hand comes from the side the bubble opens on (above the
        // sticker unless it is near the top) so it never covers the
        // sticker while it goes behind the scenery and comes back.
        let bubbleAt = stage.bubblePosition(sticker.calculateAccumulatedFrame())
        pendingBubblePosition = bubbleAt
        let fromAbove = bubbleAt.y > centre.y
        // The art is a left hand seen from the back. From above it hangs
        // down pointing down and a little left; from below it is the right
        // hand (mirrored), pointing up and a little left.
        let hand = makeHand(mirrored: !fromAbove)
        if fromAbove { hand.zRotation = .pi - 0.35 }
        let ring = makeRing()
        let side: CGFloat = fromAbove ? 1 : -1
        let start = CGPoint(x: centre.x + size * 0.9, y: centre.y + side * size * 1.3)
        // The first tap lands on the sticker's edge nearest the hand.
        let onSticker = CGPoint(x: centre.x, y: centre.y + side * sticker.size.height * 0.25)
        var button = onSticker
        var events = Set<Int>()

        let step = SKAction.customAction(withDuration: Self.layerDuration) { [weak self] _, elapsed in
            guard let self else { return }
            let t = Double(elapsed)
            let appear = Self.ease(t, 0.0, 0.4)
            let leave = Self.ease(t, 5.2, 6.0)
            // Each switch of layer dips the sticker, like the real button.
            let dip = [2.3, 3.9].map { Self.ease(t, $0, $0 + 0.1) - Self.ease(t, $0 + 0.1, $0 + 0.22) }.max() ?? 0
            sticker.alpha = CGFloat(appear * (1 - leave))
            sticker.setScale(CGFloat(Self.popIn(appear)) * CGFloat(1 - 0.4 * leave) * CGFloat(1 - 0.1 * dip))

            // Taps at 1.1 (the sticker), 2.3 (to the back) and 3.9 (to
            // the front again).
            let fire = { (id: Int, at: Double, action: () -> Void) in
                if t >= at, events.insert(id).inserted { action() }
            }
            fire(1, 1.1) { self.showBubble(for: sticker, animated: true) }
            if let bubble = self.bubble {
                button = CGPoint(x: bubble.position.x - 34, y: bubble.position.y)
            }
            fire(2, 2.3) { self.switchLayer(of: sticker) }
            fire(3, 3.9) { self.switchLayer(of: sticker) }
            if t >= 5.2, let bubble = self.bubble {
                bubble.alpha = CGFloat(1 - leave)
            }

            let toSticker = Self.ease(t, 0.35, 0.95)
            let toButton = Self.ease(t, 1.45, 2.05)
            var tip = CGPoint(
                x: start.x + (onSticker.x - start.x) * CGFloat(toSticker),
                y: start.y + (onSticker.y - start.y) * CGFloat(toSticker))
            tip.x += (button.x - tip.x) * CGFloat(toButton)
            tip.y += (button.y - tip.y) * CGFloat(toButton)
            let pressed = [0.95, 2.15, 3.75].map { Self.ease(t, $0, $0 + 0.12) - Self.ease(t, $0 + 0.2, $0 + 0.32) }.max() ?? 0
            // It leaves the way it came.
            let drop = self.stage.handHeight * 0.3 * CGFloat(leave)
            hand.position = CGPoint(x: tip.x + drop * 0.5, y: tip.y + side * drop)
            hand.alpha = CGFloat(Self.ease(t, 0.2, 0.5) * (1 - leave))
            Self.press(hand, by: 0.08 * CGFloat(pressed))
            ring.position = tip
            ring.alpha = CGFloat(pressed) * 0.9
        }
        driver.run(.sequence([step, .run { [weak self] in
            self?.cancel()
            completion()
        }]))
    }

    private func showBubble(for sticker: StickerNode, animated: Bool) {
        let position = bubble?.position ?? pendingBubblePosition ?? stage.bubblePosition(sticker.calculateAccumulatedFrame())
        bubble?.removeFromParent()
        let new = SelectionBubbleNode(target: sticker)
        new.zPosition = 900
        new.position = position
        stage.overlay.addChild(new)
        if animated { new.popIn() }
        nodes.append(new)
        bubble = new
    }

    /// What the layer button does, on the sample: the other sticker layer,
    /// a dip, and the bubble's glyph updated.
    private func switchLayer(of sticker: StickerNode) {
        let toBack = sticker.canvasLayer == .foreground
        sticker.canvasLayer = toBack ? .background : .foreground
        sticker.move(toParent: toBack ? stage.back : stage.front)
        sticker.zPosition = Self.onTopZ
        showBubble(for: sticker, animated: false)
    }

    // MARK: Pieces

    /// On top of the child's stickers, inside the layer's band
    /// (`CanvasScene.layerDepth` is 40).
    private static let onTopZ: CGFloat = 45

    private func makeHand(mirrored: Bool) -> SKSpriteNode {
        let texture = stage.hand
        let aspect = texture.size().width / max(texture.size().height, 1)
        let hand = SKSpriteNode(texture: texture, size: CGSize(width: stage.handHeight * aspect, height: stage.handHeight))
        hand.anchorPoint = mirrored ? CGPoint(x: 1 - stage.handTip.x, y: stage.handTip.y) : stage.handTip
        if mirrored { hand.xScale = -1 }
        // The art is a left hand seen from the back (knuckles to the
        // viewer); mirrored, the right one. Leaning in from below, towards
        // the middle: the left hand points up and right, the right one up
        // and left.
        hand.zRotation = mirrored ? 0.35 : -0.35
        hand.zPosition = 960
        hand.alpha = 0
        // The hand casts the same soft shadow as a lifted sticker.
        let shadow = SKSpriteNode(texture: texture, size: hand.size)
        shadow.anchorPoint = hand.anchorPoint
        shadow.color = .black
        shadow.colorBlendFactor = 1
        shadow.alpha = 0.22
        shadow.position = CGPoint(x: 6, y: -8)
        shadow.zPosition = -1
        hand.addChild(shadow)
        stage.overlay.addChild(hand)
        nodes.append(hand)
        return hand
    }

    private func makeRing() -> SKShapeNode {
        let ring = SKShapeNode(circleOfRadius: stage.handHeight * 0.12)
        ring.fillColor = UIColor.white.withAlphaComponent(0.35)
        ring.strokeColor = .white
        ring.lineWidth = 3
        ring.zPosition = 955
        ring.alpha = 0
        stage.overlay.addChild(ring)
        nodes.append(ring)
        return ring
    }

    /// Shrinks a hand a little as its finger presses, keeping a mirrored
    /// hand mirrored.
    private static func press(_ hand: SKSpriteNode, by amount: CGFloat) {
        hand.xScale = (hand.xScale < 0 ? -1 : 1) * (1 - amount)
        hand.yScale = 1 - amount
    }

    /// 0 before `from`, 1 after `to`, smoothstep between.
    private static func ease(_ t: Double, _ from: Double, _ to: Double) -> Double {
        let p = min(max((t - from) / (to - from), 0), 1)
        return p * p * (3 - 2 * p)
    }

    /// A little overshoot on the way in.
    private static func popIn(_ p: Double) -> Double {
        guard p < 1 else { return 1 }
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}
