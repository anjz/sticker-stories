#if DEBUG
import StickerStoriesKit
import SwiftUI

/// Developer-only: plays any story of any installed pack on demand, at 1×,
/// 2× or 3×, so stories and how the stickers behave in them can be checked
/// quickly. The canvas starts empty and lives only in memory — every
/// character a story names comes in as a visitor, stickers dragged from the
/// tray stay until the gallery closes, and the child's own canvas is never
/// touched. Reached from Settings in debug builds; never compiled into
/// release.
struct StoryGalleryView: View {
    let packs: [LoadedPack]
    let preferredLanguages: [String]
    @Environment(\.dismiss) private var dismiss

    @State private var packID: String
    @State private var language = ""
    @State private var speed = 1.0
    @State private var scene: CanvasScene?
    @State private var canvasState: CanvasState?
    @State private var narrator = RateNarrator()
    @State private var playback: PlaybackController?

    private static let speeds: [Double] = [1, 2, 3]

    init(packs: [LoadedPack], preferredLanguages: [String]) {
        self.packs = packs
        self.preferredLanguages = preferredLanguages
        let first = packs.first { $0.id == "forest" } ?? packs.first
        _packID = State(initialValue: Self.launchPack ?? first?.id ?? "")
        _speed = State(initialValue: Self.launchSpeed ?? 1)
    }

    private var pack: LoadedPack? { packs.first { $0.id == packID } ?? packs.first }
    private var isBusy: Bool { playback?.isBusy ?? false }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color(red: 0.49, green: 0.78, blue: 0.91).ignoresSafeArea()
            if let scene {
                CanvasView(scene: scene, onCanvasChange: { canvasState = $0 }, onHistoryChange: { _, _, _ in })
                    .id(ObjectIdentifier(scene))
            } else {
                BouncingDots()
            }

            if let playback, playback.isBusy {
                PlaybackOverlay(
                    phase: playback.phase,
                    progress: { playback.playbackProgress },
                    onPlay: {},
                    onStop: { playback.stop() })
                speedBadge
            } else {
                panel
            }
        }
        .task(id: packID) { await loadScene() }
        .onChange(of: speed) { narrator.rate = speed }
        .onChange(of: playback?.phase) { _, phase in
            guard let scene, let playback else { return }
            if case .playing(let story) = phase {
                scene.speed = speed
                scene.beginPlayMode(
                    story: story,
                    clock: PlaybackClock(rate: { [narrator] in narrator.rate }) { [playback] in playback.playbackTime },
                    policy: EffectPolicy(reduceMotion: UIAccessibility.isReduceMotionEnabled, calmMode: false))
            } else {
                scene.endPlayMode()
                scene.speed = 1
                scene.setPlayLocked(playback.isBusy)
            }
        }
        .onChange(of: speed) { if isBusy { scene?.speed = speed } }
        .onDisappear { playback?.stop() }
    }

    /// The pack, language and speed pickers and a button per story.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Story gallery")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 26))
                }
                .accessibilityLabel("Close")
            }
            Picker("Pack", selection: $packID) {
                ForEach(packs) { pack in
                    Text(verbatim: pack.manifest.displayName[language] ?? pack.manifest.displayName.values.first ?? pack.id)
                        .tag(pack.id)
                }
            }
            .pickerStyle(.menu)
            if let pack, pack.manifest.languages.count > 1 {
                Picker("Language", selection: $language) {
                    ForEach(pack.manifest.languages, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("Speed", selection: $speed) {
                ForEach(Self.speeds, id: \.self) { Text(verbatim: "\(Int($0))×").tag($0) }
            }
            .pickerStyle(.segmented)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(stories) { story in
                        Button { play(story) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: story.title)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                Text(verbatim: story.id)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                        .disabled(scene == nil)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 330)
        .background(.regularMaterial)
    }

    /// The speed a story is playing at, over the canvas, top left.
    private var speedBadge: some View {
        Text(verbatim: "\(Int(speed))×")
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.5)))
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The pack's stories in the chosen language, in manifest order.
    private var stories: [Story] {
        guard let pack else { return [] }
        return pack.manifest.stories.map { Story($0, language: language, fallbackOrder: pack.manifest.languages) }
    }

    private func loadScene() async {
        playback?.stop()
        scene = nil
        guard let pack else { return }
        if !pack.manifest.languages.contains(language) {
            language = LanguageResolver(preferredLanguages: preferredLanguages).resolve(from: pack.manifest.languages)
        }
        let textures = await PackTextureLoader.load(pack)
        guard !Task.isCancelled else { return }
        let scene = CanvasScene(pack: pack, textures: textures, stateStore: EphemeralCanvasStateStore())
        scene.hintsAllowed = false
        self.scene = scene
        if let id = Self.launchStory, let story = stories.first(where: { $0.id == id }) {
            try? await Task.sleep(for: .seconds(1.5))
            play(story)
        }
    }

    private func play(_ story: Story) {
        guard let pack else { return }
        playback?.stop()
        narrator.rate = speed
        let controller = PlaybackController(storyProvider: ChosenStoryProvider(story: story), narrator: narrator)
        playback = controller
        controller.play(canvas: canvasState ?? CanvasState(packID: pack.id), pack: pack, language: language)
    }

    // `-storyGallery [-storyGalleryPack forest] [-storyGalleryPlay <story id>]
    // [-storyGallerySpeed 3]`: straight to the gallery, playing a story
    // (simulator checks without touch injection).
    private static func argument(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static var launchPack: String? { argument(after: "-storyGalleryPack") }
    private static var launchStory: String? { argument(after: "-storyGalleryPlay") }
    private static var launchSpeed: Double? { argument(after: "-storyGallerySpeed").flatMap(Double.init) }
}

/// The story the gallery was asked for, whatever the canvas holds.
private struct ChosenStoryProvider: StoryProvider {
    let story: Story
    func story(for canvas: CanvasState, in pack: LoadedPack, language: String) async throws -> Story { story }
}

/// A canvas that starts empty and is never saved.
private struct EphemeralCanvasStateStore: CanvasStateStore {
    func load(packID: String) -> CanvasState? { nil }
    func save(_ state: CanvasState) {}
}
#endif
