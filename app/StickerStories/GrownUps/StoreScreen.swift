import StickerStoriesKit
import StoreKit
import SwiftUI
import UIKit

/// The store: a full-screen section of the app, opened from the main menu's
/// More stories card and only ever after the parental gate. Everything
/// commerce-related lives here; no child-facing surface may link out of the
/// app or offer purchases (docs/compliance.md).
///
/// A header row (back, title), the "All Sticker Story Packs" bundle as a
/// banner, then the packs as big tiles scrolling horizontally, sized so two
/// columns are always fully on screen with the next one peeking in — in two
/// rows on a big screen, so four tiles show at once. Styled like the rest
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
            let cards = cards

            VStack(spacing: isCompact ? 10 : 16) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, isCompact ? 6 : 14)

                if let bundle {
                    BundleBanner(offer: bundle, isWorking: store.isWorking, isCompact: isCompact)
                        .padding(.horizontal, Self.horizontalPadding)
                }

                GeometryReader { area in
                    tiles(cards, in: area.size)
                        .frame(width: area.size.width, height: area.size.height)  // centred in the space left
                }
                .padding(.bottom, isCompact ? 12 : 20)
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

    // MARK: Tiles

    private static let horizontalPadding: CGFloat = 26
    private static let spacing: CGFloat = 20
    /// The next column's sliver, so the row reads as scrollable.
    private static let peek: CGFloat = 44
    /// Two rows only when each tile keeps at least this much room — a big
    /// screen. A phone, or an iPad squeezed by multitasking, keeps one row.
    private static let twoRowMinTileSize = CGSize(width: 240, height: 250)

    /// The packs as a horizontally scrolling grid: two columns always fully
    /// on screen, the next one peeking in, and two rows of them when there
    /// is room for four tiles (they fill column by column, so the second
    /// row is never ahead of the first by more than one tile).
    private func tiles(_ cards: [PackCard], in size: CGSize) -> some View {
        let spacing = Self.spacing
        let columnSpace = size.width - 2 * Self.horizontalPadding - spacing
        let fullWidth = columnSpace / 2
        let twoRows = cards.count > 2
            && fullWidth - Self.peek / 2 >= Self.twoRowMinTileSize.width
            && (size.height - spacing) / 2 >= Self.twoRowMinTileSize.height
        let rows = twoRows ? 2 : 1
        let columns = (cards.count + rows - 1) / rows
        let tileWidth = columns > 2 ? (columnSpace - Self.peek) / 2 : fullWidth
        // Tiles stay tile-shaped when the screen is tall (portrait iPad).
        let tileHeight = min((size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows), tileWidth * 1.3)

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(
                rows: Array(repeating: GridItem(.fixed(tileHeight), spacing: spacing), count: rows),
                spacing: spacing
            ) {
                ForEach(cards) { card in
                    PackTile(
                        card: card, isWorking: store.isWorking, isCompact: isCompact,
                        reservesSubtitle: cards.contains { $0.subtitle != nil })
                        .frame(width: tileWidth, height: tileHeight)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Self.horizontalPadding)
        }
        .scrollTargetBehavior(.viewAligned)
        // The tiles' shadows fall outside the scroll view's bounds.
        .scrollClipDisabled()
        .frame(height: tileHeight * CGFloat(rows) + spacing * CGFloat(rows - 1))
    }

    // MARK: Header

    /// Back on the left, the title centred — each in its own space, so the
    /// title can never sit under the button. Restoring purchases lives in
    /// Settings.
    private var header: some View {
        ZStack {
            Text("More stories")
                .font(.system(size: isCompact ? 24 : 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 70)
            HStack {
                backButton
                Spacer()
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

    // MARK: Content

    /// The "All Sticker Story Packs" offer, once StoreKit has loaded it.
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
                    subtitle: pack.manifest.description(for: language),
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
                    subtitle: product.description,
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
        title: "All Sticker Story Packs", subtitle: "Every Sticker Story Pack in the app.", price: "$9.99",
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
    let id: String
    let title: String
    /// One line under the name: the manifest's description for a pack on
    /// the device, StoreKit's (already localized) for a pack on sale; nil
    /// when the pack has none.
    let subtitle: String?
    let artwork: Artwork
    let availability: Availability

    #if DEBUG
    static let mocks = [
        PackCard(
            id: "mock-meadow", title: "Meadow Friends", subtitle: "Bees, frogs and a very tall sunflower.",
            artwork: .mystery(symbol: "gift.fill"), availability: .purchasable(price: "$1.99", buy: {})),
        PackCard(
            id: "mock-ocean", title: "Under the Sea", subtitle: "Fish, crabs and a sleepy whale.",
            artwork: .mystery(symbol: "gift.fill"), availability: .purchasable(price: "$1.99", buy: {})),
        PackCard(
            id: "mock-farm", title: "Farm Friends", subtitle: "A pig, a hen and a tractor.",
            artwork: .mystery(symbol: "gift.fill"), availability: .purchasable(price: "$1.99", buy: {})),
        PackCard(
            id: "mock-space", title: "Space Explorers", subtitle: "Rockets, robots and a moon cat.",
            artwork: .mystery(symbol: "gift.fill"), availability: .purchasable(price: "$1.99", buy: {})),
        PackCard(
            id: "mock-dinos", title: "Dinosaur Valley", subtitle: "A gentle giant and three eggs.",
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
    /// Keep the subtitle's line even without one, so every tile's name and
    /// button line up with the tiles beside it.
    var reservesSubtitle = false

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
                if card.subtitle != nil || reservesSubtitle {
                    Text(verbatim: card.subtitle ?? " ")
                        .font(.system(size: isCompact ? 13 : 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(card.subtitle == nil)
                }
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
