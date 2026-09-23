import Foundation

/// The closed list of canvas effects: weather and light over the whole
/// scene rather than on one sticker (`docs/effects.md`, "Canvas effects").
/// Each suits one or more pack `setting`s — rain has no place in a
/// bedroom — and a trigger whose effect does not suit the pack is skipped.
public enum CanvasEffectName: String, CaseIterable, Codable, Sendable, Hashable {
    // Outdoors
    case fog
    case rain
    case sunshine
    case rainbow
    case night
    case snow
    case sunset
    case clouds
    case wind
    case fireflies
    case leaves
    // Indoors
    case dimlight
    case windowlight
    case firelight
    case rainywindow
    // Indoors, outdoors and space
    case confetti
    // Every setting but none
    case bubbles
    // Space
    case shootingstars
    case nebula
    case warp
    case planetrise

    /// The pack settings (`PackManifest.setting`) this effect suits.
    public var settings: Set<PackSetting> {
        switch self {
        case .fog, .rain, .sunshine, .rainbow, .night, .snow, .sunset, .clouds, .wind, .fireflies,
            .leaves: [.outdoors]
        case .dimlight, .windowlight, .firelight, .rainywindow: [.indoors]
        case .confetti: [.outdoors, .indoors, .space]
        case .bubbles: [.outdoors, .indoors, .space, .underwater]
        case .shootingstars, .nebula, .warp, .planetrise: [.space]
        }
    }

    public func suits(_ setting: PackSetting) -> Bool { settings.contains(setting) }
}

/// One canvas effect's fixed shape. Content tunes `intensity` and
/// `duration` only (`CanvasEffectOptions`); the ramps — how long the effect
/// takes to build up and to clear — are what make fog fog and are not
/// authorable.
public struct CanvasEffectDefinition: Sendable {
    public let name: CanvasEffectName
    /// Seconds the effect stays on when the trigger gives no `duration`.
    public let defaultDuration: TimeInterval
    /// Seconds to build up to full strength (capped at a third of the duration).
    public let rampIn: TimeInterval
    /// Seconds to clear at the end or after a stop (same cap).
    public let rampOut: TimeInterval
    /// A one-line, authoring-facing description (mirrored in `docs/effects/effects.json`).
    public let summary: String

    public static func definition(for name: CanvasEffectName) -> CanvasEffectDefinition {
        library[name]!
    }

    public static let library: [CanvasEffectName: CanvasEffectDefinition] = {
        var all: [CanvasEffectName: CanvasEffectDefinition] = [:]
        for definition in definitions { all[definition.name] = definition }
        precondition(all.count == CanvasEffectName.allCases.count, "every canvas effect needs a definition")
        return all
    }()

