import Foundation
import Testing

@testable import StickerStoriesKit

// MARK: - Fixtures

func localized(_ en: String, _ es: String) -> [String: String] {
    ["en-US": en, "es-ES": es]
}

/// A minimal manifest that passes every rule, mirroring the Go test fixture.
func makeValidManifest() -> PackManifest {
    PackManifest(
        schemaVersion: 2, id: "forest", version: 1,
        languages: ["en-US", "es-ES"],
        displayName: localized("Forest Friends", "Amigos del Bosque"),
        theme: "forest", background: "art/background.png", foreground: "art/foreground.png",
        stickers: [
            StickerDefinition(id: "mushroom", name: localized("Mushroom", "Seta"), image: "stickers/mushroom.png"),
            StickerDefinition(id: "fox", name: localized("Fox", "Zorro"), image: "stickers/fox.png"),
        ],
        stories: [
            StoryDefinition(
                id: "story-001",
                requiredStickers: ["mushroom"], optionalStickers: ["fox"],
                weight: 2.0, tags: ["gentle"],
                localizations: [
                    "en-US": StoryLocalization(
                        title: "The Shy Mushroom", text: "Once upon a time…",
                        audio: "audio/en-US/story-001.m4a"),
                    "es-ES": StoryLocalization(
                        title: "La seta tímida", text: "Érase una vez…",
                        audio: "audio/es-ES/story-001.m4a"),
                ]),
            StoryDefinition(
                id: "story-002",
                localizations: [
                    "en-US": StoryLocalization(
                        title: "A Forest Day", text: "One sunny morning…",
                        audio: "audio/en-US/story-002.m4a"),
                    "es-ES": StoryLocalization(
                        title: "Un día en el bosque", text: "Una mañana de sol…",
                        audio: "audio/es-ES/story-002.m4a"),
                ]),
        ])
}

/// Writes the manifest's JSON and dummy asset files into a temp directory.
func materialize(_ manifest: PackManifest, includeManifestJSON: Bool = true) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pack-\(UUID().uuidString)")
    let fm = FileManager.default
    var assets = [manifest.background, manifest.foreground]
    assets += manifest.stickers.map(\.image)
    assets += manifest.stories.flatMap { $0.localizations.values.map(\.audio) }
    assets += manifest.stories.flatMap { $0.localizations.values.compactMap(\.effects) }
    for relative in assets {
        let url = dir.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
    if includeManifestJSON {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
    }
    return dir
}

// MARK: - Decoding

@Suite struct ManifestDecodingTests {
    @Test func decodesMinimalStoryWithDefaults() throws {
        let json = """
            {
              "id": "s1",
              "localizations": {
                "en-US": { "title": "T", "text": "Body.", "audio": "audio/en-US/s1.m4a" }
              }
            }
            """
        let story = try JSONDecoder().decode(StoryDefinition.self, from: Data(json.utf8))
        #expect(story.requiredStickers.isEmpty)
        #expect(story.optionalStickers.isEmpty)
        #expect(story.weight == 1.0)
        #expect(story.tags.isEmpty)
        #expect(story.isFallback)
        #expect(story.localizations["en-US"]?.text == "Body.")
    }

    @Test func rejectsStoryWithoutLocalizations() throws {
        let json = """
            { "id": "s1", "title": "T", "text": "Body.", "audio": "audio/s1.m4a" }
            """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(StoryDefinition.self, from: Data(json.utf8))
        }
    }
}

// MARK: - Validation

@Suite struct ManifestValidationTests {
    @Test func validManifestHasNoIssues() throws {
        let manifest = makeValidManifest()
        let dir = try materialize(manifest)
        #expect(manifest.validationIssues(packDirectory: dir).isEmpty)
    }

    @Test func effectsSidecarMustExistWhenDeclared() throws {
        var manifest = makeValidManifest()
        manifest.stories[0].localizations["en-US"]?.effects = "audio/en-US/story-001.effects.json"
        let dir = try materialize(manifest)
        #expect(manifest.validationIssues(packDirectory: dir).isEmpty)
        let story = Story(manifest.stories[0], language: "en-US", fallbackOrder: manifest.languages)
        #expect(story.effectsPath == "audio/en-US/story-001.effects.json")
        #expect(Story(manifest.stories[0], language: "es-ES", fallbackOrder: manifest.languages).effectsPath == nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("audio/en-US/story-001.effects.json"))
        let issues = manifest.validationIssues(packDirectory: dir)
        #expect(issues.count == 1 && issues[0].contains("effects"))
    }

    struct InvalidCase: Sendable, CustomStringConvertible {
        let expectedSubstring: String
        let mutate: @Sendable (inout PackManifest) -> Void
        init(_ expectedSubstring: String, _ mutate: @escaping @Sendable (inout PackManifest) -> Void) {
            self.expectedSubstring = expectedSubstring
            self.mutate = mutate
        }
        var description: String { expectedSubstring }
    }

