import StickerStoriesKit
import SwiftUI

/// One open story: the full-screen canvas with the playback overlay and a
/// back button. There is deliberately no grown-ups access here — the only
/// door out of the child experience is the main menu's More stories card.
/// Leaving asks for confirmation because the canvas starts fresh next time.
struct StoryScreen: View {
    let pack: LoadedPack
    let preferredLanguages: [String]
    let onLeave: () -> Void

    @State private var canvasState: CanvasState?
    @State private var playback = PlaybackController(
        storyProvider: BundledStoryProvider(recents: UserDefaultsRecentStories()),
        narrator: AudioFileNarrator())
    @State private var isConfirmingLeave = false

    var body: some View {
        ZStack {
            CanvasView(pack: pack) { state in
                canvasState = state
            }
            .id(pack.id)

            PlaybackOverlay(
                phase: playback.phase,
                onPlay: {
                    playback.play(
                        canvas: canvasState ?? CanvasState(packID: pack.id),
                        pack: pack,
                        language: LanguageResolver(preferredLanguages: preferredLanguages)
                            .resolve(from: pack.manifest.languages))
                },
                onStop: { playback.stop() })

            backButton

            if isConfirmingLeave {
                leaveConfirmation
            }
        }
    }

    private var backButton: some View {
        VStack {
            HStack {
                Button {
                    isConfirmingLeave = true
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(13)
                        .background(Circle().fill(.black.opacity(0.25)))
                }
                .buttonStyle(SquishyButtonStyle())
                .accessibilityLabel("Back")
                .padding(.leading, 20)
                .padding(.top, 14)
                Spacer()
            }
            Spacer()
        }
    }

    /// Child-friendly confirmation: a house to go back to the menu, an X to
    /// keep playing. Tapping the dimmed background also stays.
    private var leaveConfirmation: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isConfirmingLeave = false }

            VStack(spacing: 24) {
                Text("Leave the story?")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))

                HStack(spacing: 34) {
                    confirmationButton(
                        symbol: "xmark", label: "Stay",
                        fill: Color(red: 0.36, green: 0.6, blue: 0.9)
                    ) {
                        isConfirmingLeave = false
                    }
                    confirmationButton(
                        symbol: "house.fill", label: "Leave",
                        fill: Color(red: 1.0, green: 0.72, blue: 0.15)
                    ) {
                        playback.stop()
                        onLeave()
                    }
                }
            }
            .padding(38)
            .background(
                RoundedRectangle(cornerRadius: 34)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 8))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private func confirmationButton(
        symbol: String, label: LocalizedStringKey, fill: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(fill).shadow(color: .black.opacity(0.2), radius: 5, y: 3))
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                Text(label)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
            }
        }
        .buttonStyle(SquishyButtonStyle())
    }
}
