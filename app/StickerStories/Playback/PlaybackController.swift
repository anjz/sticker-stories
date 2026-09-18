import Foundation
import Observation
import StickerStoriesKit

/// Drives the play flow: canvas snapshot → `StoryProvider` → `Narrator`.
/// The UI binds to `phase` only, keeping both seams swappable.
@MainActor
@Observable
final class PlaybackController {
    enum Phase: Equatable {
        case idle
        case choosing
        case playing(Story)
        case finished
    }

    private(set) var phase: Phase = .idle

    private let storyProvider: any StoryProvider
    private let narrator: any Narrator
    private var playTask: Task<Void, Never>?

    init(storyProvider: any StoryProvider, narrator: any Narrator) {
        self.storyProvider = storyProvider
        self.narrator = narrator
    }

    var isBusy: Bool { phase != .idle }

    /// Seconds into the narration, for the effects clock; `nil` when not playing.
    var playbackTime: TimeInterval? { narrator.playbackTime }

    func play(canvas: CanvasState, pack: LoadedPack, language: String) {
        stop()
        playTask = Task {
            phase = .choosing
            do {
                let story = try await storyProvider.story(for: canvas, in: pack, language: language)
                phase = .playing(story)
                try await narrator.narrate(story, from: pack)
                phase = .finished
                // Brief "the end" beat before returning to the canvas.
                try await Task.sleep(for: .seconds(1.2))
                phase = .idle
            } catch {
                // Cancellation and playback errors both return to idle; play
                // must never dead-end for a child.
                phase = .idle
            }
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        narrator.stop()
        phase = .idle
    }
}
