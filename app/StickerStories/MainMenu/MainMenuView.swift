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
            let cardHeight = min(geo.size.height * 0.58, geo.size.width * 0.66)
            let cardWidth = min(geo.size.width * 0.42, cardHeight * 1.1)

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

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// One selectable pack: its background art fills the card, a few stickers
/// spill over it, and the localized name sits in a banner at the bottom.
private struct PackMenuCard: View {
    let pack: LoadedPack
    let preferredLanguages: [String]

    var body: some View {
        let language = LanguageResolver(preferredLanguages: preferredLanguages)
            .resolve(from: pack.manifest.languages)

        ZStack(alignment: .bottom) {
            if let background = UIImage(
                contentsOfFile: pack.url(forAssetPath: pack.manifest.background).path) {
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
        .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
    }

    private var stickerSpill: some View {
        HStack(spacing: 8) {
            let stickers = pack.manifest.stickers.prefix(3).compactMap {
                UIImage(contentsOfFile: pack.url(forAssetPath: $0.image).path)
            }
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
        .shadow(color: .black.opacity(0.22), radius: 12, y: 8)
    }
}
