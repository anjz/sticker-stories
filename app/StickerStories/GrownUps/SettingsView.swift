import SwiftUI

/// Parent settings, reached via the gear in the Grown-Ups area (so always
/// behind the parental gate). Currently one setting: the app + narration
/// language.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    /// nil = follow the device language.
    private let choices: [(override: String?, label: Text)] = [
        (nil, Text("System language")),
        ("en-US", Text(verbatim: "English")),
        ("es-ES", Text(verbatim: "Español")),
    ]

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
                    Text("Settings")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 2)
                        .padding(.top, 10)

                    Text("Language")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))

                    VStack(spacing: 12) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                            languageRow(override: choice.override, label: choice.label)
                        }
                    }
                    .frame(maxWidth: 460)
                }
                .padding(26)
            }

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
            .padding(18)
        }
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
