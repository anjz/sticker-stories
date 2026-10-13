import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct IdleLifeTests {
    let frames: (LiveAnimationKey) -> LiveFrames? = { key in
        switch key.animationID {
        case "look-around": LiveFrames(holds: [0.5, 1, 1])  // 2.5 s
        case "sniff": LiveFrames(holds: [0.5, 1])  // 1.5 s
        case "sleep": LiveFrames(holds: [0.5, 1, 1, 0.5], pause: 2)
        default: LiveFrames(holds: [1, 1])
        }
    }
    let fox = [IdleLife.Action(id: "look-around", duration: 2.5), IdleLife.Action(id: "sniff", duration: 1.5)]

    /// Now and then, never two at once, never twice the same in a row,
    /// and only in the story's time.
    @Test func nowAndThen() {
        var random = SeededGenerator(state: 3)
        let out = IdleLife.triggers(
            actions: ["fox": fox], story: [], frames: frames, busy: { _, _ in false }, from: 1.2, to: 90, random: &random)
        #expect(out.count >= 4)
        for (a, b) in zip(out, out.dropFirst()) {
            #expect(b.at - a.at >= IdleLife.every.lowerBound)
            #expect(a.animationID != b.animationID)
        }
        #expect(out.allSatisfy { $0.at > 1.2 && $0.at < 90 && $0.mode == .whole })
    }

    /// The story comes first: nothing while it plays an action on the
    /// sticker or holds one, nothing just before a cue, nothing while busy.
    @Test func theStoryComesFirst() {
        var random = SeededGenerator(state: 5)
        let story = [
            LiveAnimationTrigger(at: 10, stickerID: "fox", animationID: "jump"),
            LiveAnimationTrigger(at: 30, stickerID: "fox", animationID: "sleep", mode: .hold),
            LiveAnimationTrigger(at: 60, stickerID: "fox", animationID: "sleep", mode: .resume),
        ]
        let out = IdleLife.triggers(
            actions: ["fox": fox], story: story, frames: frames, busy: { _, t in t > 70 && t < 80 }, from: 1.2, to: 120,
            random: &random)
        #expect(!out.isEmpty)
        for idle in out {
            let end = idle.at + (idle.animationID == "sniff" ? 1.5 : 2.5)
            #expect(end < 9.2 || idle.at > 12.8)  // the jump, with room
            #expect(end < 29.2 || idle.at > 61)  // held asleep until resumed
            #expect(end < 69.2 || idle.at > 80.8)  // busy
        }
    }
}
