import SwiftUI
import UIKit

/// The loading indicator: three white dots bouncing in turn, like a ball
/// passed along — a toy, not a system spinner. Under Reduce Motion the dots
/// stay put and breathe instead.
///
/// Drawn with Core Animation rather than SwiftUI: the animations are handed
/// to the render server once and run there, so the bounce stays perfectly
/// fluid while the main thread is busy opening the pack (the screen
/// transition, building the scene). A SwiftUI `TimelineView` needs the main
/// thread every frame and stutters exactly then.
struct BouncingDots: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> BouncingDotsView { BouncingDotsView() }

    func updateUIView(_ view: BouncingDotsView, context: Context) {
        view.reduceMotion = reduceMotion
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BouncingDotsView, context: Context) -> CGSize? {
        BouncingDotsView.size
    }
}

final class BouncingDotsView: UIView {
    static let size = CGSize(width: 3 * dot + 2 * gap, height: dot + lift + 8)

    private static let dot: CGFloat = 18
    private static let gap: CGFloat = 14
    /// How high a dot jumps.
    private static let lift: CGFloat = 22
    /// One dot's full cycle: jump, land, rest while the others go.
    private static let cycle: CFTimeInterval = 1.2
    /// Each dot starts this much after the one before it.
    private static let stagger: CFTimeInterval = 0.14

    private var dots: [CALayer] = []
    private var shadows: [CALayer] = []

    var reduceMotion = false {
        didSet {
            guard reduceMotion != oldValue else { return }
            startAnimating()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        for _ in 0..<3 {
            // A soft contact shadow on the ground, under each dot.
            let shadow = CALayer()
            shadow.backgroundColor = UIColor.black.withAlphaComponent(0.14).cgColor
            shadow.bounds = CGRect(x: 0, y: 0, width: Self.dot * 0.9, height: 5)
            shadow.cornerRadius = 2.5
            // Blurred edges: a layer shadow of the same colour around it,
            // with an explicit path so it costs nothing per frame.
            shadow.shadowColor = UIColor.black.cgColor
            shadow.shadowOpacity = 0.25
            shadow.shadowRadius = 2
            shadow.shadowOffset = .zero
            shadow.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: 2.5).cgPath
            layer.addSublayer(shadow)
            shadows.append(shadow)

            let dot = CALayer()
            dot.backgroundColor = UIColor.white.cgColor
            dot.bounds = CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot)
            dot.cornerRadius = Self.dot / 2
            // Squash and stretch happen about the dot's base, so it lands
            // flat on the ground rather than shrinking into the air.
            dot.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(dot)
            dots.append(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { Self.size }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ground = bounds.maxY - 6
        let left = bounds.midX - Self.size.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<3 {
            let x = left + Self.dot / 2 + CGFloat(index) * (Self.dot + Self.gap)
            dots[index].position = CGPoint(x: x, y: ground)
            shadows[index].position = CGPoint(x: x, y: ground + 2)
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startAnimating() }
    }

    private func startAnimating() {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for index in 0..<3 {
            let dot = dots[index], shadow = shadows[index]
            dot.removeAllAnimations()
            shadow.removeAllAnimations()
            // A negative begin time starts every dot already mid-wave, so the
            // row is moving from the very first frame.
            let begin = now - Self.cycle + Double(index) * Self.stagger
            if reduceMotion {
                dot.add(Self.breathe(begin: begin), forKey: "breathe")
            } else {
                dot.add(Self.bounce(begin: begin), forKey: "bounce")
                shadow.add(Self.shadowFollow(begin: begin), forKey: "shadow")
            }
        }
    }

    // MARK: Animations

    /// Up on an ease-out, down on an ease-in (gravity), a quick squash as it
    /// lands and a small stretch as it leaves the ground, then a rest.
    private static func bounce(begin: CFTimeInterval) -> CAAnimation {
        let rise = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.35, 1)
        let fall = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.8, 0.35)
        let settle = CAMediaTimingFunction(name: .easeOut)

        let height = CAKeyframeAnimation(keyPath: "transform.translation.y")
        height.keyTimes = [0, 0.06, 0.3, 0.54, 1]
        height.values = [0, 0, -lift, 0, 0]
        height.timingFunctions = [settle, rise, fall, settle]

        let width = CAKeyframeAnimation(keyPath: "transform.scale.x")
        width.keyTimes = [0, 0.06, 0.14, 0.3, 0.54, 0.6, 0.7, 1]
        width.values = [1, 1.12, 0.92, 1, 1, 1.2, 1, 1]
        width.timingFunctions = Array(repeating: settle, count: 7)

        let tall = CAKeyframeAnimation(keyPath: "transform.scale.y")
        tall.keyTimes = width.keyTimes
        tall.values = [1, 0.84, 1.1, 1, 1, 0.76, 1, 1]
        tall.timingFunctions = width.timingFunctions

        return group([height, width, tall], begin: begin)
    }

    /// The contact shadow shrinks and fades as its dot rises.
    private static func shadowFollow(begin: CFTimeInterval) -> CAAnimation {
        let rise = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.35, 1)
        let fall = CAMediaTimingFunction(controlPoints: 0.6, 0, 0.8, 0.35)
        let settle = CAMediaTimingFunction(name: .easeOut)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale.x")
        scale.keyTimes = [0, 0.06, 0.3, 0.54, 1]
        scale.values = [1, 1, 0.5, 1, 1]
        scale.timingFunctions = [settle, rise, fall, settle]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = scale.keyTimes
        fade.values = [1, 1, 0.35, 1, 1]
        fade.timingFunctions = scale.timingFunctions

        return group([scale, fade], begin: begin)
    }

    /// Reduce Motion: no movement, a slow brightness wave along the row.
    private static func breathe(begin: CFTimeInterval) -> CAAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = [0, 0.3, 0.6, 1]
        fade.values = [0.55, 1, 0.55, 0.55]
        fade.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 3)
        return group([fade], begin: begin)
    }

    private static func group(_ animations: [CAAnimation], begin: CFTimeInterval) -> CAAnimation {
        // Each part spans the whole cycle (a part's own duration would
        // otherwise default to a quarter of a second).
        for animation in animations { animation.duration = cycle }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = cycle
        group.beginTime = begin
        group.repeatCount = .infinity
        // Keep running when the app comes back from the background.
        group.isRemovedOnCompletion = false
        return group
    }
}
