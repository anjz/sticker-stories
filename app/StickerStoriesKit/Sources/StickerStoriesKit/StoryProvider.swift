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

    public init(id: String, title: String, text: String, audioPath: String?) {
        self.id = id
        self.title = title
        self.text = text
        self.audioPath = audioPath
    }

    public init(_ definition: StoryDefinition) {
        self.init(
            id: definition.id, title: definition.title,
            text: definition.text, audioPath: definition.audio)
    }
}

/// The story-sourcing seam (see docs/architecture.md, "Future: runtime
/// generation"). Input is a canvas snapshot + pack; output is a story.
/// v1: `BundledStoryProvider` scores the pack's pregenerated stories.
/// Future: a `GeneratedStoryProvider` produces one at runtime. Neither the
/// canvas nor playback code may depend on which one is in use.
public protocol StoryProvider: Sendable {
    func story(for canvas: CanvasState, in pack: LoadedPack) async throws -> Story
}

public enum StoryProviderError: Error, Equatable {
    /// The pack offers no playable story (validation should prevent this —
    /// packs must contain fallback stories).
    case noPlayableStory
}
