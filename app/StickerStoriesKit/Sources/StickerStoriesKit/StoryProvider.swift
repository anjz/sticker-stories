import Foundation

/// A story ready to play: the text is the portable representation (what a
/// future narrator or story generator works from); `audioPath` points at the
/// pack's pre-rendered narration for the v1 narrator.
public struct Story: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let text: String
    /// Pack-relative path to pre-rendered narration audio, if the story has one.
    public let audioPath: String?
    /// Pack-relative path to this language's sticker-effect triggers
    /// (`docs/effects.md`), if the story has any.
    public let effectsPath: String?

    public init(id: String, title: String, text: String, audioPath: String?, effectsPath: String? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.audioPath = audioPath
        self.effectsPath = effectsPath
    }

    /// Resolves a story definition into the given language (falling back
    /// through the pack's declared language order).
    public init(_ definition: StoryDefinition, language: String, fallbackOrder: [String]) {
        let localization = definition.localization(for: language, fallbackOrder: fallbackOrder)
        self.init(
            id: definition.id,
            title: localization?.title ?? definition.id,
            text: localization?.text ?? "",
            audioPath: localization?.audio,
            effectsPath: localization?.effects)
    }
}

/// The story-sourcing seam (see docs/architecture.md, "Future: runtime
/// generation"). Input is a canvas snapshot + pack + resolved language;
/// output is a story in that language.
/// v1: `BundledStoryProvider` scores the pack's pregenerated stories.
/// Future: a `GeneratedStoryProvider` produces one at runtime. Neither the
/// canvas nor playback code may depend on which one is in use.
public protocol StoryProvider: Sendable {
    func story(for canvas: CanvasState, in pack: LoadedPack, language: String) async throws -> Story
}

public enum StoryProviderError: Error, Equatable {
    /// The pack offers no playable story (validation should prevent this —
    /// packs must contain fallback stories).
    case noPlayableStory
}
