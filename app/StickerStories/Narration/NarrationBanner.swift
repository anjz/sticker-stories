import StickerStoriesKit
import SwiftUI

/// Why a story isn't playing in the chosen language
/// (docs/asset-delivery.md, "Playing while a language downloads").
enum NarrationNotice: Hashable {
    /// The chosen language's narration is still downloading; `playing` is
    /// what plays meanwhile.
    case fallback(wanted: String, playing: String)
    /// No language of the pack has arrived yet.
    case arriving
}

/// A small note for the parent at the top of the story screen, gone after
/// a few seconds. Never a modal: a four-year-old can't read one, and it
/// would stand between them and the story.
struct NarrationBanner: View {
    let notice: NarrationNotice
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18, weight: .bold))
            message
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(.black.opacity(0.55).shadow(.drop(color: .black.opacity(0.2), radius: 8, y: 4))))
        .accessibilityElement(children: .combine)
    }

    private var message: Text {
        switch notice {
        case .fallback(let wanted, let playing):
            Text("\(name(wanted)) stories are still downloading — playing in \(name(playing)) for now.")
        case .arriving:
            Text("Stories are still on their way.")
        }
    }

    /// A language's name in the language the app is shown in.
    private func name(_ tag: String) -> String {
        locale.localizedString(forLanguageCode: LanguageResolver.primarySubtag(tag)) ?? tag
    }
}
