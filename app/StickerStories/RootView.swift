import StickerStoriesKit
import SwiftUI

/// App shell. Hosts the SpriteKit canvas full-screen; SwiftUI overlays (play
/// button, playback HUD, Grown-Ups corner) layer on top.
struct RootView: View {
    private enum GrownUpsAccess: Identifiable {
        case gate, area
        var id: Self { self }
    }

    @State private var library = PackLibrary()
    @State private var canvasState: CanvasState?
    @State private var playback = PlaybackController(
        storyProvider: BundledStoryProvider(recents: UserDefaultsRecentStories()),
        narrator: AudioFileNarrator())
    @State private var entitlements = EntitlementCoordinator()
    @State private var grownUps: GrownUpsAccess?

    var body: some View {
        ZStack {
            Color(red: 0.49, green: 0.78, blue: 0.91)
                .ignoresSafeArea()
            if let pack = library.packs.first {
                CanvasView(pack: pack) { state in
                    canvasState = state
                }
                .id(pack.id)

                PlaybackOverlay(
                    phase: playback.phase,
                    onPlay: {
                        playback.play(
                            canvas: canvasState ?? CanvasState(packID: pack.id),
                            pack: pack)
                    },
                    onStop: { playback.stop() })

                grownUpsButton
            }
        }
        .persistentSystemOverlays(.hidden)
        .task {
            // Entitlement enforcement runs before pack discovery on every
            // launch (docs/commerce.md).
            await entitlements.validateOnLaunch()
            entitlements.startObservingTransactions()
            library.discoverPacks()
        }
        .sheet(item: $grownUps) { access in
            switch access {
            case .gate:
                ParentalGateView(
                    onSuccess: { grownUps = .area },
                    onCancel: { grownUps = nil })
                .presentationDetents([.medium, .large])
            case .area:
                GrownUpsView(store: StoreService(entitlements: entitlements))
            }
        }
    }

    /// Small, quiet corner button — the only door out of the child experience,
    /// and it opens onto the parental gate.
    private var grownUpsButton: some View {
        VStack {
            Spacer()
            HStack {
                Button {
                    playback.stop()
                    grownUps = .gate
                } label: {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(12)
                        .background(Circle().fill(.black.opacity(0.25)))
                }
                .buttonStyle(SquishyButtonStyle())
                .accessibilityLabel("Grown-ups area")
                .padding(.leading, 20)
                .padding(.bottom, 20)
                Spacer()
            }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
