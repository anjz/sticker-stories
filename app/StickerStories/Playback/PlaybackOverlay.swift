import StickerStoriesKit
import SwiftUI

/// The play button and the "story is playing" HUD, layered over the canvas.
/// Depends only on `PlaybackController.Phase` — never on how narration works.
struct PlaybackOverlay: View {
    let phase: PlaybackController.Phase
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

    /// Bottom-left, out of the way of the art. The title sits in a frame
    /// that animates to zero width when the pill goes compact, so the
    /// capsule shrinks around the waveform and the stop button rather than
    /// the title popping out.
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
                    .frame(width: isCompact ? 0 : nil, alignment: .leading)  // nil hugs the title
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
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            // The shadow is part of the fill style: a view-level .shadow on a
            // translucent capsule rasterises as a hard-edged box on some
            // devices.
            .background(Capsule().fill(.black.opacity(0.55).shadow(.drop(color: .black.opacity(0.2), radius: 8, y: 4))))
            .padding(.leading, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: story.id) {
            isCompact = false
            guard (try? await Task.sleep(for: Self.compactAfter)) != nil else { return }
            withAnimation(.spring(duration: 0.5)) { isCompact = true }
        }
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

/// Buttons that squash a little when pressed — reads as a toy, not chrome.
struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
