import Foundation

/// Decoded `manifest.json` of a sticker pack.
///
/// This is the Swift half of the schema contract in `docs/pack-format.md`;
/// the Go validator in `tools/internal/manifest` is the other half. Any schema
/// change must update the doc, the Go validator, and this file in the same
/// commit.
public struct PackManifest: Codable, Equatable, Sendable {
    /// The only schema version this build understands.
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var version: Int
    public var displayName: String
    public var theme: String
    public var background: String
    public var foreground: String
    public var stickers: [StickerDefinition]
    public var stories: [StoryDefinition]

    public init(
        schemaVersion: Int, id: String, version: Int, displayName: String,
        theme: String, background: String, foreground: String,
        stickers: [StickerDefinition], stories: [StoryDefinition]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.displayName = displayName
        self.theme = theme
        self.background = background
        self.foreground = foreground
        self.stickers = stickers
        self.stories = stories
    }
}

public struct StickerDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var image: String

    public init(id: String, name: String, image: String) {
        self.id = id
        self.name = name
        self.image = image
    }
}

public struct StoryDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var text: String
    public var audio: String
    public var requiredStickers: [String]
    public var optionalStickers: [String]
    public var weight: Double
    public var tags: [String]

    /// A fallback story is playable whatever is on the canvas.
    public var isFallback: Bool { requiredStickers.isEmpty }

    public init(
        id: String, title: String, text: String, audio: String,
        requiredStickers: [String] = [], optionalStickers: [String] = [],
        weight: Double = 1.0, tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.audio = audio
        self.requiredStickers = requiredStickers
        self.optionalStickers = optionalStickers
        self.weight = weight
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        audio = try c.decode(String.self, forKey: .audio)
        requiredStickers = try c.decodeIfPresent([String].self, forKey: .requiredStickers) ?? []
        optionalStickers = try c.decodeIfPresent([String].self, forKey: .optionalStickers) ?? []
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1.0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

// MARK: - Validation

extension PackManifest {
    /// Applies every rule from `docs/pack-format.md`, returning all problems
    /// found (not just the first). Pass the pack directory to include
    /// file-existence checks; pass `nil` for purely structural validation.
    public func validationIssues(
        packDirectory: URL? = nil, fileManager: FileManager = .default
    ) -> [String] {
        var issues: [String] = []

        // Rule 1: schema version.
        if schemaVersion != Self.supportedSchemaVersion {
            issues.append("schemaVersion \(schemaVersion) is not supported (want \(Self.supportedSchemaVersion))")
        }

        // Rule 6 (scalars).
        if !Self.isWellFormedID(id) {
            issues.append("pack id \"\(id)\" must be lowercase a-z0-9 with single hyphens")
        }
        if version < 1 {
            issues.append("version must be >= 1, got \(version)")
        }
        if displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("displayName must not be empty")
        }

        // Rule 3: referenced files exist inside the pack.
        func checkFile(_ field: String, _ path: String) {
            if path.isEmpty {
                issues.append("\(field) must not be empty")
                return
            }
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                issues.append("\(field): path \"\(path)\" must be pack-relative and must not escape the pack")
                return
            }
            guard let dir = packDirectory else { return }
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: dir.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !exists {
                issues.append("\(field): file \"\(path)\" not found in pack")
            } else if isDirectory.boolValue {
                issues.append("\(field): \"\(path)\" is a directory, not a file")
            }
        }
        checkFile("background", background)
        checkFile("foreground", foreground)

        // Rule 2: sticker IDs well-formed and unique.
        var stickerIDs = Set<String>()
        for sticker in stickers {
            if !Self.isWellFormedID(sticker.id) {
                issues.append("sticker id \"\(sticker.id)\" must be lowercase a-z0-9 with single hyphens")
            }
            if !stickerIDs.insert(sticker.id).inserted {
                issues.append("duplicate sticker id \"\(sticker.id)\"")
            }
            if sticker.name.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("sticker \"\(sticker.id)\": name must not be empty")
            }
            checkFile("sticker \"\(sticker.id)\" image", sticker.image)
        }

        // Rules 2, 4, 5, 6 over stories.
        var storyIDs = Set<String>()
        var fallbacks = 0
        for story in stories {
            let name = "story \"\(story.id)\""
            if story.id.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("story id must not be empty")
            }
            if !storyIDs.insert(story.id).inserted {
                issues.append("\(name): duplicate story id")
            }
            if story.title.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("\(name): title must not be empty")
            }
            if story.text.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("\(name): text must not be empty (stories must carry their text)")
            }
            checkFile("\(name) audio", story.audio)
            if story.weight <= 0 {
                issues.append("\(name): weight must be > 0, got \(story.weight)")
            }
            let required = Set(story.requiredStickers)
            for stickerID in story.requiredStickers where !stickerIDs.contains(stickerID) {
                issues.append("\(name): requiredStickers references undeclared sticker \"\(stickerID)\"")
            }
            for stickerID in story.optionalStickers {
                if !stickerIDs.contains(stickerID) {
                    issues.append("\(name): optionalStickers references undeclared sticker \"\(stickerID)\"")
                }
                if required.contains(stickerID) {
                    issues.append("\(name): sticker \"\(stickerID)\" appears in both requiredStickers and optionalStickers")
                }
            }
            if story.isFallback { fallbacks += 1 }
        }
        if !stories.isEmpty && fallbacks == 0 {
            issues.append("pack has no fallback story (at least one story must have empty requiredStickers)")
        }
        if stories.isEmpty { issues.append("pack must contain at least one story") }
        if stickers.isEmpty { issues.append("pack must contain at least one sticker") }

        return issues
    }

    /// Note: sticker ID checks run before story checks, so the set is complete
    /// by the time stories reference it — same ordering as the Go validator.
    static func isWellFormedID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }
}
