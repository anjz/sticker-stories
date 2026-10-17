import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct StoryCrowdTests {
    func members(_ kinds: [(String, Int)]) -> [StoryCrowd.Member] {
        kinds.flatMap { kind, count in
            (0..<count).map { k in StoryCrowd.Member(id: UUID(), stickerID: kind, scale: 1 + Double(k) * 0.1) }
        }
    }

    @Test func noneRestWithinTheLimit() {
        #expect(StoryCrowd.resting(members([("fox", 20)]), visitors: 5).isEmpty)
    }

    @Test func copiesRestFromTheMostCopiedSmallestFirst() {
        let placed = members([("fox", 12), ("owl", 8), ("bee", 4), ("frog", 1)])
        let resting = StoryCrowd.resting(placed, visitors: 2)
        // 25 + 2 visitors: 2 over, both foxes (the most copies), the smallest.
        let foxes = placed.filter { $0.stickerID == "fox" }.sorted { $0.scale < $1.scale }
        #expect(resting == Set(foxes.prefix(2).map(\.id)))
    }

    @Test func theLastOfAKindNeverRests() {
        let placed = members([("fox", 30), ("owl", 3)])
        let resting = StoryCrowd.resting(placed, visitors: 4)
        let left = placed.filter { !resting.contains($0.id) }
        #expect(left.count + 4 == StoryCrowd.limit)
        #expect(Set(left.map(\.stickerID)) == ["fox", "owl"])
    }

    @Test func oneOfEachIsAllThatCanBeLeft() {
        let placed = members([("fox", 3), ("owl", 3)])
        let resting = StoryCrowd.resting(placed, visitors: 0, limit: 1)
        #expect(resting.count == 4)
    }
}
