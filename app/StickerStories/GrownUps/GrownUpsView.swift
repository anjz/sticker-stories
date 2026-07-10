import StickerStoriesKit
import StoreKit
import SwiftUI

/// Everything commerce-related lives here, and this view is only ever
/// presented after the parental gate. No child-facing surface may link out
/// of the app or offer purchases (docs/compliance.md).
struct GrownUpsView: View {
    let store: StoreService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Sticker packs") {
                    if store.products.isEmpty {
                        Text("No packs available right now.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.products, id: \.id) { product in
                        productRow(product)
                    }
                }

                Section {
                    Button("Restore purchases") {
                        Task { await store.restorePurchases() }
                    }
                    .disabled(store.isWorking)
                } footer: {
                    Text(footerText)
                }
            }
            .navigationTitle("Grown-Ups")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.refresh() }
        }
    }

    private func productRow(_ product: Product) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.displayName).font(.body.weight(.medium))
                Text(product.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.ownedProductIDs.contains(product.id) {
                Label("Owned", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            } else {
                Button(product.displayPrice) {
                    Task { await store.purchase(product) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isWorking)
            }
        }
    }

    private var footerText: String {
        var text = "Purchases never leave this screen — the rest of the app is for your child. "
            + "The Forest Friends pack is included for free."
        if let message = store.lastMessage {
            text += "\n\n\(message)"
        }
        return text
    }
}
