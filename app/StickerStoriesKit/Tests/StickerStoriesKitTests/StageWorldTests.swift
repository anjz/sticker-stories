import Foundation
import Testing

@testable import StickerStoriesKit

/// A small scene: horizon 0.5, the ground at depth 1 on the art's bottom,
/// a meadow with a pond in it, an oak whose roots stand on the left, a
/// branch on the oak, a sky.
func testSpace() -> SceneSpace {
    SceneSpace(
        horizon: 0.5, ground: 0, back: 6, stand: .init(near: 1.1, far: 5), floor: 0.03,
        layers: [
            .init(id: "oak", art: "trees", depth: 2, footprint: [.init(0.05, 0.24), .init(0.2, 0.24), .init(0.2, 0.26), .init(0.05, 0.26)]),
            .init(id: "front", depth: 1),
        ],
        places: [
            "meadow": .init(ground: [.init(0.05, 0.06), .init(0.95, 0.06), .init(0.95, 0.4), .init(0.05, 0.4)]),
            "pond": .init(ground: [.init(0.4, 0.2), .init(0.7, 0.2), .init(0.7, 0.3), .init(0.4, 0.3)], water: true),
            "branches": .init(lines: [.init(layer: "oak", points: [.init(0.1, 0.8), .init(0.25, 0.82)])]),
            "trunks": .init(lines: [.init(layer: "oak", points: [.init(0.15, 0.45), .init(0.15, 0.6)], facing: .left)]),
            "sky": .init(air: .init(area: [.init(0.35, 0.6), .init(0.8, 0.6), .init(0.8, 0.85), .init(0.35, 0.85)], depth: [2.5, 4])),
        ],
        sizes: ["fox": 0.3, "bear": 0.5, "duck": 0.12, "bird": 0.1, "flower": 0.2, "bee": 0.06, "woodpecker": 0.12])
}

func testWorld() -> StageWorld {
    StageWorld(space: testSpace(), aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1000, height: 750))
}

@Suite struct StageWorldTests {
    @Test func projectsAndComesBack() {
        let w = testWorld()
        let g = w.groundPoint(.init(0.3, 0.25))
        let p = w.project(g.onGround)
        #expect(abs(p.u - 0.3) < 1e-12 && abs(p.v - 0.25) < 1e-12)
        #expect(abs(g.z - 2) < 1e-12)
        // A sticker 0.3 tall at depth 2 is drawn 0.15 of 750 points tall.
        #expect(abs(w.drawnHeight(size: 0.3, atDepth: 2) - 112.5) < 1e-9)
    }

    @Test func standsOnLandOrInItsWater() {
        let w = testWorld()
        let pond = w.groundPoint(.init(0.55, 0.25)), meadow = w.groundPoint(.init(0.55, 0.12))
        let roots = w.groundPoint(.init(0.1, 0.25)), sky = w.groundPoint(.init(0.5, 0.45))
        #expect(!w.canStand(at: pond, belongsIn: []) && w.canStand(at: pond, belongsIn: ["pond"]))
        #expect(w.canStand(at: meadow, belongsIn: []))
        #expect(!w.canStand(at: roots, belongsIn: []))
        #expect(!w.canStand(at: sky, belongsIn: []))  // past the meadow
        let shore = try! #require(w.nearestStand(to: pond, belongsIn: []))
        #expect(w.canStand(at: shore, belongsIn: []) && shore.distance(to: pond) < 0.6)
        #expect(w.perches.count == 2 && w.perches.allSatisfy { $0.depth == 2 } && w.airs.count == 1)
    }

    @Test func floatsAtItsWaterlineOnlyInItsWater() {
        let w = testWorld()
        let swim = [StageMove(id: "swim", cycle: 0.8, stride: 0.5, on: ["pond"], waterline: 0.25, facing: .right)]
        let middle = w.groundPoint(.init(0.55, 0.25)).onGround
        #expect(abs(w.afloat(at: middle, moves: swim, ramp: 0.05) - 0.25) < 1e-9)
        // Nothing on land, up in the air, or for a way with no waterline.
        #expect(w.afloat(at: w.groundPoint(.init(0.55, 0.12)).onGround, moves: swim, ramp: 0.05) == 0)
        #expect(w.afloat(at: middle + Vec3(0, 0.2, 0), moves: swim, ramp: 0.05) == 0)
        #expect(w.afloat(at: middle, moves: [StageMove(id: "swim", cycle: 0.8, stride: 0.5, on: ["pond"])], ramp: 0.05) == 0)
        // Sinking in from the edge: shallower near it.
        let edge = w.groundPoint(.init(0.55, 0.2)), inside = edge + (middle.ground - edge) * 0.02
        let near = w.afloat(at: inside.onGround, moves: swim, ramp: 1)
        #expect(near > 0 && near < 0.25)
    }

    @Test func nobodyFloatsInShallowWater() {
        var space = testSpace()
        space.places["pond"]?.shallow = true
        let w = StageWorld(space: space, aspect: 4.0 / 3, wide: false, frame: StageSize(width: 1024, height: 768))
        let swim = [StageMove(id: "swim", cycle: 0.8, stride: 0.5, on: ["pond"], waterline: 0.25, facing: .right)]
        let middle = w.groundPoint(.init(0.55, 0.25)).onGround
        #expect(w.afloat(at: middle, moves: swim, ramp: 0.05) == 0)
        #expect(w.canStand(at: middle.ground, belongsIn: ["pond"]) && !w.canStand(at: middle.ground, belongsIn: []))
    }

    @Test func aStraightWayCrossesAPondsSharpCorner() {
        // A sliver of water a centimetre deep: samples a few apart step over it.
        let corner = GroundPolygon([Vec2(0, 0), Vec2(1, 0), Vec2(0.5, 0.01)])
        #expect(corner.crosses(from: Vec2(0.5, -0.5), to: Vec2(0.5, 0.5)))
        #expect(!corner.crosses(from: Vec2(-1, 0.5), to: Vec2(2, 0.5)))
        // Along an edge, or ending on it, is not crossing.
        #expect(!corner.crosses(from: Vec2(0, 0), to: Vec2(1, 0)))
        #expect(!corner.crosses(from: Vec2(0.5, -1), to: Vec2(0.5, 0)))
        // Lying wholly in it is.
        let pond = GroundPolygon([Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)])
        #expect(pond.crosses(from: Vec2(0.2, 0.5), to: Vec2(0.8, 0.5)))
    }

    @Test func walkersGoRoundThePond() {
        let w = testWorld()
        let a = w.groundPoint(.init(0.3, 0.25)), b = w.groundPoint(.init(0.8, 0.25))
        let path = GroundPaths.path(
            from: a, to: b, walkable: { w.canStand(at: $0, belongsIn: []) },
            bounds: (Vec2(-4, 1), Vec2(4, 6)))
        #expect(path.count > 2)
        #expect(path.first == a && path.last == b)
        // Nowhere along it in the water.
        for (p, q) in zip(path, path.dropFirst()) {
            for i in 0...20 { #expect(w.water(at: p + (q - p) * (Double(i) / 20)) == nil) }
        }
        // A swimmer goes straight across.
        #expect(GroundPaths.path(from: a, to: b, walkable: { w.canStand(at: $0, belongsIn: ["pond"]) },
                                 bounds: (Vec2(-4, 1), Vec2(4, 6))).count == 2)
    }
}
