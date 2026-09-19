import StickerStoriesKit
import SwiftUI

/// App shell and navigation: the main menu (pack selection) and the story
/// screen, plus the gate→Grown-Ups sheet, which only the menu's More stories
/// card can open.
struct RootView: View {
    private enum GrownUpsAccess: Identifiable {
        case gate, area
        var id: Self { self }
    }

    private enum Screen: Equatable {
        case menu
        case story(LoadedPack)
    }

    @State private var screen: Screen = .menu
    @State private var library = PackLibrary()
    @State private var entitlements = EntitlementCoordinator()
    @State private var settings = AppSettings()
    @State private var grownUps: GrownUpsAccess?

    var body: some View {
        ZStack {
            Color(red: 0.49, green: 0.78, blue: 0.91)
                .ignoresSafeArea()

            #if DEBUG
            // `-effectsGallery` / `-effectsGalleryDemo` launch arguments open
            // the debug gallery instead of the app (no touch injection on
            // the simulator).
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-effectsGallery") }) {
                if let pack = library.packs.first { EffectsGalleryView(pack: pack) }
            } else {
                content
            }
            #else
            content
            #endif
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        // The parent language override retargets every catalog lookup live.
        .environment(\.locale, settings.uiLocale ?? Locale.autoupdatingCurrent)
        .task {
            // Entitlement enforcement runs before pack discovery on every
            // launch (docs/commerce.md).
            await entitlements.validateOnLaunch()
            entitlements.startObservingTransactions()
            library.discoverPacks()
            #if DEBUG
            // `-autoplay`: open the first pack and press play (simulator
            // verification of the playback pipeline without touch injection).
            // `-openPack`: only open it, silently (visual checks of the canvas).
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-autoplay") || args.contains("-openPack"), let pack = library.packs.first {
                screen = .story(pack)
            }
            #endif
        }
        .sheet(item: $grownUps) { access in
            Group {
                switch access {
                case .gate:
                    ParentalGateView(
                        onSuccess: { grownUps = .area },
                        onCancel: { grownUps = nil })
                    // Full-size from the start — no drag-to-resize needed.
                    .presentationDetents([.large])
                case .area:
                    GrownUpsView(
                        store: StoreService(entitlements: entitlements),
                        packs: library.packs,
                        settings: settings)
                }
            }
            // Sheets are separate presentation trees; re-apply the override.
            .environment(\.locale, settings.uiLocale ?? Locale.autoupdatingCurrent)
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch screen {
            case .menu:
                MainMenuView(
                    packs: library.packs,
                    preferredLanguages: settings.preferredLanguages,
                    onSelectPack: { pack in
                        withAnimation(.spring(duration: 0.45)) { screen = .story(pack) }
                    },
                    onMoreStories: { grownUps = .gate })
                .transition(.opacity.combined(with: .scale(scale: 1.08)))
            case .story(let pack):
                StoryScreen(
                    pack: pack,
                    preferredLanguages: settings.preferredLanguages,
                    calmMode: settings.calmMode,
                    onLeave: {
                        withAnimation(.spring(duration: 0.45)) { screen = .menu }
                    })
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
