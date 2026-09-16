import Foundation
import StickerStoriesKit

/// Stores one JSON file per pack under Application Support. App-internal
/// state only, no personal data — same compliance basis as
/// `UserDefaultsRecentStories` / `AppSettings`. Best-effort: a failed
/// load/save just means the canvas starts fresh, never crashes the child
/// experience.
struct FileCanvasStateStore: CanvasStateStore {
    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "CanvasStates", directoryHint: .isDirectory)
    }

    private func fileURL(packID: String) -> URL {
        Self.directory.appendingPathComponent("\(packID).json")
    }

    func load(packID: String) -> CanvasState? {
        guard let data = try? Data(contentsOf: fileURL(packID: packID)) else { return nil }
        return try? JSONDecoder().decode(CanvasState.self, from: data)
    }

    func save(_ state: CanvasState) {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL(packID: state.packID), options: .atomic)
        } catch {
            // Losing a save just means the canvas starts fresh next time.
        }
    }
}
