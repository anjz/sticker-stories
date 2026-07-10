import SwiftUI
import StickerStoriesKit

/// App shell. Hosts the SpriteKit canvas full-screen with SwiftUI overlays
/// (play button, playback HUD, Grown-Ups corner) layered on top.
struct RootView: View {
    @State private var library = PackLibrary()

    var body: some View {
        ZStack {
            Color(red: 0.49, green: 0.78, blue: 0.91)
                .ignoresSafeArea()
            // Temporary shell proving the pack-loading path; the canvas
            // scene replaces this.
            if let pack = library.packs.first {
                VStack(spacing: 12) {
                    Text(pack.manifest.displayName)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("\(pack.manifest.stickers.count) stickers · \(pack.manifest.stories.count) stories")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white)
            } else {
                Text("Sticker Stories")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .persistentSystemOverlays(.hidden)
        .onAppear {
            library.discoverPacks()
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
