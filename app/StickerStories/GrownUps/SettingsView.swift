import StickerStoriesKit
import SwiftUI

/// Parent settings, reached via the gear on the main menu and always behind
/// the parental gate: the app + narration language, calm mode and restoring
/// purchases.
/// Debug builds also expose the effects gallery here.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    /// For restoring purchases (the store itself only sells).
    let store: StoreService
    /// A pack whose stickers the debug effects gallery can use.
    var galleryPack: LoadedPack? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingGallery = false

    /// nil = follow the device language.
    private let choices: [(override: String?, label: Text)] = [
        (nil, Text("System language")),
        ("en-US", Text(verbatim: "English")),
        ("es-ES", Text(verbatim: "Español")),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.49, green: 0.78, blue: 0.91),
                    Color(red: 0.72, green: 0.88, blue: 0.72),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Fixed header row: title and close button share it, so they can
            // never overlap.
            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                    Spacer()
                    closeButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Language")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))

                        VStack(spacing: 12) {
                            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                                languageRow(override: choice.override, label: choice.label)
                            }
                        }
                        .frame(maxWidth: 460)

                        Text("Stories")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.top, 8)

                        calmModeRow
                            .frame(maxWidth: 460)

                        Text("Purchases")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.top, 8)

                        restoreRow
                            .frame(maxWidth: 460)
                        if let message = store.lastMessage {
                            Text(message)  // LocalizedStringKey → follows the environment locale
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(.black.opacity(0.25)))
                        }

                        #if DEBUG
                        if let galleryPack {
                            Text("Developer")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.95))
                                .padding(.top, 8)
                            Button { isShowingGallery = true } label: {
                                HStack {
                                    Text("Effects gallery")
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
                                    Spacer()
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.3))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(.white.opacity(0.85))
                                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3))
                            }
                            .buttonStyle(SquishyButtonStyle())
                            .frame(maxWidth: 460)
                            .fullScreenCover(isPresented: $isShowingGallery) {
                                EffectsGalleryView(pack: galleryPack)
                            }
                        }
                        #endif
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                    .padding(.bottom, 40)  // room after the last row
                }
            }
        }
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

    private var calmModeRow: some View {
        Button {
            settings.calmMode.toggle()
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calm mode")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
                    Text("Softer, slower sticker effects while stories play. Also follows the system Reduce Motion setting.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25).opacity(0.7))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: settings.calmMode ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(
                        settings.calmMode
                            ? Color(red: 0.2, green: 0.55, blue: 0.3)
                            : Color(red: 0.2, green: 0.3, blue: 0.25).opacity(0.25))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(settings.calmMode ? 1 : 0.85))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3))
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private var restoreRow: some View {
        Button {
            Task { await store.restorePurchases() }
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore purchases")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
                    Text("Get back the Sticker Story Packs you've already bought.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25).opacity(0.7))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if store.isWorking {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.2, green: 0.55, blue: 0.3))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3))
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(store.isWorking)
    }

    private func languageRow(override: String?, label: Text) -> some View {
        let isSelected = settings.languageOverride == override
        return Button {
            settings.languageOverride = override
        } label: {
            HStack {
                label
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.3, blue: 0.25))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(
                        isSelected
                            ? Color(red: 0.2, green: 0.55, blue: 0.3)
                            : Color(red: 0.2, green: 0.3, blue: 0.25).opacity(0.25))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(isSelected ? 1 : 0.85))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3))
        }
        .buttonStyle(SquishyButtonStyle())
    }
}
