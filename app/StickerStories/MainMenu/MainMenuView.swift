import ImageIO
import StickerStoriesKit
import SwiftUI
import UIKit

/// The landing screen. Almost all of it is pack selection: one big card per
/// available pack, sliding horizontally, with a final "More stories" card
/// that opens the grown-ups area (gate first — it is the only door out of
/// the child experience).
struct MainMenuView: View {
    let packs: [LoadedPack]
    let preferredLanguages: [String]
    let onSelectPack: (LoadedPack) -> Void
    let onMoreStories: () -> Void

    var body: some View {
        GeometryReader { geo in
            // Portrait iPad is tall and narrow: cap the height against the
            // width so cards stay card-shaped in every orientation.
            let cardHeight = min(geo.size.height * 0.66, geo.size.width * 0.66)
            let cardWidth = min(geo.size.width * 0.48, cardHeight * 1.1)

            VStack(spacing: 0) {
                Text(verbatim: "Sticker Stories")
                    .font(.system(size: min(52, geo.size.height * 0.09), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 3)
                    .padding(.top, geo.size.height * 0.06)

                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(packs) { pack in
                            Button {
                                onSelectPack(pack)
                            } label: {
                                PackMenuCard(pack: pack, preferredLanguages: preferredLanguages)
                                    .frame(width: cardWidth, height: cardHeight)
                            }
                            .buttonStyle(SquishyButtonStyle())
                        }

                        Button(action: onMoreStories) {
                            MoreStoriesCard()
                                .frame(width: cardWidth, height: cardHeight)
                        }
                        .buttonStyle(SquishyButtonStyle())
                        .accessibilityLabel("More stories")
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, max(24, (geo.size.width - cardWidth) / 2 - 26))
                    .padding(.vertical, 20)
                }
                .scrollTargetBehavior(.viewAligned)
                // The cards' shadows fall outside the scroll view's bounds.
                .scrollClipDisabled()

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One selectable pack: its background art fills the card, a few stickers
/// spill over it, and the localized name sits in a banner at the bottom.
/// The art is shown from small thumbnails decoded off the main thread — the
/// full-size pack images are decoded only when the pack is opened.
private struct PackMenuCard: View {
    let pack: LoadedPack
    let preferredLanguages: [String]

    @State private var background: UIImage?
    @State private var stickers: [UIImage] = []

    /// Longest side of the background thumbnail: a card is at most ~0.42 of
    /// the screen width, well under this at 2× or 3×.
    private static let backgroundPixels = 1200
    /// The spilled stickers are 76 pt tall.
    private static let stickerPixels = 256

    var body: some View {
        let language = LanguageResolver(preferredLanguages: preferredLanguages)
            .resolve(from: pack.manifest.languages)

        ZStack(alignment: .bottom) {
            if let background {
                // Overlay on a clear base so the fill-scaled image cannot
                // inflate the card's layout size (it would in portrait).
                Color.clear.overlay {
                    Image(uiImage: background)
                        .resizable()
                        .scaledToFill()
                }
            } else {
                Color(red: 0.55, green: 0.8, blue: 0.5)
            }

            stickerSpill
                .padding(.bottom, 66)

            Text(pack.manifest.displayName(for: language))
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.38))
        }
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.9), lineWidth: 4))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
        .task(id: pack.id) {
            let backgroundURL = pack.url(forAssetPath: pack.manifest.background)
            let stickerURLs = pack.manifest.stickers.prefix(3).map { pack.url(forAssetPath: $0.image) }
            let backgroundPixels = Self.backgroundPixels, stickerPixels = Self.stickerPixels
            let (backgroundThumbnail, stickerThumbnails) = await Task.detached(priority: .userInitiated) {
                (Thumbnail.load(backgroundURL, maxPixelSize: backgroundPixels),
                 stickerURLs.compactMap { Thumbnail.load($0, maxPixelSize: stickerPixels) })
            }.value
            background = backgroundThumbnail
            stickers = stickerThumbnails
        }
    }

    private var stickerSpill: some View {
        HStack(spacing: 8) {
            ForEach(Array(stickers.enumerated()), id: \.offset) { index, image in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 76)
                    .rotationEffect(.degrees(index % 2 == 0 ? -9 : 9))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            }
        }
    }
}

/// Downsampled decoding with ImageIO: the file is read once and scaled on
/// the way in, so a 2048×1536 background never becomes a 12 MB bitmap just
/// to fill a card.
private nonisolated enum Thumbnail {
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

/// The final card: opens the grown-ups area (parental gate first), where new
/// packs live.
private struct MoreStoriesCard: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.62, blue: 0.95),
                    Color(red: 0.85, green: 0.6, blue: 0.9),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 18) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                Text("More stories")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.9), lineWidth: 4))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 4)
    }
}
