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
    case shootingstars
    // Indoors
    case dimlight
    case windowlight
    case firelight
    case rainywindow
    // Outdoors and indoors
    case confetti
    // Outdoors, indoors and underwater
    case bubbles
    // Space: a real sky over a moon or planet with no air
    case comet
    case nightfall
    case daybreak
    case eclipse
    case milkyway
    case satellites
    case dust
    case floodlights
    case glints
    // Underwater
    case sunrays
    case ripples
    case deepwater
    case glowplankton
    case current
    case sandcloud

    /// The pack settings (`PackManifest.setting`) this effect suits.
    public var settings: Set<PackSetting> {
        switch self {
        case .fog, .rain, .sunshine, .rainbow, .night, .snow, .sunset, .clouds, .wind, .fireflies,
            .leaves, .shootingstars: [.outdoors]
        case .dimlight, .windowlight, .firelight, .rainywindow: [.indoors]
        case .confetti: [.outdoors, .indoors]
        case .bubbles: [.outdoors, .indoors, .underwater]
        case .comet, .nightfall, .daybreak, .eclipse, .milkyway, .satellites, .dust, .floodlights, .glints: [.space]
        case .sunrays, .ripples, .deepwater, .glowplankton, .current, .sandcloud: [.underwater]
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
            summary: "Rain falls over everything under a grey sky with a few grey clouds; the light cools a little."),
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
            summary: "Soft snowflakes drift down over everything; the top of the sky turns white and the light cool and bright. It keeps falling until the sun comes out or rain washes it away, and settles on the ground as a snow cover that stays after the snowfall until sunshine or rain melts it."),
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
            name: .shootingstars, defaultDuration: 10, rampIn: 1.0, rampOut: 1.5,
            summary: "Now and then a shooting star streaks across the sky."),
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
            name: .comet, defaultDuration: 12, rampIn: 1.5, rampOut: 2.0,
            summary: "A comet with a long glowing tail glides slowly across the sky."),
        CanvasEffectDefinition(
            name: .nightfall, defaultDuration: 10, rampIn: 2.5, rampOut: 2.5,
            summary: "The long night comes: the ground darkens to a deep blue-grey and many more stars come out."),
        CanvasEffectDefinition(
            name: .daybreak, defaultDuration: 8, rampIn: 1.5, rampOut: 2.0,
            summary: "Stark white sunlight sweeps across the scene from the left, with a soft glare in the top-left corner."),
        CanvasEffectDefinition(
            name: .eclipse, defaultDuration: 12, rampIn: 3.0, rampOut: 3.0,
            summary: "The light turns a deep, dim copper-red for a while, then comes back."),
        CanvasEffectDefinition(
            name: .milkyway, defaultDuration: 12, rampIn: 3.0, rampOut: 3.0,
            summary: "A pale band of countless stars glows across the black sky."),
        CanvasEffectDefinition(
            name: .satellites, defaultDuration: 12, rampIn: 1.5, rampOut: 2.0,
            summary: "A few tiny steady lights glide slowly across the sky, far overhead."),
        CanvasEffectDefinition(
            name: .dust, defaultDuration: 5, rampIn: 0.8, rampOut: 2.0,
            summary: "A cloud of grey dust sprays up across the lower scene and falls back down."),
        CanvasEffectDefinition(
            name: .floodlights, defaultDuration: 10, rampIn: 0.8, rampOut: 1.5,
            summary: "Floodlights switch on: white beams from the top corners and pools of light on the ground."),
        CanvasEffectDefinition(
            name: .glints, defaultDuration: 8, rampIn: 1.5, rampOut: 2.0,
            summary: "The ground sparkles softly here and there, as the light catches tiny beads."),
        CanvasEffectDefinition(
            name: .sunrays, defaultDuration: 10, rampIn: 2.0, rampOut: 2.0,
            summary: "Shafts of sunlight slant down from the surface and sway slowly."),
        CanvasEffectDefinition(
            name: .ripples, defaultDuration: 12, rampIn: 2.0, rampOut: 2.0,
            summary: "A net of rippling light plays over the scene, brightest near the sea floor."),
        CanvasEffectDefinition(
            name: .deepwater, defaultDuration: 12, rampIn: 2.5, rampOut: 2.5,
            summary: "The water darkens to a deep blue, most of all at the edges."),
        CanvasEffectDefinition(
            name: .glowplankton, defaultDuration: 12, rampIn: 2.0, rampOut: 2.0,
            summary: "Tiny blue-green lights twinkle and drift through the water."),
        CanvasEffectDefinition(
            name: .current, defaultDuration: 8, rampIn: 1.2, rampOut: 1.5,
            summary: "A gentle current sweeps specks and bits of green across the scene."),
        CanvasEffectDefinition(
            name: .sandcloud, defaultDuration: 6, rampIn: 1.5, rampOut: 2.5,
            summary: "A cloud of sand swirls up from the sea floor and slowly settles."),
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
