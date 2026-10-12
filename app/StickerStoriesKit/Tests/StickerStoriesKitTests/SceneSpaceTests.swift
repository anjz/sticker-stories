import CoreGraphics
import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct SceneSpaceTests {
    func space() -> SceneSpace {
        SceneSpace(
            horizon: 0.5, ground: 0, back: 7, stand: .init(near: 1.1, far: 6), floor: 0.05,
            layers: [.init(id: "trees", art: "trees", depth: 2), .init(id: "front", depth: 1)],
            places: [
                "meadow": .init(ground: [.init(0.1, 0.1), .init(0.9, 0.1), .init(0.5, 0.4)]),
                "branch": .init(lines: [.init(layer: "trees", points: [.init(0.1, 0.8), .init(0.2, 0.85)], facing: .left)]),
            ],
            sizes: ["fox": 0.3, "mushroom": 0.2])
    }

    func manifest() -> PackManifest {
        var manifest = makeValidManifest()
        manifest.layers = [SceneLayer(id: "trees", image: "art/layer-trees.png")]
        manifest.features = [
            "meadow": SceneFeature(description: "The meadow.", areas: [.init(x: [0.1, 0.9], y: [0.2, 0.4])]),
            "branch": SceneFeature(description: "A branch.", areas: [.init(x: [0.1, 0.2], y: [0.8, 0.9])]),
        ]
        manifest.space = space()
        return manifest
    }

    @Test func depthAndDrawnHeight() {
        let s = space()
        #expect(abs(s.groundDepth(atArtY: 0) - 1) < 1e-12)
        #expect(abs(s.groundDepth(atArtY: 0.25) - 2) < 1e-12)
        #expect(abs(s.groundArtY(atDepth: 2) - 0.25) < 1e-12)
        #expect(abs(s.drawnHeight(size: 0.3, atDepth: 2) - 0.15) < 1e-12)
        #expect(abs(s.drawnHeight(size: 0.08, atDepth: 4) - 0.05) < 1e-12)  // the floor
        #expect(abs(s.drawnHeight(size: 0.03, atDepth: 4) - 0.03) < 1e-12)  // never above its own size
    }

    @Test func roundTripsAndValidates() throws {
        let manifest = manifest()
        let dir = try materialize(manifest)
        #expect(manifest.validationIssues(packDirectory: dir).isEmpty)
        let data = try JSONEncoder().encode(manifest)
        #expect(String(decoding: data, as: UTF8.self).contains("[0.1,0.8]"))  // points are [u, v]
        let decoded = try JSONDecoder().decode(PackManifest.self, from: data)
        #expect(decoded.space == manifest.space)
        #expect(decoded.layers == manifest.layers)
        #expect(makeValidManifest().space == nil && makeValidManifest().layers.isEmpty)
    }

    @Test(arguments: [
        "not a feature", "not below the horizon", "show all of trees", "not one of the pack's",
        "nothing puts trees", "has no size", "not one of the space", "exactly one of", "id must be",
        "imageWide is needed",
    ])
    func flagsProblems(_ want: String) throws {
        var manifest = manifest()
        switch want {
        case "not a feature":
            manifest.space?.places["sky"] = .init(air: .init(area: [.init(0, 0.6), .init(1, 0.6), .init(0.5, 0.9)], depth: [2, 5]))
        case "not below the horizon":
            manifest.space?.places["meadow"] = .init(ground: [.init(0.1, 0.6), .init(0.9, 0.6), .init(0.5, 0.8)])
        case "show all of trees":
            manifest.space?.layers.append(.init(id: "more", art: "trees", depth: 3))
        case "not one of the pack's":
            manifest.space?.layers[0].art = "rocks"
        case "nothing puts trees":
            manifest.space?.layers.removeFirst()
            manifest.space?.places["branch"] = nil
        case "has no size":
            manifest.space?.sizes["fox"] = nil
        case "not one of the space":
            manifest.space?.places["branch"]?.lines?[0].layer = "bush"
        case "exactly one of":
            manifest.space?.places["meadow"] = .init()
        case "id must be":
            manifest.layers.append(SceneLayer(id: "foreground", image: "art/layer-trees.png"))
        default:
            manifest.backgroundWide = "art/background-wide.png"
            manifest.foregroundWide = "art/foreground-wide.png"
        }
        let dir = try materialize(manifest)
        let issues = manifest.validationIssues(packDirectory: dir)
        #expect(issues.contains { $0.contains(want) }, "\(issues)")
    }

    @Test func pointsAreTwoNumbers() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([SceneSpace.Point].self, from: Data("[[0.1, 0.2, 0.3]]".utf8))
        }
    }
}

@Suite struct EditSizeAndBoundsTests {
    @Test func editSizeIsHalfwayAndPinchesFromBackToFront() throws {
        let space = SceneSpace(
            horizon: 0.5, ground: 0, back: 5, stand: .init(near: 1, far: 4), floor: 0.05,
            layers: [.init(id: "front", depth: 1)], sizes: ["fox": 0.4, "bee": 0.08])
        let fox = try #require(space.editSize(of: "fox"))
        #expect(abs(fox.height - 0.25) < 1e-12)  // (0.4 + 0.1) / 2
        #expect(abs(fox.scales.lowerBound - 0.4) < 1e-12 && abs(fox.scales.upperBound - 1.6) < 1e-12)
        // The floor holds a tiny one up at the back: it barely pinches.
        let bee = try #require(space.editSize(of: "bee"))
        #expect(abs(bee.height - 0.065) < 1e-12)
        #expect(bee.scales.upperBound / bee.scales.lowerBound < 1.7)
        #expect(space.editSize(of: "owl") == nil)
    }

    /// An image with a painted block in its lower left: the box comes back
    /// in fractions, origin bottom-left.
    @Test func opaqueBoundsAreBottomLeftFractions() throws {
        let context = try #require(CGContext(
            data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 0, width: 20, height: 30))  // user space: y up from the bottom
        let image = try #require(context.makeImage())
        let box = try #require(OpaqueBounds.of(image))
        #expect(abs(box.minX - 0.1) < 0.02 && abs(box.width - 0.2) < 0.02)
        #expect(abs(box.minY - 0) < 0.02 && abs(box.height - 0.6) < 0.02)
        let empty = try #require(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        #expect(OpaqueBounds.of(empty) == nil)
    }
}

@Suite struct StageDepthTests {
    let space = SceneSpace(
        horizon: 0.5, ground: 0, back: 5, stand: .init(near: 1.1, far: 4),
        layers: [.init(id: "oak", art: "trees", depth: 2), .init(id: "front", depth: 1)],
        sizes: [:])

    @Test func groundAndPlanes() {
        #expect(space.isGround(artY: 0.35) && !space.isGround(artY: 0.45))  // 0.45 is at depth 10, past the back
        #expect(space.planeDepth("trees") == 2 && space.planeDepth("foreground") == 1)
    }
}
