import StickerStoriesKit
import SwiftUI

/// One open story: the full-screen canvas with the playback overlay, a back
/// button, and undo/redo/clear. There is deliberately no grown-ups access
/// here — the only door out of the child experience is the main menu's More
/// stories card. Leaving still asks for confirmation (it's easy to bump by
/// accident); the canvas itself is preserved either way.
///
/// The pack's textures are decoded off the main thread first
/// (`PackTextureLoader`); until they are ready the screen shows a sky-to-
/// meadow gradient with bouncing dots, and the canvas is mounted only once
/// — at its final size — so opening a pack neither stalls nor re-lays out.
struct StoryScreen: View {
    let pack: LoadedPack
    let preferredLanguages: [String]
    /// Parent setting: softer effects (docs/effects.md, "calm mode").
    let calmMode: Bool
    let onLeave: () -> Void

    /// `nil` until the pack's textures are loaded.
    @State private var scene: CanvasScene?
    @State private var canvasState: CanvasState?
    @State private var playback = PlaybackController(
        storyProvider: BundledStoryProvider(recents: UserDefaultsRecentStories()),
        narrator: AudioFileNarrator())
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var canClear = false
    @State private var isConfirmingClear = false
    /// The loading screen is a deliberate beat, not a stall: it stays for
    /// at least this long, enough for the dots to bounce once, even though
    /// the textures usually load faster.
    private static let minimumLoadingTime: Duration = .milliseconds(800)
    /// Flipped as the load starts rather than initialised true: content that
    /// is only present in this screen's very first render never showed
    /// (SwiftUI dropped the branch as the screen was inserted), while a
    /// state change right after reliably brings it in.
    @State private var showsLoader = false

    init(pack: LoadedPack, preferredLanguages: [String], calmMode: Bool, onLeave: @escaping () -> Void) {
        self.pack = pack
        self.preferredLanguages = preferredLanguages
        self.calmMode = calmMode
        self.onLeave = onLeave
        #if DEBUG
        if Self.isAutoplay {
            // Deterministic pick (highest-scoring story) so a seeded canvas
            // always plays the same story.
            _playback = State(initialValue: PlaybackController(
                storyProvider: BundledStoryProvider(recents: UserDefaultsRecentStories(), random: { $0.lowerBound }),
                narrator: AudioFileNarrator()))
        }
        #endif
    }

    #if DEBUG
    private static var isAutoplay: Bool { ProcessInfo.processInfo.arguments.contains("-autoplay") }
    #endif

