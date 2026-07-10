import Foundation
import Observation
import StickerStoriesKit

/// Discovers packs and loads every one of them through the single
/// `PackLoader` code path — the bundled pack gets no special treatment, so
/// the flow a purchased pack will use is exercised from day one.
@MainActor
@Observable
final class PackLibrary {
    private(set) var packs: [LoadedPack] = []
    private(set) var loadFailures: [String] = []

    private let loader = PackLoader()

    /// The directory purchased packs are installed into.
    static var installedPacksDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Packs", directoryHint: .isDirectory)
    }

    func discoverPacks() {
        var found: [LoadedPack] = []
        var failures: [String] = []
        for (directory, source) in candidateDirectories() {
            do {
                found.append(try loader.loadPack(at: directory, source: source))
            } catch {
                failures.append("\(directory.lastPathComponent): \(error)")
            }
        }
        packs = found.sorted { $0.manifest.displayName < $1.manifest.displayName }
        loadFailures = failures
    }

    private func candidateDirectories() -> [(URL, PackSource)] {
        let fm = FileManager.default
        func packDirectories(in parent: URL?) -> [URL] {
            guard let parent,
                let entries = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            else { return [] }
            return entries.filter {
                fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
            }
        }
        return packDirectories(in: Bundle.main.resourceURL).map { ($0, PackSource.bundled) }
            + packDirectories(in: Self.installedPacksDirectory).map { ($0, PackSource.installed) }
    }
}
