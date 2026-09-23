import StickerStoriesKit
import SwiftUI

/// App shell and navigation: the main menu (pack selection), the story
/// screen and the store. The store (the menu's More stories card) and the
/// parent settings (the menu's gear) are both reached only through the
/// parental gate, presented as a sheet.
struct RootView: View {
    /// What the gate sheet is showing: the gate itself, on its way to one of
    /// the grown-ups destinations, or the settings it opened.
    private enum GrownUpsAccess: Identifiable {
        case gate(to: Destination)
        case settings
        var id: String {
            switch self {
            case .gate(let destination): "gate-\(destination)"
            case .settings: "settings"
            }
        }
    }

    private enum Destination {
        case store, settings
    }

    private enum Screen: Equatable {
        case menu
        case story(LoadedPack)
        case store
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
            // `-openGate`: show the parental gate (visual checks of it).
            if args.contains("-openGate") { grownUps = .gate(to: .store) }
            // `-openStore`: straight into the store, skipping the gate.
            if args.contains("-openStore") { screen = .store }
            #endif
        }
        .sheet(item: $grownUps) { access in
            Group {
                switch access {
                case .gate(let destination):
                    ParentalGateView(
                        onSuccess: {
                            switch destination {
                            case .settings:
                                grownUps = .settings
                            case .store:
                                grownUps = nil
                                withAnimation(.spring(duration: 0.45)) { screen = .store }
                            }
                        },
                        onCancel: { grownUps = nil })
                    // Full-size from the start — no drag-to-resize needed.
                    .presentationDetents([.large])
                case .settings:
                    SettingsView(settings: settings, galleryPack: library.packs.first)
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
                    onMoreStories: { grownUps = .gate(to: .store) },
                    onSettings: { grownUps = .gate(to: .settings) })
                .transition(.opacity.combined(with: .scale(scale: 1.08)))
            case .story(let pack):
                StoryScreen(
                    pack: pack,
                    preferredLanguages: settings.preferredLanguages,
                    calmMode: settings.calmMode,
                    onLeave: {
                        withAnimation(.spring(duration: 0.45)) { screen = .menu }
                    })
                // A plain crossfade: a scale-in would show the root's
                // background around the loading screen for the whole spring.
                .transition(.opacity)
            case .store:
                StoreScreen(
                    store: StoreService(entitlements: entitlements),
                    packs: library.packs,
                    settings: settings,
                    onClose: {
                        withAnimation(.spring(duration: 0.45)) { screen = .menu }
                    })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
