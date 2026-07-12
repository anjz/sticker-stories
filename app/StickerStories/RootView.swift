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
    @State private var grownUps: GrownUpsAccess?

    var body: some View {
        ZStack {
            Color(red: 0.49, green: 0.78, blue: 0.91)
                .ignoresSafeArea()

            switch screen {
            case .menu:
                MainMenuView(
                    packs: library.packs,
                    preferredLanguages: Locale.preferredLanguages,
                    onSelectPack: { pack in
                        withAnimation(.spring(duration: 0.45)) { screen = .story(pack) }
                    },
                    onMoreStories: { grownUps = .gate })
                .transition(.opacity.combined(with: .scale(scale: 1.08)))
            case .story(let pack):
                StoryScreen(
                    pack: pack,
                    preferredLanguages: Locale.preferredLanguages,
                    onLeave: {
                        withAnimation(.spring(duration: 0.45)) { screen = .menu }
                    })
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
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
                GrownUpsView(
                    store: StoreService(entitlements: entitlements),
                    packs: library.packs)
            }
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
