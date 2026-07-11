import Foundation

/// Decoded `manifest.json` of a sticker pack.
///
/// This is the Swift half of the schema contract in `docs/pack-format.md`;
/// the Go validator in `tools/internal/manifest` is the other half. Any schema
/// change must update the doc, the Go validator, and this file in the same
/// commit.
///
/// Packs are multilingual: `languages` declares the supported BCP-47 tags
/// (first entry = fallback), and every user-facing string / narration file
/// exists once per language.
public struct PackManifest: Codable, Equatable, Sendable {
    /// The only schema version this build understands.
    public static let supportedSchemaVersion = 2

    public var schemaVersion: Int
    public var id: String
    public var version: Int
    public var languages: [String]
    public var displayName: [String: String]
    public var theme: String
    public var background: String
    public var foreground: String
    public var stickers: [StickerDefinition]
    public var stories: [StoryDefinition]

    public init(
        schemaVersion: Int, id: String, version: Int, languages: [String],
        displayName: [String: String], theme: String, background: String,
        foreground: String, stickers: [StickerDefinition], stories: [StoryDefinition]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.languages = languages
        self.displayName = displayName
        self.theme = theme
        self.background = background
        self.foreground = foreground
        self.stickers = stickers
        self.stories = stories
    }

    /// The pack's name in the given language, falling back through the
    /// declared language order (validation guarantees full coverage, so the
    /// fallbacks only matter for not-yet-validated data).
    public func displayName(for language: String) -> String {
        Self.localizedValue(displayName, language: language, fallbackOrder: languages) ?? id
    }

    static func localizedValue(
        _ values: [String: String], language: String, fallbackOrder: [String]
    ) -> String? {
        if let exact = values[language] { return exact }
        for fallback in fallbackOrder {
            if let value = values[fallback] { return value }
        }
        return values.values.first
    }
}

public struct StickerDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: [String: String]
    public var image: String

    public init(id: String, name: [String: String], image: String) {
        self.id = id
        self.name = name
        self.image = image
    }

    public func name(for language: String, fallbackOrder: [String]) -> String {
        PackManifest.localizedValue(name, language: language, fallbackOrder: fallbackOrder) ?? id
    }
}

/// One language's rendition of a story: its title, full text (the portable
/// representation any future narrator needs), and pre-rendered narration.
public struct StoryLocalization: Codable, Equatable, Sendable {
    public var title: String
    public var text: String
    public var audio: String

    public init(title: String, text: String, audio: String) {
        self.title = title
        self.text = text
        self.audio = audio
    }
}

public struct StoryDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var requiredStickers: [String]
    public var optionalStickers: [String]
    public var weight: Double
    public var tags: [String]
    public var localizations: [String: StoryLocalization]

    /// A fallback story is playable whatever is on the canvas.
    public var isFallback: Bool { requiredStickers.isEmpty }

    public init(
        id: String, requiredStickers: [String] = [], optionalStickers: [String] = [],
        weight: Double = 1.0, tags: [String] = [],
        localizations: [String: StoryLocalization]
    ) {
        self.id = id
        self.requiredStickers = requiredStickers
        self.optionalStickers = optionalStickers
        self.weight = weight
        self.tags = tags
        self.localizations = localizations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        requiredStickers = try c.decodeIfPresent([String].self, forKey: .requiredStickers) ?? []
        optionalStickers = try c.decodeIfPresent([String].self, forKey: .optionalStickers) ?? []
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1.0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        localizations = try c.decode([String: StoryLocalization].self, forKey: .localizations)
    }

    public func localization(for language: String, fallbackOrder: [String]) -> StoryLocalization? {
        if let exact = localizations[language] { return exact }
        for fallback in fallbackOrder {
            if let value = localizations[fallback] { return value }
        }
        return localizations.values.first
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

        // Rule 8 (scalars).
        if !Self.isWellFormedID(id) {
            issues.append("pack id \"\(id)\" must be lowercase a-z0-9 with single hyphens")
        }
        if version < 1 {
            issues.append("version must be >= 1, got \(version)")
        }

        // Rule 3: declared languages.
        if languages.isEmpty {
            issues.append("languages must not be empty")
        }
        var declared = Set<String>()
        for language in languages {
            if !Self.isWellFormedLanguage(language) {
                issues.append("languages: \"\(language)\" is not a well-formed tag (want xx or xx-YY)")
            }
            if !declared.insert(language).inserted {
                issues.append("languages: duplicate language \"\(language)\"")
            }
        }

        // Rule 4: exact language coverage for a localized string map.
        func checkCoverage(_ field: String, _ values: [String: String]) {
            for language in languages {
                if let value = values[language] {
                    if value.trimmingCharacters(in: .whitespaces).isEmpty {
                        issues.append("\(field): \"\(language)\" localization must not be empty")
                    }
                } else {
                    issues.append("\(field): missing \"\(language)\" localization")
                }
            }
            for language in values.keys where !declared.contains(language) {
                issues.append("\(field): localization \"\(language)\" is not in declared languages")
            }
        }
        checkCoverage("displayName", displayName)

        // Rule 5: referenced files exist inside the pack.
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
            checkCoverage("sticker \"\(sticker.id)\" name", sticker.name)
            checkFile("sticker \"\(sticker.id)\" image", sticker.image)
        }

        // Rules 2, 4, 6, 7, 8 over stories.
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
            if story.weight <= 0 {
                issues.append("\(name): weight must be > 0, got \(story.weight)")
            }

            // Rule 4: one localization block per declared language, no extras.
            for language in languages {
                guard let localization = story.localizations[language] else {
                    issues.append("\(name): missing \"\(language)\" localization")
                    continue
                }
                let locName = "\(name) \(language)"
                if localization.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append("\(locName): title must not be empty")
                }
                if localization.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append("\(locName): text must not be empty (stories must carry their text)")
                }
                checkFile("\(locName) audio", localization.audio)
            }
            for language in story.localizations.keys where !declared.contains(language) {
                issues.append("\(name): localization \"\(language)\" is not in declared languages")
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

    static func isWellFormedID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }

    static func isWellFormedLanguage(_ tag: String) -> Bool {
        tag.wholeMatch(of: /[a-z]{2,3}(-[A-Z]{2})?/) != nil
    }
}
