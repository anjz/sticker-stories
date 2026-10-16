import Testing

@testable import StickerStoriesKit

@Suite struct SnowSceneryTests {
    /// A box with a sheer side, standing on the plane's bottom edge, its
    /// top at row 20.
    func box() -> BytePlane {
        var values = [UInt8](repeating: 0, count: 100 * 60)
        for y in 20..<60 { for x in 30..<70 { values[y * 100 + x] = 255 } }
        return BytePlane(width: 100, height: 60, values: values)
    }

    @Test func capsSitOnTopEdgesOnly() {
        let caps = SnowScenery.caps(of: box(), thickness: 6)
        #expect(caps.earliness(50, 20) > 0.3)  // the top edge, first
        #expect(caps.earliness(50, 21) > 0 && caps.earliness(50, 21) <= caps.earliness(50, 20))
        #expect(caps.earliness(50, 30) == 0)  // deep inside: no snow
        #expect(caps.earliness(50, 10) == 0)  // in the air above
        #expect(caps.earliness(69, 40) == 0)  // down the sheer side
        #expect(caps.opacity(50, 20) > 0.9)
    }

    @Test func noCapWhereAShapeRunsOutOfTheTop() {
        var values = [UInt8](repeating: 0, count: 20 * 20)
        for y in 0..<20 { for x in 5..<15 { values[y * 20 + x] = 255 } }
        let caps = SnowScenery.caps(of: BytePlane(width: 20, height: 20, values: values), thickness: 4)
        #expect(caps.pixels.enumerated().allSatisfy { $0.offset % 4 != 0 || $0.element == 0 })
    }

    func space() -> SceneSpace {
        SceneSpace(
            horizon: 0.6, ground: 0, back: 4, stand: .init(near: 1.1, far: 3.8), floor: 0.05,
            layers: [.init(id: "front", depth: 1)],
            places: ["pond": .init(ground: [.init(0.4, 0.1), .init(0.6, 0.1), .init(0.6, 0.2), .init(0.4, 0.2)], water: true)],
            sizes: [:])
    }

    /// The top 30 % open sky.
    func sky() -> BytePlane {
        BytePlane(width: 40, height: 30, values: (0..<1200).map { $0 / 40 < 9 ? 255 : 0 })
    }

    @Test func groundSnowCoversTheGroundButNotWaterOrSky() {
        let (field, flakes) = SnowScenery.ground(
            width: 200, height: 150, frame: (0, 1), aspect: 4.0 / 3, space: space(), sky: sky())
        // Ground near and far (its far edge is at 0.6 - 0.6 / 4 = 0.45).
        #expect(field.earliness(20, 140) > 0)
        #expect(field.earliness(20, 150 - 60) > 0)  // art y 0.4
        // The pond, the backdrop past the far edge, the sky.
        #expect(field.earliness(100, 150 - 22) == 0)  // art y ≈ 0.15
        #expect(field.earliness(20, 150 - 75) == 0)  // art y 0.5, the backdrop
        #expect(field.earliness(20, 10) == 0)
        // A cap where the scenery meets the sky (row 45 is its first).
        #expect(field.earliness(20, 45) > 0)
        // Flakes only on the ground, smaller further away.
        #expect(!flakes.isEmpty)
        #expect(flakes.allSatisfy { $0.y <= 0.45 && !($0.x > 0.4 && $0.x < 0.6 && $0.y > 0.1 && $0.y < 0.2) })
        let near = flakes.filter { $0.y < 0.1 }.map(\.size), far = flakes.filter { $0.y > 0.4 }.map(\.size)
        #expect(near.max()! > far.max()!)
    }

    @Test func withoutASpaceTheGroundIsWhatIsNotSky() {
        let (field, _) = SnowScenery.ground(
            width: 200, height: 150, frame: (0, 1), aspect: 4.0 / 3, space: nil, sky: sky())
        #expect(field.earliness(100, 100) > 0)
        #expect(field.earliness(100, 10) == 0)
    }

    @Test func coverRevealsByEarlinessAlone() {
        // The snow is a pure function of the cover: a pixel shows from
        // 1 - earliness on, so at a full cover the whole ground does.
        let (field, _) = SnowScenery.ground(
            width: 120, height: 90, frame: (0, 1), aspect: 4.0 / 3, space: space(), sky: sky())
        let ground = (0..<90).flatMap { y in (0..<120).map { field.earliness($0, y) } }.filter { $0 > 0 }
        #expect(ground.allSatisfy { $0 >= 0.1 })
    }
}
