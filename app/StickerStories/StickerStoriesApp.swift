import SwiftUI
import UIKit

@main
struct StickerStoriesApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear(perform: applyWindowSizePreference)
        }
    }

    /// iPadOS 26 windows are resizable and every orientation is supported
    /// (Apple TN3192: `UIRequiresFullScreen` is deprecated). The canvas
    /// adapts to any size, but below this the tray and controls collide, so
    /// express a preferred minimum. It is a preference the system may
    /// relax (rotation, Split View); nothing here may assume it holds.
    private func applyWindowSizePreference() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 440)
        }
    }
}
