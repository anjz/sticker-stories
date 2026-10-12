import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import StickerStoriesKit

@Suite struct StageDirectorTests {
    let world = testWorld()
    let screen = StageScreen(visible: StageRect(minX: 0, minY: 0, maxX: 1000, maxY: 750))
    let fox = UUID(), rabbit = UUID(), duck = UUID(), bee = UUID(), flower = UUID(), bird = UUID(), woodpecker = UUID()

    func actor(
        _ id: UUID, _ sticker: String, at feet: SceneSpace.Point? = nil,
        stage: StickerStage = StickerStage(entrance: .hop, on: ["meadow"]), moves: [StageMove] = []
    ) -> StageActor {
        StageActor(
            id: id, stickerID: sticker, size: testSpace().sizes[sticker] ?? 0.2, ratio: 1, stage: stage, moves: moves,
            placed: feet)
    }

    let trot = [StageMove(id: "trot", cycle: 0.8, stride: 0.6, facing: .right)]
    let flight = [StageMove(id: "fly", cycle: 0.5, stride: 1.2, flies: true, facing: .right)]

    func plan(_ actors: [StageActor], entrances: [EntranceTrigger] = [], goes: [GoTrigger] = []) -> [UUID: StagePlan] {
        var random = SeededGenerator(state: 7)
        return StageDirector.plan(
            world: world, screen: screen, actors: actors, entrances: entrances, goes: goes, policy: .standard,
            random: &random)
    }

    @Test func aChildsStickerInWaterItDoesNotBelongInSettlesOnLand() throws {
        let plans = plan([
            actor(fox, "fox", at: .init(0.55, 0.25), moves: trot),
            actor(duck, "duck", at: .init(0.55, 0.25), stage: StickerStage(entrance: .hop, on: ["pond"])),
        ])
        let foxPlan = try #require(plans[fox])
        #expect(foxPlan.legs.first?.kind == .settle)
        let settled = foxPlan.sample(at: StageDirector.settle).position.ground
        #expect(world.water(at: settled) == nil && world.canStand(at: settled, belongsIn: []))
        // The duck belongs in the pond: it stays.
        #expect(try #require(plans[duck]).legs.isEmpty)
    }

    @Test func goingToSomeoneAcrossThePondWalksRoundItAndStandsBesideThem() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.3, 0.25), moves: trot), actor(rabbit, "flower", at: .init(0.85, 0.25))],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "flower")])
        let leg = try #require(plans[fox]?.legs.last)
        #expect(leg.path.count > 2)  // round the pond
        for k in 0...50 {
            let p = StagePlan.along(leg.path, Double(k) / 50)
            #expect(world.water(at: p.ground) == nil)
        }
        let end = try #require(leg.path.last)
        let flowerAt = world.groundPoint(.init(0.85, 0.25))
        #expect(abs(end.z - (flowerAt.z - StageDirector.inFront)) < 0.05)  // at its depth, just in front
        #expect(leg.support == .beside(rabbit))
    }

    @Test func aBeeGoesOnTheFlowerAndABirdOntoTheBranch() throws {
        let plans = plan(
            [actor(bee, "bee", at: .init(0.3, 0.6), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: flight),
             actor(flower, "flower", at: .init(0.3, 0.15), stage: StickerStage(entrance: .grow, on: ["meadow"])),
             actor(bird, "bird", at: .init(0.6, 0.15), stage: StickerStage(entrance: .fly, on: ["branches"]), moves: flight)],
            goes: [GoTrigger(at: 1, stickerID: "bee", kind: .on, target: "flower"),
                   GoTrigger(at: 1, stickerID: "bird", kind: .to, target: "branches")])
        let beeEnd = try #require(plans[bee]?.sample(at: 10))
        let flowerAt = world.groundPoint(.init(0.3, 0.15))
        #expect(beeEnd.support == .on(flower) && beeEnd.position.y > 0.1 && beeEnd.position.z < flowerAt.z)
        let birdEnd = try #require(plans[bird]?.sample(at: 10))
        #expect(birdEnd.support == .perch("branches") && abs(birdEnd.position.z - (2 - StageDirector.inFront)) < 1e-9)
        #expect(plans[bird]?.legs.last?.gait == .fly)
    }

    @Test func aVisitorComesInFromTheSideOntoLandOnScreen() throws {
        let plans = plan([actor(fox, "fox", moves: trot)], entrances: [EntranceTrigger(at: 2, stickerID: "fox")])
        let p = try #require(plans[fox])
        #expect(p.sample(at: 1).opacity == 0)
        let leg = try #require(p.legs.first)
        #expect(leg.kind == .entrance && leg.at == 2)
        let start = try #require(leg.path.first), end = try #require(leg.path.last)
        let u = world.project(start).u
        #expect(u < 0 || u > 1)  // off the art at a side
        #expect(world.canStand(at: end.ground, belongsIn: []))
        let r = world.drawing(at: end, size: 0.3, ratio: 1)
        #expect(r.minX >= 0 && r.maxX <= 1000 && r.minY >= 0 && r.maxY <= 750)
    }

    @Test func awayAndBack() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.3, 0.15), moves: trot)],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .away), GoTrigger(at: 10, stickerID: "fox", kind: .back)])
        let p = try #require(plans[fox])
        #expect(p.sample(at: 9).opacity == 0)
        let home = world.groundPoint(.init(0.3, 0.15))
        let back = p.sample(at: 30)
        #expect(back.opacity == 1 && (back.position.ground - home).length < 1e-6)
    }

    @Test func theWoodpeckerFacesTheBark() throws {
        let plans = plan(
            [actor(woodpecker, "woodpecker", at: .init(0.5, 0.15), stage: StickerStage(entrance: .fly, on: ["trunks"]),
                   moves: [StageMove(id: "fly", cycle: 0.5, stride: 1, flies: true, facing: .right)])],
            goes: [GoTrigger(at: 1, stickerID: "woodpecker", kind: .to, target: "trunks")])
        let end = try #require(plans[woodpecker]?.sample(at: 10))
        #expect(end.support == .perch("trunks"))
        // Facing left (its moves face right: mirrored), its centre right of the bark.
        #expect(end.facing == -1)
        let bark = world.point(.init(0.15, 0.5), atDepth: 2)
        #expect(end.position.x > bark.x)
    }
}