    @Test(arguments: [
        InvalidCase("schemaVersion") { $0.schemaVersion = 1 },
        InvalidCase("pack id") { $0.id = "Forest Pack!" },
        InvalidCase("version") { $0.version = 0 },
        InvalidCase("languages must not be empty") { $0.languages = [] },
        InvalidCase("well-formed") { $0.languages[0] = "english" },
        InvalidCase("duplicate language") { $0.languages = ["en-US", "en-US"] },
        InvalidCase("missing \"es-ES\"") { $0.displayName.removeValue(forKey: "es-ES") },
        InvalidCase("must not be empty") { $0.displayName["es-ES"] = " " },
        InvalidCase("not in declared languages") { $0.displayName["fr-FR"] = "Amis" },
        InvalidCase("missing \"es-ES\"") { $0.stickers[0].name.removeValue(forKey: "es-ES") },
        InvalidCase("not found") { $0.background = "art/nope.png" },
        InvalidCase("escape") { $0.foreground = "../../evil.png" },
        InvalidCase("escape") { $0.foreground = "/etc/passwd" },
        InvalidCase("duplicate sticker") { $0.stickers[1].id = "mushroom" },
        InvalidCase("sticker id") { $0.stickers[0].id = "Mushroom" },
        InvalidCase("duplicate story") { $0.stories[1].id = "story-001" },
        InvalidCase("missing \"es-ES\"") { $0.stories[0].localizations.removeValue(forKey: "es-ES") },
        InvalidCase("not in declared languages") {
            $0.stories[0].localizations["fr-FR"] = StoryLocalization(
                title: "T", text: "T.", audio: "audio/en-US/story-001.m4a")
        },
        InvalidCase("text") { $0.stories[0].localizations["en-US"]?.text = "" },
        InvalidCase("title") { $0.stories[0].localizations["en-US"]?.title = "" },
        InvalidCase("not found") { $0.stories[0].localizations["es-ES"]?.audio = "audio/es-ES/nope.m4a" },
        InvalidCase("undeclared") { $0.stories[0].requiredStickers = ["dragon"] },
        InvalidCase("undeclared") { $0.stories[0].optionalStickers = ["dragon"] },
        InvalidCase("both") { $0.stories[0].optionalStickers = ["mushroom"] },
        InvalidCase("weight") { $0.stories[0].weight = 0 },
        InvalidCase("fallback") { $0.stories[1].requiredStickers = ["fox"] },
        InvalidCase("at least one story") { $0.stories = [] },
    ])
    func detectsInvalidManifests(testCase: InvalidCase) throws {
        var manifest = makeValidManifest()
        let dir = try materialize(manifest)  // valid assets on disk
        testCase.mutate(&manifest)
        let issues = manifest.validationIssues(packDirectory: dir)
        #expect(
            issues.contains { $0.contains(testCase.expectedSubstring) },
            "no issue mentioning \"\(testCase.expectedSubstring)\" in \(issues)")
    }
}

// MARK: - PackLoader

@Suite struct PackLoaderTests {
    @Test func loadsValidPack() throws {
        let dir = try materialize(makeValidManifest())
        let pack = try PackLoader().loadPack(at: dir, source: .bundled)
        #expect(pack.id == "forest")
        #expect(pack.manifest.stickers.count == 2)
        #expect(pack.source == .bundled)
        #expect(pack.manifest.displayName(for: "es-ES") == "Amigos del Bosque")
        #expect(pack.manifest.displayName(for: "fr-FR") == "Forest Friends")  // fallback order
        #expect(pack.sticker(withID: "fox")?.name(for: "es-ES", fallbackOrder: pack.manifest.languages) == "Zorro")
    }

    @Test func missingManifestThrows() throws {
        let dir = try materialize(makeValidManifest(), includeManifestJSON: false)
        #expect(throws: PackLoadingError.manifestNotFound(dir.appendingPathComponent("manifest.json"))) {
            try PackLoader().loadPack(at: dir, source: .installed)
        }
    }

    @Test func invalidPackThrowsWithIssues() throws {
        var manifest = makeValidManifest()
        let dir = try materialize(manifest)
        manifest.stories = []  // no stories
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        do {
            _ = try PackLoader().loadPack(at: dir, source: .installed)
            Issue.record("expected invalidPack error")
        } catch let PackLoadingError.invalidPack(issues) {
            #expect(!issues.isEmpty)
        }
    }

    /// Keeps the Swift validator honest against the real bundled pack, which
    /// the Go packager also validates. Skips gracefully if the repo layout
    /// isn't available (e.g. tests run outside the monorepo).
    @Test func loadsTheRealForestPack() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)  // …/Tests/StickerStoriesKitTests/PackManifestTests.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let forestDir = repoRoot.appendingPathComponent("packs/forest")
        guard FileManager.default.fileExists(atPath: forestDir.appendingPathComponent("manifest.json").path) else {
            return  // not running inside the monorepo
        }
        let pack = try PackLoader().loadPack(at: forestDir, source: .bundled)
        #expect(pack.manifest.languages == ["en-US", "es-ES"])
        #expect(pack.manifest.stickers.count == 19)
        #expect(pack.manifest.stories.count == 10)
        #expect(pack.manifest.stories.filter(\.isFallback).count == 3)
    }
}

// MARK: - CanvasState

@Suite struct CanvasStateTests {
    @Test func roundTripsThroughJSON() throws {
        let state = CanvasState(
            packID: "forest",
            stickers: [
                PlacedSticker(
                    stickerID: "fox", position: NormalizedPoint(x: 0.25, y: 0.75),
                    layer: .foreground, zOrder: 2, scale: 1.2, rotation: 0.1),
                PlacedSticker(
                    stickerID: "tree", position: NormalizedPoint(x: 0.5, y: 0.5),
                    layer: .background, zOrder: 1),
            ])
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CanvasState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.stickerIDs == ["fox", "tree"])
    }
}
