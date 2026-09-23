import StickerStoriesKit
import StoreKit
import SwiftUI
import UIKit

/// The store: a full-screen section of the app, opened from the main menu's
/// More stories card and only ever after the parental gate. Everything
/// commerce-related lives here; no child-facing surface may link out of the
/// app or offer purchases (docs/compliance.md).
///
/// A header row (back, title, restore), the "All sticker packs" bundle as a
/// banner, then the packs as big tiles in a horizontal row sized so two are
/// always fully on screen, with the next one peeking in. Styled like the rest
/// of the app — big cards on a meadow gradient, not system chrome.
struct StoreScreen: View {
    let store: StoreService
    let packs: [LoadedPack]
    let settings: AppSettings
    let onClose: () -> Void

    /// Compact height is a phone in landscape: everything tightens so the
    /// banner and a whole row of tiles still fit on one screen.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { geo in
            let horizontalPadding: CGFloat = 26
            let spacing: CGFloat = 20
            let cards = cards
            // Two tiles fit exactly; with more than two, leave room for the
            // next one to peek in so the row reads as scrollable.
            let peek: CGFloat = cards.count > 2 ? 44 : 0
            let tileWidth = (geo.size.width - 2 * horizontalPadding - spacing - peek) / 2
            // Tiles stay tile-shaped when the screen is tall (portrait iPad).
            let tileMaxHeight = tileWidth * 1.3

            VStack(spacing: isCompact ? 10 : 16) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, isCompact ? 6 : 14)

                if let bundle {
                    BundleBanner(offer: bundle, isWorking: store.isWorking, isCompact: isCompact)
                        .padding(.horizontal, horizontalPadding)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(cards) { card in
                            PackTile(card: card, isWorking: store.isWorking, isCompact: isCompact)
                                .frame(width: tileWidth)
                                .frame(maxHeight: tileMaxHeight)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, horizontalPadding)
                }
                .scrollTargetBehavior(.viewAligned)
                // The tiles' shadows fall outside the scroll view's bounds.
                .scrollClipDisabled()
                .frame(maxHeight: .infinity)  // the row sits centred in the space left
                .padding(.bottom, isCompact ? 12 : 0)

                if !isCompact {
                    Text("Purchases never leave this screen — the rest of the app is for your child. The Forest Friends pack is included for free.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 10)
                }
            }
        }
        .background {
            LinearGradient(
                colors: [
                    Color(red: 0.49, green: 0.78, blue: 0.91),
                    Color(red: 0.72, green: 0.88, blue: 0.72),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if let message = store.lastMessage {
                Text(message)  // LocalizedStringKey → follows the environment locale
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: store.lastMessage)
        .task { await store.refresh() }
    }

    // MARK: Header

    /// Back on the left, the title centred, restore on the right — each in
    /// its own space, so the title can never sit under a button.
    private var header: some View {
        ZStack {
            Text("More stories")
                .font(.system(size: isCompact ? 24 : 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 190)
            HStack {
                backButton
                Spacer()
                restoreButton
            }
        }
    }

    private var backButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.left")
                .font(.system(size: 19, weight: .heavy))
                .foregroundStyle(Color(red: 0.25, green: 0.35, blue: 0.4))
                .frame(width: 22, height: 22)
                .padding(14)
                .background(Circle().fill(.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("Back")
    }

    private var restoreButton: some View {
        Button {
            Task { await store.restorePurchases() }
        } label: {
            Label("Restore purchases", systemImage: "arrow.clockwise")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.15, green: 0.4, blue: 0.2))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Capsule().fill(.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(store.isWorking)
    }

    // MARK: Content

    /// The "All sticker packs" offer, once StoreKit has loaded it.
    private var bundle: BundleOffer? {
        #if DEBUG
        if Self.isMocked { return .mock }
        #endif
        guard let product = store.products.first(where: { $0.id == StoreConfiguration.catalog.allAccessProductID })
        else { return nil }
        return BundleOffer(
            title: product.displayName, subtitle: product.description, price: product.displayPrice,
            isOwned: store.ownedProductIDs.contains(product.id),
            buy: { [store] in Task { await store.purchase(product) } })
    }

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

        // Pack products not installed locally (the bundle has its banner).
        let ownsEverything = store.ownedProductIDs.contains(StoreConfiguration.catalog.allAccessProductID)
        for product in store.products {
            guard let packID = StoreConfiguration.catalog.packID(fromProductID: product.id),
                !packs.contains(where: { $0.id == packID })
            else { continue }
            let owned = ownsEverything || store.ownedProductIDs.contains(product.id)
            result.append(
                PackCard(
                    id: product.id, title: product.displayName,
                    subtitle: .text(product.description),
                    artwork: .mystery(symbol: "gift.fill"),
                    availability: owned
                        ? .owned
                        : .purchasable(price: product.displayPrice) { [store] in
                            Task { await store.purchase(product) }
                        }))
        }
        #if DEBUG
        if Self.isMocked { result += PackCard.mocks }
        #endif
        return result
    }

    #if DEBUG
    /// `-storeMock`: sample products in place of StoreKit's, for checking the
    /// layout where the StoreKit test configuration isn't loaded (a
    /// simulator launch from the command line).
    fileprivate static var isMocked: Bool { ProcessInfo.processInfo.arguments.contains("-storeMock") }
    #endif
}

/// What the bundle banner shows: StoreKit's copy and price, and what buying
/// it does.
private struct BundleOffer {
    let title: String
    let subtitle: String
    let price: String
    let isOwned: Bool
    let buy: () -> Void

    #if DEBUG
    static let mock = BundleOffer(
        title: "All sticker packs", subtitle: "Every sticker pack, now and in the future.", price: "$9.99",
        isOwned: false, buy: {})
    #endif
}

// MARK: - Bundle banner

/// The best deal, first: every pack in one purchase.
private struct BundleBanner: View {
    let offer: BundleOffer
    let isWorking: Bool
    /// One line, no description: a phone in landscape.
    var isCompact = false

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: isCompact ? 22 : 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 42 : 58, height: isCompact ? 42 : 58)
                .background(Circle().fill(.white.opacity(0.22)))

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: offer.title)  // StoreKit copy, already localized
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                if !isCompact {
                    Text(verbatim: offer.subtitle)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if offer.isOwned {
                Label("Owned", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.white.opacity(0.22)))
            } else {
                Button(action: offer.buy) {
                    Text(verbatim: offer.price)
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, isCompact ? 9 : 13)
                        .background(
                            Capsule()
                                .fill(Color(red: 1.0, green: 0.72, blue: 0.15))
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 3))
                }
                .buttonStyle(SquishyButtonStyle())
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isCompact ? 8 : 14)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.62, blue: 0.95),
                    Color(red: 0.85, green: 0.6, blue: 0.9),
                ],
                startPoint: .leading, endPoint: .trailing))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.9), lineWidth: 3))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 5)
    }
}

