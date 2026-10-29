import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import StickerStoriesKit

/// Every story of the packs staged on an empty iPad canvas: a sticker sent
/// to someone ends up by them, and every action plays near its words.
/// With STAGE_REPORT=<file> ({pack} in it is the pack), also a report: how
/// late each story's actions and moves land after the words that cue them,
/// and how far apart two characters cued together stand
/// (`docs/stage3d.md`, "The staging report").
@Suite struct StoryTimingReport {
    /// The most a move to someone may leave between them, in widths of the
    /// wider (a walker by a pool it cannot step into stands at its edge;
    /// the third by someone stands a step further out).
    static let farthest = 2.0
    /// The latest an action may play after its words.
    static let latest: TimeInterval = 3

    @Test(arguments: PackStagingTests.packs) func report(_ staged: PackStagingTests.Staged) throws {
        let out = ProcessInfo.processInfo.environment["STAGE_REPORT"]
        guard let pack = try PackStagingTests.load(staged.id), let space = pack.manifest.space else { return }
        var world = StageWorld(space: space, aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1024, height: 768))
        var arts = ["foreground": pack.manifest.foreground]
        for layer in pack.manifest.layers { arts[layer.id] = layer.image }
        for (art, path) in arts {
            guard let source = CGImageSourceCreateWithURL(pack.dir.appendingPathComponent(path) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let grid = OpaqueGrid.of(image),
                let depth = space.planeDepth(art)
            else { continue }
            world.covers.append(.init(depth: depth, grid: grid, area: StageRect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        }
        let screen = StageScreen(
            visible: StageRect(minX: 0, minY: 30, maxX: 1024, maxY: 738),
            avoid: [StageRect(minX: 900, minY: 30, maxX: 1024, maxY: 110)])
        let stickers = Dictionary(uniqueKeysWithValues: pack.manifest.stickers.map { ($0.id, $0) })
        var lines: [String] = []
        var problems: [String] = []
        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        for story in pack.manifest.stories {
            guard let sidecar = story.localizations["en-US"]?.effects,
                let data = try? Data(contentsOf: pack.dir.appendingPathComponent(sidecar)),
                let file = try? EffectTriggerFile(data: data)
            else { continue }
            var random = SeededGenerator(state: 11)
            var actors: [StageActor] = []
            for entrance in file.entranceTriggers {
                guard !actors.contains(where: { $0.stickerID == entrance.stickerID }), let s = stickers[entrance.stickerID] else { continue }
                actors.append(StageActor(
                    id: UUID(), stickerID: s.id, size: space.sizes[s.id] ?? 0.2, ratio: pack.ratios[s.id] ?? 1,
                    stage: s.stage ?? .default, moves: pack.moves[s.id] ?? [], stature: s.size))
            }
            let goes = file.goTriggers + PlacementPlanner.goes(live: file.liveTriggers, places: pack.places, goes: file.goTriggers)
            let cast = StageDirector.cast(
                entrances: file.entranceTriggers, goes: file.goTriggers, live: file.liveTriggers,
                faces: file.expressionTriggers, effects: file.triggers)
            let actions = StageAction.of(file.liveTriggers, frames: { pack.actionFrames[$0] }, faces: { pack.actionFaces[$0] })
            let plans = StageDirector.plan(
                world: world, screen: screen, actors: actors, entrances: file.entranceTriggers, goes: goes,
                policy: .standard, cast: cast, actions: actions, live: file.liveTriggers, random: &random)
            let ids = Dictionary(uniqueKeysWithValues: actors.map { ($0.id, $0.stickerID) })
            let played = StageDirector.delayed(file.liveTriggers, plans: plans, stickers: ids, places: Set(pack.places.keys))
            func actor(_ id: String) -> StageActor? { actors.first { $0.stickerID == id } }
            func rect(_ id: String, _ t: Double) -> StageRect? {
                guard let a = actor(id), let s = plans[a.id]?.sample(at: t), s.opacity > 0.5 else { return nil }
                return world.drawing(at: s.position, size: a.size, ratio: a.ratio)
            }
            /// The gap between two drawings on the screen, in widths of the
            /// wider — across it only when one is up in the air (by a bee in
            /// the sky, a walker stands on the ground below).
            func gap(_ a: String, _ b: String, _ t: Double) -> Double? {
                guard let r = rect(a, t), let q = rect(b, t) else { return nil }
                let aloft = [a, b].contains { id in actor(id).flatMap { plans[$0.id]?.sample(at: t).position.y }.map { $0 > 0.01 } ?? false }
                let dx = max(r.minX - q.maxX, q.minX - r.maxX, 0)
                let dy = aloft ? 0 : max(r.minY - q.maxY, q.minY - r.maxY, 0)
                return (dx * dx + dy * dy).squareRoot() / max(r.maxX - r.minX, q.maxX - q.minX)
            }
            var events: [(at: Double, text: String)] = []
            for e in file.entranceTriggers {
                guard let a = actor(e.stickerID), let plan = plans[a.id] else { continue }
                let end = plan.legs.filter { abs($0.cue - e.at) < 1e-6 }.map(\.end).max() ?? e.at
                events.append((e.at, "enter \(e.stickerID)\(e.by.map { " by \($0)" } ?? "") → in by \(f(end)) (+\(f(end - e.at)))"))
            }
            for go in goes {
                guard let a = actor(go.stickerID), let plan = plans[a.id] else { continue }
                let mine = plan.legs.filter { abs($0.cue - go.at) < 1e-6 }
                let start = mine.map(\.at).min() ?? go.at, end = mine.map(\.end).max() ?? go.at
                var text = "go \(go.stickerID) \(go.kind) \(go.target ?? "") → \(mine.isEmpty ? "NO MOVE" : "\(f(start))–\(f(end)) (+\(f(end - go.at)))")"
                // Once both have got where they were going.
                let settled = [go.stickerID, go.target ?? ""].compactMap(actor).compactMap { plans[$0.id] }.flatMap(\.legs)
                    .filter { $0.cue <= go.at + 1e-6 }.map(\.end).max() ?? 0
                if let t = go.target, actor(t) != nil, let g = gap(go.stickerID, t, max(end, settled) + 0.05) {
                    text += " gap \(f(g))"
                    // (Unless they come the rest of the way to meet it: the
                    // starfish cartwheeling out of the pool to the turtle.)
                    let met = goes.contains { $0.stickerID == t && $0.target == go.stickerID && $0.at > go.at && $0.at - go.at < 5 }
                    if g > Self.farthest, !met { problems.append("\(story.id): \(go.stickerID) sent to \(t) at \(f(go.at)) ends \(f(g)) widths away") }
                }
                events.append((go.at, text))
            }
            for (k, live) in file.liveTriggers.enumerated() {
                let late = played[k].at - live.at
                if late > Self.latest { problems.append("\(story.id): \(live.stickerID) \(live.animationID) at \(f(live.at)) plays \(f(late)) s late") }
                events.append((live.at, "live \(live.stickerID) \(live.animationID) → \(f(played[k].at))\(late > 0.3 ? " LATE +\(f(late))" : "")"))
            }
            // Cued close together, two characters are in the same beat: how far apart.
            let cues = (file.liveTriggers.map { ($0.at, $0.stickerID) } + file.expressionTriggers.map { ($0.at, $0.stickerID) }
                + file.goTriggers.map { ($0.at, $0.stickerID) }).filter { $0.1 != EffectTrigger.allStickers }
            for (t, a) in cues {
                for (u, b) in cues where a < b && u >= t && u - t <= 2.5 {
                    if let g = gap(a, b, u + 1), g > 1.5 { events.append((u, "  far: \(a)–\(b) \(f(g)) widths apart")) }
                }
            }
            if (ProcessInfo.processInfo.environment["STAGE_LEGS"] ?? "").split(separator: ",").contains(Substring(story.id)) {
                for a in actors {
                    for leg in plans[a.id]?.legs ?? [] {
                        events.append((leg.at, "    leg \(a.stickerID) \(leg.kind) \(leg.gait) cue \(f(leg.cue)) \(f(leg.at))–\(f(leg.end)) rate \(f(leg.rate)) move \(leg.move ?? "-") \(leg.support) x \(f(world.screen(leg.path.first ?? Vec3(0, 0, 1)).x))→\(f(world.screen(leg.path.last ?? Vec3(0, 0, 1)).x)) facing \(f(leg.facingTo))\(world.outInWater((leg.path.last ?? Vec3(0, 0, 1)).ground).map { " out \(f($0 * 100))%" } ?? "")"))
                    }
                }
            }
            lines.append("## \(story.id)")
            for e in events.sorted(by: { $0.at < $1.at }) { lines.append("\(f(e.at))  \(e.text)") }
        }
        if let out {
            try lines.joined(separator: "\n").write(
                toFile: out.replacingOccurrences(of: "{pack}", with: staged.id), atomically: true, encoding: .utf8)
        }
        #expect(problems.isEmpty, "\(problems.count) staging problems:\n\(problems.joined(separator: "\n"))")
    }
}
