import StickerStoriesKit
import SwiftUI

/// One open story: the full-screen canvas with the playback overlay, a back
/// button, and undo/redo/clear. There is deliberately no grown-ups access
/// here — the only door out of the child experience is the main menu's More
/// stories card. Leaving still asks for confirmation (it's easy to bump by
/// accident); the canvas itself is preserved either way.
struct StoryScreen: View {
    let pack: LoadedPack
    let preferredLanguages: [String]
    let onLeave: () -> Void

    @State private var scene: CanvasScene
    @State private var canvasState: CanvasState?
    @State private var playback = PlaybackController(
        storyProvider: BundledStoryProvider(recents: UserDefaultsRecentStories()),
        narrator: AudioFileNarrator())
    @State private var isConfirmingLeave = false
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var canClear = false
    @State private var isConfirmingClear = false

    init(pack: LoadedPack, preferredLanguages: [String], onLeave: @escaping () -> Void) {
        self.pack = pack
        self.preferredLanguages = preferredLanguages
        self.onLeave = onLeave
        _scene = State(initialValue: CanvasScene(pack: pack, stateStore: FileCanvasStateStore()))
    }

    var body: some View {
        ZStack {
            CanvasView(
                scene: scene,
                onCanvasChange: { state in canvasState = state },
                onHistoryChange: { undo, redo, clear in
                    canUndo = undo
                    canRedo = redo
                    canClear = clear
                })
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
            historyControls

            if isConfirmingLeave {
                leaveConfirmation
            }
            if isConfirmingClear {
                clearConfirmation
            }
        }
        .onChange(of: playback.phase) { _, phase in
            // Effects exist only while a story plays; everything else is a
            // hard reset back to the child's arrangement.
            if case .playing(let story) = phase {
                scene.beginPlayMode(
                    story: story,
                    clock: PlaybackClock { [playback] in playback.playbackTime },
                    policy: .standard)
            } else {
                scene.endPlayMode()
                scene.setPlayLocked(playback.isBusy)
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

    /// Undo / redo / clear, top-trailing — small and secondary next to the
    /// play button, each disabled when it wouldn't do anything.
    private var historyControls: some View {
        VStack {
            HStack {
                Spacer()
                // Editing is locked while a story plays.
                let editable = !playback.isBusy
                HStack(spacing: 10) {
                    historyButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: canUndo && editable) {
                        scene.undo()
                    }
                    historyButton(symbol: "arrow.uturn.forward", label: "Redo", enabled: canRedo && editable) {
                        scene.redo()
                    }
                    historyButton(symbol: "trash", label: "Clear canvas", enabled: canClear && editable) {
                        isConfirmingClear = true
                    }
                }
                .padding(.trailing, 20)
                .padding(.top, 14)
            }
            Spacer()
        }
    }

    private func historyButton(
        symbol: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.35))
                .padding(10)
                .background(Circle().fill(.black.opacity(enabled ? 0.25 : 0.12)))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel(label)
        .disabled(!enabled)
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

    /// Clear is final — there's no undoing it, so this confirmation is the
    /// only safety net. An X cancels; the trash confirms and wipes the canvas.
    private var clearConfirmation: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isConfirmingClear = false }

            VStack(spacing: 24) {
                Text("Clear the canvas?")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))

                HStack(spacing: 34) {
                    confirmationButton(
                        symbol: "xmark", label: "Cancel",
                        fill: Color(red: 0.36, green: 0.6, blue: 0.9)
                    ) {
                        isConfirmingClear = false
                    }
                    confirmationButton(
                        symbol: "trash.fill", label: "Clear",
                        fill: Color(red: 0.86, green: 0.3, blue: 0.3)
                    ) {
                        isConfirmingClear = false
                        scene.clearCanvas()
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
