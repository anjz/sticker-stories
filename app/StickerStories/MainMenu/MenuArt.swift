import ImageIO
import Observation
import SwiftUI
import UIKit

/// The app's own art (made with `tools/author/uiart`): the main screen's
/// background and the "Sticker Stories" title, bundled in `Art/`. Decoded
/// once, off the main thread and downsampled to the screen, and shared by
/// every screen that shows it — the menu and the pack loading screen — so
/// the loading screen has it ready the moment it appears.
@MainActor
@Observable
final class MenuArt {
    static let shared = MenuArt()

    private(set) var background: UIImage?
    private(set) var title: UIImage?
    private var started = false

    /// Longest side of the decoded background: a 13" iPad is 2752 px wide;
    /// the art is soft enough that a little upscaling beyond that is fine.
    private static let backgroundPixels = 2400
    /// The title is drawn at most ~40 % of the screen width.
    private static let titlePixels = 1200

    /// Starts decoding; safe to call from every screen's `task`.
    func load() {
        guard !started else { return }
        started = true
        Task {
            let backgroundURL = Bundle.main.url(forResource: "menu-background", withExtension: "webp")
            let titleURL = Bundle.main.url(forResource: "menu-title", withExtension: "webp")
            let backgroundPixels = Self.backgroundPixels, titlePixels = Self.titlePixels
            let (background, title) = await Task.detached(priority: .userInitiated) {
                (backgroundURL.flatMap { Thumbnail.load($0, maxPixelSize: backgroundPixels) },
                 titleURL.flatMap { Thumbnail.load($0, maxPixelSize: titlePixels) })
            }.value
            withAnimation(.easeOut(duration: 0.25)) {
                self.background = background
                self.title = title
            }
        }
    }
}

/// The menu background, filling the screen (cropped, never letterboxed);
/// the plain sky colour until it has decoded.
struct MenuBackground: View {
    private let art = MenuArt.shared

    var body: some View {
        Color(red: 0.49, green: 0.78, blue: 0.91)
            .overlay {
                if let background = art.background {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .ignoresSafeArea()
            .task { art.load() }
    }
}

/// Downsampled decoding with ImageIO: the file is read once and scaled on
/// the way in, so a 2048×1536 background never becomes a 12 MB bitmap just
/// to fill a card.
nonisolated enum Thumbnail {
    static func load(_ url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
