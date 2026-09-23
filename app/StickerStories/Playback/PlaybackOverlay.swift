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

    /// The playing pill shows the title for the first seconds of a story,
    /// then collapses to the waveform and the stop button so it stops
    /// covering the scene (it matters most on a phone).
    static let compactAfter: Duration = .seconds(8)
    @State private var isCompact = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if case .playing(let story) = phase {
                playingHUD(for: story)
            } else if phase == .finished {
                theEnd
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

    /// Bottom-right, in the play button's corner. The title sits in a frame
    /// that animates to zero width when the pill goes compact, so the
    /// capsule shrinks towards the right around the waveform and the stop
    /// button rather than the title popping out.
    private func playingHUD(for story: Story) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 0) {
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text(story.title)
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
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .padding(.vertical, 14)
            // The shadow is part of the fill style: a view-level .shadow on a
            // translucent capsule rasterises as a hard-edged box on some
            // devices.
            .background(Capsule().fill(.black.opacity(0.55).shadow(.drop(color: .black.opacity(0.2), radius: 8, y: 4))))
            .overlay(progressRing)
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: story.id) {
            isCompact = false
            guard (try? await Task.sleep(for: Self.compactAfter)) != nil else { return }
            withAnimation(.spring(duration: 0.5)) { isCompact = true }
        }
    }

    /// A translucent white line tracing the pill's outline clockwise from the
    /// bottom centre as the story plays, over a faint track. Follows the pill
    /// as it collapses to compact.
    private var progressRing: some View {
        TimelineView(.animation) { _ in
            let lineWidth: CGFloat = 6
            let outline = CapsuleOutline().inset(by: lineWidth / 2)
            ZStack {
                outline.stroke(.white.opacity(0.08), lineWidth: lineWidth)
                outline
                    .trim(from: 0, to: progress() ?? 0)
                    .stroke(.white.opacity(0.45), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var theEnd: some View {
        VStack {
            Spacer()
            Text("The End")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .transition(.scale.combined(with: .opacity))
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
