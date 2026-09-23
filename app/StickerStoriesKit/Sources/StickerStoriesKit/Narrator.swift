import Foundation

/// Observable narration lifecycle. Playback UI depends only on these states —
/// never on "an audio file is playing" — so a future synthesised narrator
/// slots in without UI changes.
public enum NarrationState: Equatable, Sendable {
    case idle
    case preparing
    case playing(Story)
    case finished
}

/// The narration seam (see docs/architecture.md, "Future: runtime
/// generation"). v1: `AudioFileNarrator` (app target) plays the pack's
/// pre-rendered audio. Future: an on-device TTS narrator synthesises from
/// `story.text`.
@MainActor
public protocol Narrator: AnyObject {
    var state: NarrationState { get }

    /// Seconds into the current narration, or `nil` when nothing is playing.
    /// This is the clock sticker effects run on, so it must track what the
    /// child hears: the audio player's position for pre-rendered audio,
    /// elapsed speech time for a synthesised narrator.
    var playbackTime: TimeInterval? { get }

    /// Total length of the current narration in seconds, or `nil` when
    /// nothing is playing or the length isn't known up front (a synthesised
    /// narrator may not). Only drives the progress ring in the playing HUD.
    var playbackDuration: TimeInterval? { get }

    /// Narrates the story, returning when narration finishes or is cancelled.
    func narrate(_ story: Story, from pack: LoadedPack) async throws

    /// Stops any narration in progress.
    func stop()
}

public enum NarrationError: Error, Equatable {
    case missingAudio(storyID: String)
    case unplayableAudio(String)
}
