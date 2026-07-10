import Foundation

/// Where a pack came from. Bundled packs are entitled by definition;
/// installed packs are subject to entitlement reconciliation.
public enum PackSource: Sendable, Equatable {
    case bundled
    case installed
}

/// A pack that passed decoding and validation, ready for use.
public struct LoadedPack: Sendable, Equatable, Identifiable {
    public let manifest: PackManifest
    public let baseURL: URL
    public let source: PackSource

    public var id: String { manifest.id }

    /// Resolves a pack-relative asset path (already validated) to a file URL.
    public func url(forAssetPath path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    public func sticker(withID id: String) -> StickerDefinition? {
        manifest.stickers.first { $0.id == id }
    }

    public func story(withID id: String) -> StoryDefinition? {
        manifest.stories.first { $0.id == id }
    }
}

public enum PackLoadingError: Error, Equatable {
    case manifestNotFound(URL)
    case undecodableManifest(String)
    case invalidPack(issues: [String])
}

/// Loads a pack from a directory. Every pack — bundled or purchased — goes
/// through this one code path, so the bundled pack permanently exercises the
/// flow a downloaded pack will use.
public struct PackLoader: Sendable {
    public init() {}

    public func loadPack(at directory: URL, source: PackSource) throws -> LoadedPack {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PackLoadingError.manifestNotFound(manifestURL)
        }
        let manifest: PackManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        } catch {
            throw PackLoadingError.undecodableManifest(String(describing: error))
        }
        let issues = manifest.validationIssues(packDirectory: directory)
        guard issues.isEmpty else {
            throw PackLoadingError.invalidPack(issues: issues)
        }
        return LoadedPack(manifest: manifest, baseURL: directory, source: source)
    }
}