    private static let definitions: [CanvasEffectDefinition] = [
        CanvasEffectDefinition(
            name: .fog, defaultDuration: 12, rampIn: 2.5, rampOut: 2.5,
            summary: "Soft mist drifts slowly across the whole scene."),
        CanvasEffectDefinition(
            name: .rain, defaultDuration: 10, rampIn: 1.2, rampOut: 1.5,
            summary: "Rain falls over everything; the light cools a little."),
        CanvasEffectDefinition(
            name: .sunshine, defaultDuration: 8, rampIn: 1.5, rampOut: 1.5,
            summary: "Warm light across the top of the scene, soft shafts drifting down."),
        CanvasEffectDefinition(
            name: .rainbow, defaultDuration: 8, rampIn: 2.0, rampOut: 2.0,
            summary: "A soft rainbow arcs across the sky behind the scenery."),
        CanvasEffectDefinition(
            name: .night, defaultDuration: 10, rampIn: 2.0, rampOut: 2.0,
            summary: "Night falls: the scene darkens and a moon glows in the sky."),
        CanvasEffectDefinition(
            name: .snow, defaultDuration: 12, rampIn: 2.0, rampOut: 2.5,
            summary: "Soft snowflakes drift down over everything; the light turns cool and bright."),
        CanvasEffectDefinition(
            name: .sunset, defaultDuration: 10, rampIn: 2.5, rampOut: 2.5,
            summary: "A warm orange-pink glow spreads from the horizon while the sky above deepens."),
        CanvasEffectDefinition(
            name: .clouds, defaultDuration: 12, rampIn: 2.5, rampOut: 2.5,
            summary: "Big soft clouds drift slowly across the sky behind the scenery; the light dims a little."),
        CanvasEffectDefinition(
            name: .wind, defaultDuration: 8, rampIn: 1.0, rampOut: 1.5,
            summary: "Pale wisps of air sweep across the scene with a few specks tumbling along."),
        CanvasEffectDefinition(
            name: .fireflies, defaultDuration: 12, rampIn: 2.0, rampOut: 2.0,
            summary: "Tiny warm lights drift and glow softly, mostly low over the ground."),
        CanvasEffectDefinition(
            name: .leaves, defaultDuration: 10, rampIn: 1.5, rampOut: 2.0,
            summary: "Autumn leaves flutter down and drift sideways across the scene."),
        CanvasEffectDefinition(
            name: .dimlight, defaultDuration: 8, rampIn: 1.5, rampOut: 1.5,
            summary: "The lights go low: the scene darkens toward its edges."),
        CanvasEffectDefinition(
            name: .windowlight, defaultDuration: 10, rampIn: 2.0, rampOut: 2.0,
            summary: "A slanted shaft of sunlight falls across the room, with dust motes turning in it."),
        CanvasEffectDefinition(
            name: .firelight, defaultDuration: 10, rampIn: 2.0, rampOut: 2.0,
            summary: "A warm glow from below flickers slowly and gently while the room around it dims."),
        CanvasEffectDefinition(
            name: .rainywindow, defaultDuration: 12, rampIn: 2.0, rampOut: 2.0,
            summary: "The room turns cool and grey while raindrops trickle down, as if seen through glass."),
        CanvasEffectDefinition(
            name: .confetti, defaultDuration: 6, rampIn: 0.5, rampOut: 1.5,
            summary: "A shower of colourful confetti flutters down over the whole scene."),
        CanvasEffectDefinition(
            name: .bubbles, defaultDuration: 8, rampIn: 1.0, rampOut: 1.5,
            summary: "Bubbles float up and wobble gently over the scene."),
        CanvasEffectDefinition(
            name: .shootingstars, defaultDuration: 10, rampIn: 1.0, rampOut: 1.5,
            summary: "Now and then a shooting star streaks across the sky."),
        CanvasEffectDefinition(
            name: .nebula, defaultDuration: 12, rampIn: 3.0, rampOut: 3.0,
            summary: "Soft purple and teal clouds of light swell across the sky behind the scenery."),
        CanvasEffectDefinition(
            name: .warp, defaultDuration: 4, rampIn: 0.6, rampOut: 1.0,
            summary: "Stars stretch into streaks rushing out from the centre: zooming through space."),
        CanvasEffectDefinition(
            name: .planetrise, defaultDuration: 12, rampIn: 3.0, rampOut: 3.0,
            summary: "A big glowing planet rises slowly from behind the scenery, lighting the scene from below."),
    ]
}

/// The whole tuning surface a canvas effect gets: two keys.
public struct CanvasEffectOptions: Equatable, Sendable, Hashable {
    public static let defaultIntensity = 0.6
    /// Canvas effects stay on for whole beats or whole stories, so the
    /// range is wider than a sticker effect's cycle.
    public static let durationRange: ClosedRange<TimeInterval> = 1...120

    /// 0...1. How strong: denser fog, heavier rain, darker dimlight or night.
    public var intensity: Double = CanvasEffectOptions.defaultIntensity
    /// Seconds the effect stays on, ramps included; `nil` = the effect's default.
    public var duration: TimeInterval? = nil

    public init(intensity: Double = CanvasEffectOptions.defaultIntensity, duration: TimeInterval? = nil) {
        self.intensity = intensity
        self.duration = duration
    }

    /// Options with every value inside the documented ranges.
    public var clamped: CanvasEffectOptions {
        var copy = self
        copy.duration = duration.map { $0.isFinite ? $0.clamped(to: Self.durationRange) : Self.durationRange.lowerBound }
        copy.intensity = intensity.isFinite ? intensity.clamped(to: 0...1) : Self.defaultIntensity
        return copy
    }
}

/// One resolved, declarative canvas trigger: at `at` seconds into the
/// narration, run `effect` over the scene.
public struct CanvasEffectTrigger: Equatable, Sendable {
    public var at: TimeInterval
    /// Optional authoring label ("rain"); never interpreted by the app.
    public var cue: String?
    public var effect: CanvasEffectName
    public var options: CanvasEffectOptions

    public init(at: TimeInterval, cue: String? = nil, effect: CanvasEffectName, options: CanvasEffectOptions = CanvasEffectOptions()) {
        self.at = at
        self.cue = cue
        self.effect = effect
        self.options = options
    }
}
