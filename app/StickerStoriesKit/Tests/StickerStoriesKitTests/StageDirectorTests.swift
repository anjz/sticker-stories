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
    let hovering = [StageMove(id: "fly", cycle: 0.5, stride: 1.2, flies: true, hovers: true, facing: .right)]

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
        let settle = try #require(foxPlan.legs.first)
        #expect(settle.kind == .settle)
        // At its walking pace, never less than the settle.
        #expect(settle.duration >= StageDirector.settle && settle.move == "trot")
        let settled = foxPlan.sample(at: settle.end).position.ground
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

    /// A sticker the story does not use, standing where the cast will
    /// walk, steps aside as the story starts; one out of the way stays.
    @Test func extrasInTheWayStepAside() throws {
        let bear = UUID(), deer = UUID()
        var random = SeededGenerator(state: 3)
        let plans = StageDirector.plan(
            world: world, screen: screen,
            actors: [actor(fox, "fox", at: .init(0.2, 0.12), moves: trot),
                     actor(rabbit, "rabbit", at: .init(0.8, 0.12), moves: trot),
                     actor(bear, "bear", at: .init(0.5, 0.12), moves: trot),
                     actor(deer, "fox", at: .init(0.9, 0.38), moves: trot)],
            entrances: [], goes: [GoTrigger(at: 2, stickerID: "fox", kind: .to, target: "rabbit")],
            policy: .standard, cast: ["fox", "rabbit"], random: &random)
        let moved = try #require(plans[bear])
        #expect(moved.legs.first?.kind == .settle && moved.legs.first?.at == 0)
        let start = world.groundPoint(.init(0.5, 0.12))
        #expect((moved.sample(at: 30).position.ground - start).length > 0.3)
        // The far "fox" is the same sticker as the cast's: it is cast too.
        #expect(plans[deer]?.legs.allSatisfy { $0.kind != .settle } ?? true)
    }

    /// Stepping aside, never behind a tree.
    @Test func extrasStepAsideIntoView() throws {
        let bear = UUID()
        let w = covered(world)
        for seed in 1...6 {
            var random = SeededGenerator(state: UInt64(seed))
            let plans = StageDirector.plan(
                world: w, screen: screen,
                actors: [actor(fox, "fox", at: .init(0.2, 0.12), moves: trot),
                         actor(rabbit, "rabbit", at: .init(0.8, 0.12), moves: trot),
                         actor(bear, "bear", at: .init(0.5, 0.12), moves: trot)],
                entrances: [], goes: [GoTrigger(at: 2, stickerID: "fox", kind: .to, target: "rabbit")],
                policy: .standard, cast: ["fox", "rabbit"], random: &random)
            let p = try #require(plans[bear]).sample(at: 30).position
            var r = w.drawing(at: p, size: 0.5, ratio: 1)
            r.maxY += (r.maxY - r.minY) * 0.5
            #expect(w.hidden(r, atDepth: p.z) < 0.05)
        }
    }

    /// A walker's steps keep pace with the ground: its leg takes as long
    /// as its steps take to cover the way, at a rate near the drawn one.
    @Test func walkersNeverGlide() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.15, 0.15), moves: trot), actor(rabbit, "rabbit", at: .init(0.45, 0.25))],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let leg = try #require(plans[fox]?.legs.last)
        #expect(leg.gait == .walk && leg.move == "trot")
        #expect(StageDirector.rates.contains(leg.rate))
        let length = zip(leg.path, leg.path.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).length }
        let speed = 0.6 * (testSpace().sizes["fox"] ?? 0.2) / 0.8  // stride × width ÷ cycle
        #expect(abs(leg.duration * leg.rate * speed - length) < 1e-6)
        // A long way never keeps the story waiting: it hurries.
        let far = plan([actor(fox, "fox", at: .init(0.06, 0.07), moves: trot), actor(rabbit, "rabbit", at: .init(0.94, 0.38))],
                       goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let long = try #require(far[fox]?.legs.last)
        #expect(long.duration <= StageDirector.maxTravel + 1e-9 && long.rate > 1)
    }

    /// An action cued while its sticker is on its way waits until it gets
    /// there; one cued when it is still plays then.
    @Test func actionsWaitForTheMoveToEnd() throws {
        let plans = plan(
            [actor(fox, "fox", at: .init(0.15, 0.15), moves: trot), actor(rabbit, "rabbit", at: .init(0.8, 0.4))],
            goes: [GoTrigger(at: 1, stickerID: "fox", kind: .to, target: "rabbit")])
        let leg = try #require(plans[fox]?.legs.last)
        let live = StageDirector.delayed(
            [LiveAnimationTrigger(at: 1.5, stickerID: "fox", animationID: "jump"),
             LiveAnimationTrigger(at: 0.5, stickerID: "fox", animationID: "nod"),
             LiveAnimationTrigger(at: 1.5, stickerID: "rabbit", animationID: "nod")],
            plans: plans, stickers: [fox: "fox", rabbit: "rabbit"], places: [])
        #expect(live.map(\.at) == [leg.end, 0.5, 1.5])
    }

    /// A flyer resting in the air keeps its wings going: one that flies to
    /// the sky, and one the child put there.
    @Test func flyersInTheAirKeepFlying() throws {
        let plans = plan(
            [actor(bee, "bee", at: .init(0.5, 0.7), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: hovering),
             actor(bird, "bird", at: .init(0.3, 0.15), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: hovering)],
            goes: [GoTrigger(at: 1, stickerID: "bird", kind: .to, target: "sky")])
        let hover = try #require(plans[bee]?.travel(at: 5))
        #expect(hover.move == "fly" && hover.stays)
        let flight = try #require(plans[bird]?.travel(at: 30))
        #expect(flight.move == "fly" && flight.stays && !flight.isMoving(at: 30))
        // Bobbing gently where it is.
        let a = try #require(plans[bird]?.sample(at: 30)), b = try #require(plans[bird]?.sample(at: 30.4))
        #expect(a.position.y != b.position.y && abs(a.position.y - b.position.y) < 0.05)
        #expect(a.position.x == b.position.x && a.position.z == b.position.z)
    }

    /// One that cannot hover never stops in the air: it flies a loop round
    /// its spot, turning at each end, on screen, until it goes on — from
    /// wherever it is on the loop, without a jump.
    @Test func flyersThatCannotHoverCircle() throws {
        let plans = plan(
            [actor(bird, "bird", at: .init(0.3, 0.15), stage: StickerStage(entrance: .fly, on: ["sky"]), moves: flight),
             actor(fox, "fox", at: .init(0.7, 0.2), moves: trot)],
            goes: [GoTrigger(at: 1, stickerID: "bird", kind: .to, target: "sky"),
                   GoTrigger(at: 21.3, stickerID: "bird", kind: .to, target: "fox")])
        let bird = try #require(plans[self.bird])
        let up = try #require(bird.legs.first { $0.at == 1 })
        let loop = try #require(up.circling)
        #expect(up.stays && loop.across > 0 && loop.toward > 0)
        let lap = stride(from: up.end + 2, to: up.end + 7, by: 0.1).map { bird.sample(at: $0) }
        let xs = lap.map(\.position.x), zs = lap.map(\.position.z)
        #expect(xs.max()! - xs.min()! > loop.across && zs.max()! - zs.min()! > loop.toward / 2)
        // Out its way, back the other.
        #expect(lap.contains { $0.facing > 0.9 } && lap.contains { $0.facing < -0.9 })
        for sample in lap {
            let r = world.drawing(at: sample.position, size: testSpace().sizes["bird"] ?? 0.2, ratio: 1)
            #expect(r.minX >= 0 && r.maxX <= 1000 && r.minY >= 0 && r.maxY <= 750)
        }
        // On to the fox from where it was on its loop.
        let next = try #require(bird.legs.first { $0.at == 21.3 })
        let before = bird.sample(at: next.at - 0.01), after = bird.sample(at: next.at + 0.01)
        #expect((before.position - after.position).length < 0.02)
        #expect(abs(before.facing - after.facing) < 0.2)
        #expect((bird.sample(at: next.end).position - next.path.last!).length < 1e-6)
    }

    /// The world with a plane at depth 2 painted over the art's right
    /// third (a tree): what stands behind it there is hidden.
    func covered(_ w: StageWorld) -> StageWorld {
        var w = w
        var cells = [Bool](repeating: false, count: 30 * 30)
        for r in 0..<30 { for c in 20..<30 { cells[r * 30 + c] = true } }
        w.covers = [.init(depth: 2, grid: OpaqueGrid(columns: 30, rows: 30, cells: cells), area: StageRect(minX: 0, minY: 0, maxX: 1, maxY: 1))]
        return w
    }

    @Test func planesInFrontHideWhatIsBehindThem() {
        let w = covered(world)
        let behind = w.groundPoint(.init(0.85, 0.3)).onGround, before = w.groundPoint(.init(0.85, 0.15)).onGround
        #expect(w.hidden(w.drawing(at: behind, size: 0.2, ratio: 0.5), atDepth: behind.z) == 1)
        #expect(w.hidden(w.drawing(at: before, size: 0.2, ratio: 0.5), atDepth: before.z) == 0)
    }

    /// Where the director chooses, a tiny visitor comes to the front, and
    /// nobody lands behind the tree.
    @Test func smallOnesComeToTheFrontAndNobodyLandsBehindATree() throws {
        let w = covered(world)
        let meadow = StickerStage(entrance: .hop, on: ["meadow"])
        for seed in 1...8 {
            var random = SeededGenerator(state: UInt64(seed))
            let plans = StageDirector.plan(
                world: w, screen: screen,
                actors: [StageActor(id: bee, stickerID: "bee", size: 0.06, ratio: 1, stage: meadow, stature: .tiny),
                         StageActor(id: bird, stickerID: "bird", size: 0.1, ratio: 1, stage: meadow, stature: .small),
                         StageActor(id: fox, stickerID: "fox", size: 0.3, ratio: 1, stage: meadow, stature: .big)],
                entrances: [EntranceTrigger(at: 1, stickerID: "bee"), EntranceTrigger(at: 1, stickerID: "bird"),
                            EntranceTrigger(at: 1, stickerID: "fox")],
                goes: [], policy: .standard, random: &random)
            let near = w.space.stand.near, far = w.space.stand.far
            for (id, size) in [(bee, 0.06), (bird, 0.1), (fox, 0.3)] {
                let p = try #require(plans[id]).sample(at: 30).position
                #expect(w.hidden(w.drawing(at: p, size: size, ratio: 1), atDepth: p.z) < 0.2)
                if id != fox { #expect(p.z < near + (far - near) * 0.3) }
            }
        }
    }

    /// A child's sticker its depth puts behind the tree steps out to where
    /// it shows.
    @Test func aChildsStickerBehindATreeStepsOut() throws {
        var random = SeededGenerator(state: 7)
        let w = covered(world)
        let plans = StageDirector.plan(
            world: w, screen: screen, actors: [actor(fox, "fox", at: .init(0.85, 0.3), moves: trot)], entrances: [],
            goes: [], policy: .standard, random: &random)
        let leg = try #require(plans[fox]?.legs.first)
        #expect(leg.kind == .settle)
        let p = try #require(plans[fox]).sample(at: leg.end).position
        #expect(w.hidden(w.drawing(at: p, size: 0.3, ratio: 1), atDepth: p.z) < 0.15)
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
                        hovers: json["hovers"] as? Bool ?? false, on: json["on"] as? [String] ?? [], stays: json["stays"] as? Bool ?? false,
                        waterline: json["waterline"] as? Double ?? 0, facing: (json["facing"] as? String).flatMap(StageMove.Facing.init(rawValue:)), seconds: loop ? 0 : 1))
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
        var world = StageWorld(space: space, aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1024, height: 768))
        // What the trees, the reeds and the foreground hide.
        var arts = ["foreground": pack.manifest.foreground]
        for layer in pack.manifest.layers { arts[layer.id] = layer.image }
        for (art, path) in arts {
            guard let source = CGImageSourceCreateWithURL(pack.dir.appendingPathComponent(path) as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let grid = OpaqueGrid.of(image),
                let depth = space.planeDepth(art)
            else { continue }
            world.covers.append(.init(depth: depth, grid: grid, area: StageRect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        }
        #expect(world.covers.count == pack.manifest.layers.count + 1)
        // An iPad's landscape window shows the art less a few percent top and bottom.
        let screen = StageScreen(
            visible: StageRect(minX: 0, minY: 30, maxX: 1024, maxY: 738),
            avoid: [StageRect(minX: 900, minY: 30, maxX: 1024, maxY: 110)])
        let waterPlaces = Set(world.grounds.filter(\.water).map(\.place))
        let stickers = Dictionary(uniqueKeysWithValues: pack.manifest.stickers.map { ($0.id, $0) })
        var problems: [String] = []
        var backwards: [String] = []
        var circling = 0
        for story in pack.manifest.stories {
            guard let sidecar = story.localizations["en-US"]?.effects,
                let data = try? Data(contentsOf: pack.dir.appendingPathComponent(sidecar)),
                let file = try? EffectTriggerFile(data: data)
            else { continue }
            // Spots are chosen with a little chance: two draws of each.
            for (crowded, seed) in [(false, 11), (true, 11), (false, 7777), (true, 7777)] {
                var random = SeededGenerator(state: UInt64(seed))
                // The story's cast as visitors; on the crowded canvas the
                // child has placed its stickers (and a few more) here and there.
                var actors: [StageActor] = []
                let placed: [String] = crowded
                    ? Array(Set(story.requiredStickers + story.optionalStickers + ["bear", "deer", "mushroom", "hedgehog"])).sorted() : []
                for (k, id) in placed.enumerated() {
                    guard let s = stickers[id] else { continue }
                    let feet = SceneSpace.Point(0.08 + 0.84 * Double((k * 37) % 11) / 10, 0.1 + 0.4 * Double((k * 53) % 7) / 6)
                    actors.append(StageActor(
                        id: UUID(), stickerID: id, size: space.sizes[id] ?? 0.2, ratio: pack.ratios[id] ?? 1,
                        stage: s.stage ?? .default, moves: pack.moves[id] ?? [], placed: feet, stature: s.size))
                }
                for entrance in file.entranceTriggers where !placed.contains(entrance.stickerID) {
                    guard !actors.contains(where: { $0.stickerID == entrance.stickerID }), let s = stickers[entrance.stickerID] else { continue }
                    actors.append(StageActor(
                        id: UUID(), stickerID: s.id, size: space.sizes[s.id] ?? 0.2, ratio: pack.ratios[s.id] ?? 1,
                        stage: s.stage ?? .default, moves: pack.moves[s.id] ?? [], stature: s.size))
                }
                let placedIDs = Set(actors.filter { $0.placed != nil }.map(\.id))
                let goes = file.goTriggers + PlacementPlanner.goes(live: file.liveTriggers, places: pack.places, goes: file.goTriggers)
                let cast = StageDirector.cast(
                    entrances: file.entranceTriggers, goes: file.goTriggers, live: file.liveTriggers,
                    faces: file.expressionTriggers, effects: file.triggers)
                let plans = StageDirector.plan(
                    world: world, screen: screen, actors: actors, entrances: file.entranceTriggers, goes: goes,
                    policy: .standard, cast: cast, random: &random)
                // A whole lap past the last leg: whoever circles is seen all round its loop.
                let end = (plans.values.flatMap(\.legs).map(\.end).max() ?? 0) + StagePlan.lapTime + 1
                circling += plans.values.flatMap(\.legs).filter { $0.circling != nil }.count
                // Nobody in the story stands mostly hidden behind another
                // sticker while both are still (the deer in front of the
                // frog); one passing in front on its way is fine.
                var t0 = StageDirector.settle
                let last = plans.values.flatMap(\.legs).map(\.end).max() ?? 0
                while t0 <= last + 1 {
                    defer { t0 += 0.25 }
                    let shown = actors.compactMap { a -> (StageActor, StagePlan.Sample, StageRect, Bool)? in
                        guard let plan = plans[a.id] else { return nil }
                        let s = plan.sample(at: t0)
                        guard s.opacity > 0.5, s.support != .off else { return nil }
                        let still = !plan.legs.contains { $0.at <= t0 && t0 < $0.end }
                        return (a, s, world.drawing(at: s.position, size: a.size, ratio: a.ratio), still)
                    }
                    for (a, s, r, still) in shown where still && cast.contains(a.stickerID) {
                        func linked(_ x: StageSupport, _ id: UUID) -> Bool {
                            switch x {
                            case .on(let h), .under(let h), .beside(let h): return h == id
                            default: return false
                            }
                        }
                        let front = shown.filter { b in
                            b.0.id != a.id && b.3 && b.1.position.z < s.position.z - 1e-6
                                && !linked(s.support, b.0.id) && !linked(b.1.support, a.id)
                        }
                        let h = StageWorld.hidden(r, behind: front.map(\.2))
                        if h > 0.5 {
                            let tag = "\(story.id)\(crowded ? " (crowded)" : "") \(a.stickerID)"
                            let who = front.filter { StageWorld.hidden(r, behind: [$0.2]) > 0.1 }.map(\.0.stickerID).sorted()
                            problems.append("\(tag): behind \(who.joined(separator: "+")) at \(String(format: "%.1f", t0))")
                        }
                    }
                }
                // Whoever travels across faces the way it goes.
                for a in actors {
                    guard let plan = plans[a.id] else { continue }
                    var t = 0.0
                    let step = 0.05
                    while t <= end {
                        defer { t += step }
                        let s = plan.sample(at: t), next = plan.sample(at: t + step)
                        guard s.opacity > 0.5, next.opacity > 0.5 else { continue }
                        let leg = plan.legs.last { $0.at <= t }
                        let art = StageMove.pick(a.moves, by: leg?.move).flatMap(\.facing) ?? a.moves.first?.facing
                        guard let art else { continue }
                        let dx = world.screen(next.position).x - world.screen(s.position).x
                        let width = world.drawnHeight(size: a.size, atDepth: s.position.z) * a.ratio
                        // Faster than a quarter of its width a second, sideways
                        // — but a little sidestep making room is not a walk.
                        guard abs(dx) / step > width * 0.25 else { continue }
                        if let now = plan.legs.last(where: { $0.at <= t + step }), now.kind == .shuffle,
                            let a0 = now.path.first, let a1 = now.path.last,
                            abs(world.screen(a1).x - world.screen(a0).x) < width * 0.25
                        { continue }
                        let looks = (art == .right ? 1.0 : -1.0) * (s.facing < 0 ? -1 : 1)
                        if looks * dx < 0 {
                            let what = leg.map { $0.end > t ? "\($0.kind) \($0.gait)" : "after \($0.kind) \($0.gait)" } ?? "start"
                            backwards.append("\(story.id)\(crowded ? " (crowded)" : "") \(a.stickerID): \(what) at \(String(format: "%.1f", t))")
                        }
                    }
                }
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
                        // A child's sticker left in the water wades out as the story starts.
                        let settling = plan.legs.contains { $0.kind == .settle && $0.at <= t && t < $0.end }
                        if land, onFoot, !settling, let water = world.water(at: s.position.ground) {
                            problems.append("\(tag): in the \(water) at \(String(format: "%.1f", t))")
                        }
                        // In the water only afloat, its feet under it (never standing in it).
                        if !land, onFoot, !settling, let water = world.water(at: s.position.ground),
                            !a.moves.contains(where: { $0.waterline > 0 && $0.on.contains(water) })
                        {
                            problems.append("\(tag): standing in the \(water) at \(String(format: "%.1f", t))")
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
                            // On (or under) a sticker the child put by a tree, it
                            // shares that sticker's place.
                            var onTheChilds = false
                            switch s.support {
                            case .on(let host), .under(let host): onTheChilds = placedIDs.contains(host)
                            default: break
                            }
                            if !onTheChilds, world.hidden(r, atDepth: s.position.z) > 0.35 {
                                problems.append("\(tag): hidden behind the scene at \(String(format: "%.1f", t))")
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
        // The birds, the owl and the woodpecker are left in the air now and then.
        #expect(circling > 0)
        let turned = Dictionary(grouping: backwards) { $0.components(separatedBy: " at ")[0] }
            .map { "\($0.key) ×\($0.value.count) — first at \($0.value[0].components(separatedBy: " at ").last!)" }.sorted()
        #expect(backwards.isEmpty, "\(turned.count) travel backwards:\n\(turned.joined(separator: "\n"))")
        #expect(problems.isEmpty, "\(problems.count) problems:\n\(report.prefix(40).joined(separator: "\n"))")
    }
}