    private func play() {
        playback.play(
            canvas: canvasState ?? CanvasState(packID: pack.id),
            pack: pack,
            language: LanguageResolver(preferredLanguages: preferredLanguages)
                .resolve(from: pack.manifest.languages))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                loadingBackdrop
                if let scene {
                    CanvasView(
                        scene: scene,
                        onCanvasChange: { state in canvasState = state },
                        onHistoryChange: { undo, redo, clear in
                            canUndo = undo
                            canRedo = redo
                            canClear = clear
                        })
                    .id(pack.id)
                    .transition(.opacity)

                    PlaybackOverlay(
                        phase: playback.phase,
                        onPlay: play,
                        onStop: { playback.stop() })
                } else if showsLoader {
                    BouncingDots()
                        .accessibilityLabel("Loading")
                        .transition(.opacity)
                }

                let topPadding = Self.hudTopPadding(safeAreaTop: geometry.safeAreaInsets.top)
                if scene != nil {
                    backButton(topPadding: topPadding)
                    // Editing is locked while a story plays: the controls fade
                    // out and back in on the same timing as the sticker tray
                    // (`CanvasScene.setPlayLocked`).
                    historyControls(topPadding: topPadding)
                        .opacity(playback.isBusy ? 0 : 1)
                        .allowsHitTesting(!playback.isBusy)
                        .animation(.easeInOut(duration: playback.isBusy ? 0.35 : 0.45), value: playback.isBusy)
                }

                if isConfirmingClear {
                    clearConfirmation
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A swipe down from the top edge — easy to do by accident while
        // dragging a sticker out of the tray — shows the system's grabber
        // first instead of opening Notification Centre or Control Centre.
        .defersSystemGestures(on: .top)
        .task(id: pack.id) {
            withAnimation(.easeIn(duration: 0.2)) { showsLoader = true }
            let start = ContinuousClock.now
            let textures = await PackTextureLoader.load(pack)
            let elapsed = ContinuousClock.now - start
            if elapsed < Self.minimumLoadingTime {
                try? await Task.sleep(for: Self.minimumLoadingTime - elapsed)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showsLoader = false
                scene = CanvasScene(pack: pack, textures: textures, stateStore: FileCanvasStateStore())
            }
            #if DEBUG
            if Self.isAutoplay {
                try? await Task.sleep(for: .seconds(1.5))
                play()
            }
            #endif
        }
        .onChange(of: playback.phase) { _, phase in
            guard let scene else { return }
            // Effects exist only while a story plays; everything else is a
            // hard reset back to the child's arrangement.
            if case .playing(let story) = phase {
                scene.beginPlayMode(
                    story: story,
                    clock: PlaybackClock { [playback] in playback.playbackTime },
                    policy: effectPolicy)
            } else {
                scene.endPlayMode()
                scene.setPlayLocked(playback.isBusy)
            }
        }
        // Reduce Motion can be toggled mid-story (Control Centre); effects
        // that start from then on follow it.
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)) { _ in
            scene?.setEffectPolicy(effectPolicy)
        }
        .onChange(of: calmMode) { scene?.setEffectPolicy(effectPolicy) }
    }

    /// What shows while the pack loads and what the canvas fades in over: a
    /// soft sky above a soft meadow, so the art's own sky and ground take
    /// over from something that already looks like them.
    private var loadingBackdrop: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.60, green: 0.85, blue: 0.97), location: 0),
                .init(color: Color(uiColor: CanvasScene.skyColor), location: 0.45),
                .init(color: Color(red: 0.62, green: 0.84, blue: 0.66), location: 0.8),
                .init(color: Color(red: 0.78, green: 0.88, blue: 0.52), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }

    private var effectPolicy: EffectPolicy {
        EffectPolicy(reduceMotion: UIAccessibility.isReduceMotionEnabled, calmMode: calmMode)
    }

    /// Top padding for the corner buttons: the same row as the sticker tray
    /// (`CanvasScene.layoutTray`), which hangs below the larger of the safe
    /// area inset and a minimum, so the HUD keeps off the physical top edge
    /// on iPhones in landscape.
    private static func hudTopPadding(safeAreaTop: CGFloat) -> CGFloat {
        max(0, CanvasScene.hudMinimumTopInset - safeAreaTop) + CanvasScene.hudTopClearance
    }

    private func backButton(topPadding: CGFloat) -> some View {
        VStack {
            HStack {
                // No confirmation: the canvas is saved, so coming back
                // costs nothing and a stray tap is harmless.
                Button {
                    playback.stop()
                    onLeave()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(13)
                        .background(Self.hudButtonBackground(enabled: true))
                }
                .buttonStyle(SquishyButtonStyle())
                .accessibilityLabel("Back")
                .padding(.leading, 20)
                .padding(.top, topPadding)
                Spacer()
            }
            Spacer()
        }
    }

    /// Undo / redo / clear, top-trailing — small and secondary next to the
    /// play button, each disabled when it wouldn't do anything.
    private func historyControls(topPadding: CGFloat) -> some View {
        VStack {
            HStack {
                Spacer()
                // Editing is locked while a story plays.
                let editable = !playback.isBusy
                HStack(spacing: 10) {
                    historyButton(symbol: "arrow.uturn.backward", label: "Undo", enabled: canUndo && editable) {
                        scene?.undo()
                    }
                    historyButton(symbol: "arrow.uturn.forward", label: "Redo", enabled: canRedo && editable) {
                        scene?.redo()
                    }
                    historyButton(symbol: "trash", label: "Clear canvas", enabled: canClear && editable) {
                        isConfirmingClear = true
                    }
                }
                .padding(.trailing, 20)
                .padding(.top, topPadding)
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
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.65))
                .padding(10)
                .background(Self.hudButtonBackground(enabled: enabled))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel(label)
        .disabled(!enabled)
    }

    /// The round HUD buttons over the art: a solid dark disc with a thin
    /// light rim and a drop shadow so they read on any part of the scene.
    private static func hudButtonBackground(enabled: Bool) -> some View {
        Circle()
            .fill(.black.opacity(enabled ? 0.6 : 0.42))
            .overlay(Circle().strokeBorder(.white.opacity(enabled ? 0.6 : 0.35), lineWidth: 1.5))
            .shadow(color: .black.opacity(enabled ? 0.3 : 0.1), radius: 4, y: 2)
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
                        scene?.clearCanvas()
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

/// The loading indicator: three white dots bouncing in turn, like a ball
/// passed along — a toy, not a system spinner. Under Reduce Motion the dots
/// stay put and breathe instead.
struct BouncingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = t * 2 * .pi / 1.2 - Double(index) * 0.9
                    let lift = max(0, sin(phase))  // a half-sine: up, land, wait
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 3)
                        .offset(y: reduceMotion ? 0 : -18 * lift)
                        .opacity(reduceMotion ? 0.6 + 0.4 * lift : 1)
                }
            }
            .frame(height: 40, alignment: .bottom)
        }
    }
}