/// Plans every story of the real Forest pack on an empty canvas and on a
/// crowded one, and checks the stage keeps its rules all the way through.
@Suite struct ForestStagingTests {
    struct Pack {
        let manifest: PackManifest
        let dir: URL
        var moves: [String: [StageMove]] = [:]
        var places: [LiveAnimationKey: [String]] = [:]
        var ratios: [String: Double] = [:]
    }

    static func load() throws -> Pack? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("packs/forest")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        var pack = Pack(manifest: try JSONDecoder().decode(PackManifest.self, from: data), dir: dir)
        for sticker in pack.manifest.stickers {
            for path in sticker.animations {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(path)),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let id = json["id"] as? String ?? ""
                if (json["kind"] as? String) == "move" {
                    let loop = json["loop"] != nil
                    pack.moves[sticker.id, default: []].append(StageMove(
                        id: id, cycle: loop ? 0.8 : nil, stride: json["stride"] as? Double ?? 0,
                        hops: json["hops"] as? Bool ?? false, flies: json["flies"] as? Bool ?? false,
                        on: json["on"] as? [String] ?? [], stays: json["stays"] as? Bool ?? false,
                        facing: (json["facing"] as? String).flatMap(StageMove.Facing.init(rawValue:)), seconds: loop ? 0 : 1))
                }
                if let place = json["place"] as? [String] {
                    pack.places[LiveAnimationKey(stickerID: sticker.id, animationID: id)] = place
                }
            }
            if let source = CGImageSourceCreateWithURL(dir.appendingPathComponent(sticker.image) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let box = OpaqueBounds.of(image)
            {
                pack.ratios[sticker.id] = Double(box.width / box.height) * Double(image.width) / Double(image.height)
            }
        }
        return pack
    }

    @Test func everyStoryKeepsTheStagesRules() throws {
        guard let pack = try Self.load(), let space = pack.manifest.space else { return }
        let world = StageWorld(space: space, aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1024, height: 768))
        // An iPad's landscape window shows the art less a few percent top and bottom.
        let screen = StageScreen(
            visible: StageRect(minX: 0, minY: 30, maxX: 1024, maxY: 738),
            avoid: [StageRect(minX: 900, minY: 30, maxX: 1024, maxY: 110)])
        let waterPlaces = Set(world.grounds.filter(\.water).map(\.place))
        let stickers = Dictionary(uniqueKeysWithValues: pack.manifest.stickers.map { ($0.id, $0) })
        var problems: [String] = []
        for story in pack.manifest.stories {
            guard let sidecar = story.localizations["en-US"]?.effects,
                let data = try? Data(contentsOf: pack.dir.appendingPathComponent(sidecar)),
                let file = try? EffectTriggerFile(data: data)
            else { continue }
            for crowded in [false, true] {
                var random = SeededGenerator(state: 11)
                // The story's cast as visitors; on the crowded canvas the
                // child has placed its stickers (and a few more) here and there.
                var actors: [StageActor] = []
                let placed: [String] = crowded ? Array(Set(story.requiredStickers + story.optionalStickers + ["bear", "deer"])).sorted() : []
                for (k, id) in placed.enumerated() {
                    guard let s = stickers[id] else { continue }
                    let feet = SceneSpace.Point(0.08 + 0.84 * Double((k * 37) % 11) / 10, 0.1 + 0.4 * Double((k * 53) % 7) / 6)
                    actors.append(StageActor(
                        id: UUID(), stickerID: id, size: space.sizes[id] ?? 0.2, ratio: pack.ratios[id] ?? 1,
                        stage: s.stage ?? .default, moves: pack.moves[id] ?? [], placed: feet))
                }
                for entrance in file.entranceTriggers where !placed.contains(entrance.stickerID) {
                    guard !actors.contains(where: { $0.stickerID == entrance.stickerID }), let s = stickers[entrance.stickerID] else { continue }
                    actors.append(StageActor(
                        id: UUID(), stickerID: s.id, size: space.sizes[s.id] ?? 0.2, ratio: pack.ratios[s.id] ?? 1,
                        stage: s.stage ?? .default, moves: pack.moves[s.id] ?? []))
                }
                let goes = file.goTriggers + PlacementPlanner.goes(live: file.liveTriggers, places: pack.places, goes: file.goTriggers)
                let plans = StageDirector.plan(
                    world: world, screen: screen, actors: actors, entrances: file.entranceTriggers, goes: goes,
                    policy: .standard, random: &random)
                let end = (plans.values.flatMap(\.legs).map(\.end).max() ?? 0) + 1
                for a in actors {
                    guard let plan = plans[a.id] else { continue }
                    let land = !(a.stage.on + a.moves.flatMap(\.on)).contains { waterPlaces.contains($0) }
                    var t = 0.0
                    while t <= end {
                        defer { t += 0.1 }
                        let s = plan.sample(at: t)
                        guard s.opacity > 0.5 else { continue }
                        let tag = "\(story.id)\(crowded ? " (crowded)" : "") \(a.stickerID)"
                        let onFoot = s.position.y < 0.01 && t >= StageDirector.settle
                        if land, onFoot, let water = world.water(at: s.position.ground) {
                            problems.append("\(tag): in the \(water) at \(String(format: "%.1f", t))")
                        }
                        let moving = plan.legs.contains { $0.at <= t && t < $0.end }
                        if !moving, t >= StageDirector.settle, s.support != .off {
                            let r = world.drawing(at: s.position, size: a.size, ratio: a.ratio)
                            let c = screen.clear
                            if r.minX < c.minX - 2 || r.maxX > c.maxX + 2 || r.minY < c.minY - 2 || r.maxY > c.maxY + 2 {
                                problems.append("\(tag): not wholly on screen at \(String(format: "%.1f", t)) \(r)")
                            }
                            if onFoot, world.footprints.contains(where: { $0.contains(s.position.ground) }) {
                                problems.append("\(tag): on a tree's roots at \(String(format: "%.1f", t))")
                            }
                        }
                    }
                }
            }
        }
        let report = Dictionary(grouping: problems) { p -> String in
            let parts = p.split(separator: ":", maxSplits: 1)
            return parts[0] + ":" + (parts.count > 1 ? String(parts[1].split(separator: " at ")[0]) : "")
        }.map { "\($0.key) ×\($0.value.count) — first \($0.value.first!.split(separator: ":", maxSplits: 1).last!)" }.sorted()
        #expect(problems.isEmpty, "\(problems.count) problems:\n\(report.prefix(40).joined(separator: "\n"))")
    }
}
