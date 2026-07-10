import Foundation
import Testing

@testable import StickerStoriesKit

// MARK: - Fixtures

/// A minimal manifest that passes every rule, mirroring the Go test fixture.
func makeValidManifest() -> PackManifest {
    PackManifest(
        schemaVersion: 1, id: "forest", version: 1, displayName: "Forest Friends",
        theme: "forest", background: "art/background.png", foreground: "art/foreground.png",
        stickers: [
            StickerDefinition(id: "mushroom", name: "Mushroom", image: "stickers/mushroom.png"),
            StickerDefinition(id: "fox", name: "Fox", image: "stickers/fox.png"),
        ],
        stories: [
            StoryDefinition(
                id: "story-001", title: "The Shy Mushroom", text: "Once upon a time…",
                audio: "audio/story-001.m4a",
                requiredStickers: ["mushroom"], optionalStickers: ["fox"],
                weight: 2.0, tags: ["gentle"]),
            StoryDefinition(
                id: "story-002", title: "A Forest Day", text: "One sunny morning…",
                audio: "audio/story-002.m4a"),
        ])
}

/// Writes the manifest's JSON and dummy asset files into a temp directory.
func materialize(_ manifest: PackManifest, includeManifestJSON: Bool = true) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pack-\(UUID().uuidString)")
    let fm = FileManager.default
    var assets = [manifest.background, manifest.foreground]
    assets += manifest.stickers.map(\.image)
    assets += manifest.stories.map(\.audio)
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
              "id": "s1", "title": "T", "text": "Body.", "audio": "audio/s1.m4a"
            }
            """
        let story = try JSONDecoder().decode(StoryDefinition.self, from: Data(json.utf8))
        #expect(story.requiredStickers.isEmpty)
        #expect(story.optionalStickers.isEmpty)
        #expect(story.weight == 1.0)
        #expect(story.tags.isEmpty)
        #expect(story.isFallback)
    }

    @Test func rejectsStoryWithoutText() throws {
        let json = """
            { "id": "s1", "title": "T", "audio": "audio/s1.m4a" }
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
        InvalidCase("schemaVersion") { $0.schemaVersion = 99 },
        InvalidCase("pack id") { $0.id = "Forest Pack!" },
        InvalidCase("version") { $0.version = 0 },
        InvalidCase("displayName") { $0.displayName = " " },
        InvalidCase("not found") { $0.background = "art/nope.png" },
        InvalidCase("escape") { $0.foreground = "../../evil.png" },
        InvalidCase("escape") { $0.foreground = "/etc/passwd" },
        InvalidCase("duplicate sticker") { $0.stickers[1].id = "mushroom" },
        InvalidCase("sticker id") { $0.stickers[0].id = "Mushroom" },
        InvalidCase("duplicate story") { $0.stories[1].id = "story-001" },
        InvalidCase("text") { $0.stories[0].text = "" },
        InvalidCase("title") { $0.stories[0].title = "" },
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
        #expect(pack.url(forAssetPath: "art/background.png").path.hasSuffix("art/background.png"))
        #expect(pack.sticker(withID: "fox")?.name == "Fox")
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
        #expect(pack.manifest.stickers.count == 9)
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
