import SwiftUI

/// App shell. Hosts the SpriteKit canvas full-screen with SwiftUI overlays
/// (play button, playback HUD, Grown-Ups corner) layered on top.
struct RootView: View {
    var body: some View {
        ZStack {
            Color(red: 0.49, green: 0.78, blue: 0.91)
                .ignoresSafeArea()
            Text("Sticker Stories")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .persistentSystemOverlays(.hidden)
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