// MARK: - Pack tile

private struct PackCard: Identifiable {
    enum Artwork {
        case pack(background: UIImage, stickers: [UIImage])
        case mystery(symbol: String)
    }
    enum Availability {
        case included
        case owned
        case purchasable(price: String, buy: () -> Void)
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

    #if DEBUG
    static let mocks = [
        PackCard(
            id: "mock-meadow", title: "Meadow Friends", subtitle: .text("Bees, frogs and a very tall sunflower."),
            artwork: .mystery(symbol: "gift.fill"), availability: .purchasable(price: "$1.99", buy: {})),
        PackCard(
            id: "mock-ocean", title: "Under the Sea", subtitle: .text("Fish, crabs and a sleepy whale."),
            artwork: .mystery(symbol: "gift.fill"), availability: .purchasable(price: "$1.99", buy: {})),
    ]
    #endif
}

/// One pack: its art fills whatever height the row gives it, with the name,
/// counts and the price (or an owned badge) underneath.
private struct PackTile: View {
    let card: PackCard
    let isWorking: Bool
    /// A slimmer info block and smaller art: a phone in landscape.
    var isCompact = false

    var body: some View {
        VStack(spacing: 0) {
            // Overlay on a clear base so the fill-scaled art cannot inflate
            // the tile's layout size.
            Color.clear
                .frame(minHeight: isCompact ? 60 : 110, maxHeight: .infinity)
                .overlay { artwork }
                .clipped()

            VStack(alignment: .leading, spacing: isCompact ? 4 : 8) {
                Text(card.title)
                    .font(.system(size: isCompact ? 19 : 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                subtitleText
                    .font(.system(size: isCompact ? 13 : 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                actionRow
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isCompact ? 12 : 18)
            .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.9), lineWidth: 3))
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
        case .purchasable(let price, let buy):
            Button(action: buy) {
                Text(verbatim: price)
                    .font(.system(size: isCompact ? 18 : 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCompact ? 8 : 13)
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
            .font(.system(size: isCompact ? 15 : 17, weight: .bold, design: .rounded))
            .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.3))
            .frame(maxWidth: .infinity)
            .padding(.vertical, isCompact ? 8 : 12)
            .background(Capsule().fill(Color(red: 0.2, green: 0.55, blue: 0.3).opacity(0.14)))
    }
}
