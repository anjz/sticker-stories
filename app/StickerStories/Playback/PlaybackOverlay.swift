import StickerStoriesKit
import SwiftUI

/// The play button and the "story is playing" HUD, layered over the canvas.
/// Depends only on `PlaybackController.Phase` and a 0...1 progress reading —
/// never on how narration works.
struct PlaybackOverlay: View {
    let phase: PlaybackController.Phase
    /// Polled every frame while a story plays; `nil` leaves the ring empty.
    let progress: () -> Double?
    let onPlay: () -> Void
    let onStop: () -> Void
    /// Where the compact pill sits, in global coordinates, whenever that
    /// changes: the scene keeps story visitors from landing under it.
    var onCompactPillFrame: (CGRect) -> Void = { _ in }

    /// The playing pill shows the title for the first seconds of a story,
    /// then collapses to the waveform and the stop button so it stops
    /// covering the scene (it matters most on a phone).
    static let compactAfter: Duration = .seconds(8)
    @State private var isCompact = false

    /// The playing pill's padding around its contents, and its margin from
    /// the corner.
    private static let pillPadding = EdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 14)
    private static let pillMargin: CGFloat = 20

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            compactPillFootprint

            if showsPill {
                storyPill
            }

            if phase == .idle {
                playButton
                    .padding(.trailing, 28)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.spring(duration: 0.35), value: phase)
    }

    private var playButton: some View {
        Button(action: onPlay) {
            Image(systemName: "play.fill")
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(.white)
                .padding(26)
                .background(
                    Circle()
                        .fill(Color(red: 1.0, green: 0.72, blue: 0.15))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 4))
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("Play a story")
        .transition(.scale.combined(with: .opacity))
    }

    private var showsPill: Bool {
        if case .playing = phase { return true }
        return phase == .finished
    }

    private var isFinished: Bool { phase == .finished }

    private var playingStoryID: String? {
        if case .playing(let story) = phase { return story.id }
        return nil
    }

    /// Bottom-right, in the play button's corner. One pill serves both the
    /// playing HUD and "The End": it stays in place when the story finishes
    /// and resizes around the new contents, so the waveform and stop button
    /// turn into "The End" rather than one view replacing another.
    private var storyPill: some View {
        ZStack {
            if case .playing(let story) = phase {
                playingContents(title: story.title, compact: isCompact)
                    .transition(.opacity)
            } else {
                Text("The End")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.leading, isFinished ? 30 : Self.pillPadding.leading)
        .padding(.trailing, isFinished ? 30 : Self.pillPadding.trailing)
        .padding(.vertical, isFinished ? 12 : Self.pillPadding.top)
        // The shadow is part of the fill style: a view-level .shadow on a
        // translucent capsule rasterises as a hard-edged box on some
        // devices.
        .background(Capsule().fill(.black.opacity(0.55).shadow(.drop(color: .black.opacity(0.2), radius: 8, y: 4))))
        .overlay(progressRing.opacity(isFinished ? 0 : 1))
        .padding(.trailing, Self.pillMargin)
        .padding(.bottom, Self.pillMargin)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: playingStoryID) {
            isCompact = false
            guard playingStoryID != nil,
                  (try? await Task.sleep(for: Self.compactAfter)) != nil else { return }
            withAnimation(.spring(duration: 0.5)) { isCompact = true }
        }
    }

    /// Where the pill sits once it is compact — the waveform and the stop
    /// button, as it stays for most of a story — measured on an invisible
    /// copy of it, there before a story starts.
    private var compactPillFootprint: some View {
        playingContents(title: "", compact: true)
            .padding(Self.pillPadding)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCompactPillFrame($0) }
            .padding(.trailing, Self.pillMargin)
            .padding(.bottom, Self.pillMargin)
    }

    /// The title sits in a frame that animates to zero width when the pill
    /// goes compact, so the capsule shrinks towards the right around the
    /// waveform and the stop button rather than the title popping out.
    private func playingContents(title: String, compact isCompact: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 12)
                .frame(width: isCompact ? 0 : nil, alignment: .trailing)  // nil hugs the title
                .clipped()
                .opacity(isCompact ? 0 : 1)
                .accessibilityHidden(isCompact)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(.white.opacity(0.25)))
            }
            .buttonStyle(SquishyButtonStyle())
            .accessibilityLabel("Stop the story")
            .padding(.leading, 12)
        }
    }

    /// A translucent white line tracing the pill's outline clockwise from the
    /// bottom centre as the story plays, over a faint track. Follows the pill
    /// as it collapses to compact; completes and fades as it becomes "The End".
    private var progressRing: some View {
        TimelineView(.animation) { _ in
            let lineWidth: CGFloat = 6
            let outline = CapsuleOutline().inset(by: lineWidth / 2)
            ZStack {
                outline.stroke(.white.opacity(0.08), lineWidth: lineWidth)
                outline
                    .trim(from: 0, to: isFinished ? 1 : progress() ?? 0)
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A capsule whose path starts at the bottom centre and runs clockwise, so a
/// trimmed stroke fills like a progress ring (`Capsule`'s own path starts
/// elsewhere).
nonisolated private struct CapsuleOutline: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.midY), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius,
                    startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> CapsuleOutline {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

/// Buttons that squash a little when pressed — reads as a toy, not chrome.
struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
