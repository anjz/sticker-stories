import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct StoryCameraTests {
    let world = 0.0...1600.0

    @Test func staysPutWhenTheFocusIsInView() {
        let focus = [StoryCamera.Focus(minX: 300, maxX: 500, since: 1)]
        #expect(StoryCamera.target(center: 400, view: 600, world: world, focus: focus, margin: 40) == 400)
    }

    @Test func movesOnlyAsFarAsItMust() {
        // The woodpecker on the oak's trunk, off the window's left side.
        let focus = [StoryCamera.Focus(minX: 60, maxX: 200, since: 3)]
        let x = StoryCamera.target(center: 800, view: 600, world: world, focus: focus, margin: 40)
        #expect(x == 60 - 40 + 300)
        // Never past the art's edge.
        let edge = [StoryCamera.Focus(minX: 0, maxX: 80, since: 3)]
        #expect(StoryCamera.target(center: 800, view: 600, world: world, focus: edge, margin: 40) == 300)
    }

    @Test func takesInEveryoneThatFits() {
        let focus = [
            StoryCamera.Focus(minX: 900, maxX: 1000, since: 1),
            StoryCamera.Focus(minX: 1200, maxX: 1300, since: 2),
        ]
        let x = StoryCamera.target(center: 400, view: 600, world: world, focus: focus, margin: 40)
        #expect(x - 300 <= 900 - 40 && x + 300 >= 1300 + 40)
    }

    @Test func goesWithTheLatestWhenNotAllFit() {
        let focus = [
            StoryCamera.Focus(minX: 100, maxX: 200, since: 5),
            StoryCamera.Focus(minX: 1300, maxX: 1400, since: 2),
        ]
        let x = StoryCamera.target(center: 1100, view: 600, world: world, focus: focus, margin: 40)
        #expect(x - 300 <= 100 && x + 300 >= 200)
    }

    @Test func whatIsPlayingKeepsTheCamera() {
        // Nico rides the wave far right; the seal comes in and claps far
        // left meanwhile: the ride keeps the camera till it is over.
        let seal = StoryCamera.Focus(minX: 100, maxX: 200, since: 9, playing: true)
        let ride = StoryCamera.Focus(minX: 1300, maxX: 1400, since: 8, playing: true)
        let x = StoryCamera.target(center: 1100, view: 600, world: world, focus: [seal, ride], margin: 40)
        #expect(x - 300 <= 1300 && x + 300 >= 1400)
        // Coming in is not playing: the ride keeps it over that too.
        var coming = seal
        coming.playing = false
        coming.since = 12
        let y = StoryCamera.target(center: 1100, view: 600, world: world, focus: [coming, ride], margin: 40)
        #expect(y - 300 <= 1300 && y + 300 >= 1400)
        // An action or an effect plays from its start to its end; a face
        // does not hold it.
        let beats = StoryCamera.beats(
            live: [LiveAnimationTrigger(at: 8, stickerID: "surfer", animationID: "ride")], duration: { _ in 4 },
            faces: [ExpressionTrigger(at: 8, stickerID: "seal", expression: "happy")], effects: [])
        #expect(beats.first { $0.stickerID == "surfer" }?.playing(at: 10) == true)
        #expect(beats.first { $0.stickerID == "surfer" }?.playing(at: 12.5) == false)
        #expect(beats.first { $0.stickerID == "seal" }?.playing(at: 8.5) == false)
    }

    @Test func keepsTheRestOfTheCastWholeWhenItCan() {
        // Nico waits out at sea while the turtle swims: the turtle first,
        // and Nico in view too when both fit.
        let turtle = [StoryCamera.Focus(minX: 700, maxX: 800, since: 5)]
        let nico = StoryCamera.Focus(minX: 420, maxX: 500, since: 0)
        let x = StoryCamera.target(center: 750, view: 600, world: world, focus: turtle, cast: [nico], margin: 40)
        #expect(x - 300 <= 420 - 40 && x + 300 >= 800 + 40)
        // One that does not fit is left wholly out, never cut by the edge.
        let pelican = StoryCamera.Focus(minX: 1060, maxX: 1180, since: 0)
        let far = StoryCamera.Focus(minX: 120, maxX: 200, since: 0)
        let y = StoryCamera.target(center: 800, view: 600, world: world, focus: turtle, cast: [pelican, far], margin: 40)
        #expect(y - 300 <= 700 - 40 && y + 300 >= 800 + 40)
        for f in [pelican, far] {
            let whollyIn = f.minX >= y - 300 && f.maxX <= y + 300
            let whollyOut = f.maxX <= y - 300 || f.minX >= y + 300
            #expect(whollyIn || whollyOut, "\(f) at \(y)")
        }
    }

    @Test func aBeatCutByTheEdgeGoesWhollyOut() {
        // The latest beat wins; an earlier one it cannot take in is not
        // left half on screen.
        let focus = [
            StoryCamera.Focus(minX: 700, maxX: 800, since: 5),
            StoryCamera.Focus(minX: 300, maxX: 420, since: 2),
        ]
        let x = StoryCamera.target(center: 650, view: 400, world: world, focus: focus, margin: 40)
        #expect(x - 200 <= 700 - 40 && x + 200 >= 800 + 40)
        #expect(420 <= x - 200 || 300 >= x - 200)
    }

    @Test func aWindowAsWideAsTheArtNeverMoves() {
        let focus = [StoryCamera.Focus(minX: 0, maxX: 100, since: 1)]
        #expect(StoryCamera.target(center: 800, view: 1600, world: world, focus: focus, margin: 40) == 800)
    }

    @Test func glidesAtAPaceAChildCanFollow() {
        var x = 300.0
        var frames = 0
        while x != 1300, frames < 600 {
            let next = StoryCamera.step(center: x, toward: 1300, dt: 1.0 / 60, view: 600)
            #expect(next - x <= StoryCamera.topSpeed * 600 / 60 + 1e-9)
            #expect(next >= x)
            x = next
            frames += 1
        }
        // There within a few seconds, and never past it.
        #expect(frames < 300)
        #expect(x == 1300)
    }

    @Test func followsTheStorysCuesFromAMomentBefore() {
        let beats = StoryCamera.beats(
            live: [LiveAnimationTrigger(at: 4, stickerID: "woodpecker", animationID: "drum")],
            duration: { _ in 3 },
            faces: [
                ExpressionTrigger(at: 9, stickerID: "fox", expression: "happy"),
                ExpressionTrigger(at: 12, stickerID: "fox", expression: ExpressionTrigger.normal),
            ],
            effects: [])
        #expect(beats.map(\.stickerID) == ["woodpecker", "fox"])
        #expect(StoryCamera.current(beats, at: 3.5).map(\.stickerID) == ["woodpecker"])
        #expect(StoryCamera.current(beats, at: 7.5).map(\.stickerID) == ["woodpecker"])
        #expect(StoryCamera.current(beats, at: 8.5).map(\.stickerID) == ["fox"])
        #expect(StoryCamera.current(beats, at: 12.5).isEmpty)
    }
}
