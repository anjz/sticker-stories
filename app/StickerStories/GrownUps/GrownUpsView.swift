import StickerStoriesKit
import StoreKit
import SwiftUI
import UIKit

/// Everything commerce-related lives here, and this view is only ever
/// presented after the parental gate. No child-facing surface may link out
/// of the app or offer purchases (docs/compliance.md).
///
/// Styled like the rest of the app — big cards on a meadow gradient, not
/// system chrome. Cards for locally available packs showcase the pack's real
/// background art with a few of its stickers.
struct GrownUpsView: View {
    let store: StoreService
    let packs: [LoadedPack]
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingSettings = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    Color(red: 0.49, green: 0.78, blue: 0.91),
                    Color(red: 0.72, green: 0.88, blue: 0.72),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Grown-Ups")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                        .padding(.top, 10)

                    Text("Sticker packs")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 18) {
                            ForEach(cards) { card in
                                PackCardView(card: card, isWorking: store.isWorking) { product in
                                    Task { await store.purchase(product) }
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                    }

                    restoreButton

                    if let message = store.lastMessage {
                        Text(message)  // LocalizedStringKey → follows the environment locale
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(.black.opacity(0.25)))
                    }

                    Text(
                        "Purchases never leave this screen — the rest of the app is for your child. "
                            + "The Forest Friends pack is included for free."
                    )
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 20)
                }
                .padding(26)
            }

            closeButton
                .padding(18)
        }
        .overlay(alignment: .topLeading) {
            settingsButton
                .padding(18)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(settings: settings)
                // Sheets are separate presentation trees; re-apply the override.
                .environment(\.locale, settings.uiLocale ?? Locale.autoupdatingCurrent)
        }
        .task { await store.refresh() }
    }

    private var settingsButton: some View {
        Button { isShowingSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(Color(red: 0.25, green: 0.35, blue: 0.4))
                .padding(14)
                .background(Circle().fill(.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("Settings")
    }

    // MARK: Cards

    private var cards: [PackCard] {
        var result: [PackCard] = []

        // Packs available on this device — showcase their real artwork.
        for pack in packs {
            let background = UIImage(
                contentsOfFile: pack.url(forAssetPath: pack.manifest.background).path)
            let stickers = pack.manifest.stickers.prefix(3).compactMap {
                UIImage(contentsOfFile: pack.url(forAssetPath: $0.image).path)
            }
            let language = LanguageResolver(preferredLanguages: settings.preferredLanguages)
                .resolve(from: pack.manifest.languages)
            result.append(
                PackCard(
                    id: pack.id,
                    title: pack.manifest.displayName(for: language),
                    subtitle: .counts(
                        stickers: pack.manifest.stickers.count,
                        stories: pack.manifest.stories.count),
                    artwork: background.map { .pack(background: $0, stickers: stickers) }
                        ?? .mystery(symbol: "photo"),
                    availability: pack.source == .bundled ? .included : .owned))
        }

        // Store products not installed locally.
        for product in store.products {
            let owned = store.ownedProductIDs.contains(product.id)
            if product.id == StoreConfiguration.catalog.allAccessProductID {
                result.append(
                    PackCard(
                        id: product.id, title: product.displayName,
                        subtitle: .text(product.description),
                        artwork: .mystery(symbol: "sparkles"),
                        availability: owned ? .owned : .purchasable(product)))
            } else if let packID = StoreConfiguration.catalog.packID(fromProductID: product.id),
                !packs.contains(where: { $0.id == packID }) {
                result.append(
                    PackCard(
                        id: product.id, title: product.displayName,
                        subtitle: .text(product.description),
                        artwork: .mystery(symbol: "gift.fill"),
                        availability: owned ? .owned : .purchasable(product)))
            }
        }
        return result
    }

    // MARK: Chrome

    private var restoreButton: some View {
        Button {
            Task { await store.restorePurchases() }
        } label: {
            Label("Restore purchases", systemImage: "arrow.clockwise")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.15, green: 0.4, blue: 0.2))
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background(Capsule().fill(.white.opacity(0.92)))
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(store.isWorking)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(Color(red: 0.25, green: 0.35, blue: 0.4))
                .padding(14)
                .background(Circle().fill(.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("Close")
    }
}

// MARK: - Pack card

private struct PackCard: Identifiable {
    enum Artwork {
        case pack(background: UIImage, stickers: [UIImage])
        case mystery(symbol: String)
    }
    enum Availability {
        case included
        case owned
        case purchasable(Product)
    }
    enum Subtitle {
        /// Localized via the catalog ("%lld stickers · %lld stories").
        case counts(stickers: Int, stories: Int)
        /// Verbatim text already localized elsewhere (StoreKit product copy).
        case text(String)
    }

    let id: String
    let title: String
    let subtitle: Subtitle
    let artwork: Artwork
    let availability: Availability
}

private struct PackCardView: View {
    let card: PackCard
    let isWorking: Bool
    let buy: (Product) -> Void

    private let cardWidth: CGFloat = 290

    var body: some View {
        VStack(spacing: 0) {
            artwork
                .frame(width: cardWidth, height: 165)
                .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text(card.title)
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
                subtitleText
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                actionRow
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white)
        }
        .frame(width: cardWidth)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    private var subtitleText: Text {
        switch card.subtitle {
        case .counts(let stickers, let stories):
            Text("\(stickers) stickers · \(stories) stories")
        case .text(let value):
            Text(verbatim: value)
        }
    }

    private var artwork: some View {
        ZStack {
            switch card.artwork {
            case .pack(let background, let stickers):
                Image(uiImage: background)
                    .resizable()
                    .scaledToFill()
                HStack(spacing: 12) {
                    ForEach(Array(stickers.enumerated()), id: \.offset) { index, image in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 84)
                            .rotationEffect(.degrees(index % 2 == 0 ? -8 : 8))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                }
            case .mystery(let symbol):
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.8, blue: 0.5),
                        Color(red: 0.95, green: 0.85, blue: 0.45),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch card.availability {
        case .included:
            badge("Included for free", symbol: "checkmark.seal.fill")
        case .owned:
            badge("Owned", symbol: "checkmark.circle.fill")
        case .purchasable(let product):
            Button {
                buy(product)
            } label: {
                Text(product.displayPrice)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        Capsule()
                            .fill(Color(red: 1.0, green: 0.72, blue: 0.15))
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 3))
            }
            .buttonStyle(SquishyButtonStyle())
            .disabled(isWorking)
        }
    }

    private func badge(_ text: LocalizedStringKey, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.3))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color(red: 0.2, green: 0.55, blue: 0.3).opacity(0.14)))
    }
}
