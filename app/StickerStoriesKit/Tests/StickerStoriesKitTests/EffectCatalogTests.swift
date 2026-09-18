import Foundation
import Testing

@testable import StickerStoriesKit

/// `docs/effects/effects.json` is what story tooling reads to learn the
/// library. This pins it to the compiled definitions so it cannot drift.
struct EffectCatalogTests {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            let name: String
            let category: String
            let summary: String
            let defaultDuration: Double
            let anchor: [Double]
            let parameters: [String]
            let oneWay: Bool
            let hold: Bool
            let defaultColor: String?
            let requiresColor: Bool
            let reduceMotion: String
        }
        let catalogSchema: Int
        let triggerSchema: Int
        let effects: [Entry]
    }

    private func loadCatalog() throws -> Catalog {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/effects/effects.json")
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    @Test func catalogMatchesCompiledLibrary() throws {
        let catalog = try loadCatalog()
        #expect(catalog.triggerSchema == EffectTriggerFile.supportedSchema)
        #expect(catalog.effects.map(\.name) == EffectName.allCases.map(\.rawValue))

        for entry in catalog.effects {
            let name = try #require(EffectName(rawValue: entry.name))
            let definition = EffectDefinition.definition(for: name)
            #expect(entry.category == name.category.rawValue, Comment(rawValue: entry.name))
            #expect(entry.summary == definition.summary, Comment(rawValue: entry.name))
            #expect(entry.defaultDuration == definition.defaultDuration, Comment(rawValue: entry.name))
            #expect(entry.anchor == [definition.anchor.x, definition.anchor.y], Comment(rawValue: entry.name))
            #expect(entry.oneWay == name.isOneWay, Comment(rawValue: entry.name))
            #expect(entry.hold == name.supportsHold, Comment(rawValue: entry.name))
            #expect(entry.defaultColor == definition.defaultColor?.hexString, Comment(rawValue: entry.name))
            #expect(entry.parameters.contains("color") == name.readsColor, Comment(rawValue: entry.name))
            #expect(entry.requiresColor == name.requiresColor, Comment(rawValue: entry.name))
            #expect(entry.parameters.contains("hold") == name.supportsHold, Comment(rawValue: entry.name))
            #expect(entry.parameters.contains("repeat") == !name.isOneWay, Comment(rawValue: entry.name))
            #expect(entry.parameters.contains("duration") && entry.parameters.contains("intensity"), Comment(rawValue: entry.name))

            let reduced = EffectPolicy(reduceMotion: true).adjusted(name, EffectOptions(intensity: 1))
            let expected: String
            switch reduced?.intensity {
            case nil: expected = "dropped"
            case 1: expected = "full"
            case 0.3: expected = "damped-0.3"
            case 0.4: expected = "damped-0.4"
            default: expected = "unknown"
            }
            #expect(entry.reduceMotion == expected, Comment(rawValue: entry.name))
        }
    }
}
