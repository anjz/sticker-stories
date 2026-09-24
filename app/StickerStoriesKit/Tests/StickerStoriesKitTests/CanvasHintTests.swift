import Foundation
import Testing

@testable import StickerStoriesKit

@Suite struct CanvasHintScheduleTests {
    @Test func waitsForTheIdleDelay() {
        var schedule = CanvasHintSchedule(used: [])
        #expect(schedule.due(idleFor: 9.9).isEmpty)
        #expect(schedule.due(idleFor: 10) == [.pinch, .layer])
    }

    @Test func showsOnlyWhatWasNeverUsed() {
        var schedule = CanvasHintSchedule(used: [.pinch])
        #expect(schedule.due(idleFor: 12) == [.layer])
        var none = CanvasHintSchedule(used: [.pinch, .layer])
        #expect(none.due(idleFor: 60).isEmpty)
        #expect(!none.hasPending)
    }

    @Test func eachHintOncePerVisit() {
        var schedule = CanvasHintSchedule(used: [])
        #expect(schedule.due(idleFor: 10) == [.pinch, .layer])
        #expect(schedule.due(idleFor: 30).isEmpty)
        #expect(!schedule.hasPending)
    }

    @Test func usingAGestureRetiresItsHint() {
        var schedule = CanvasHintSchedule(used: [])
        schedule.markUsed(.layer)
        #expect(schedule.due(idleFor: 10) == [.pinch])
    }
}

@Suite struct HintPlacementTests {
    @Test func pinchWantsOpenGroundLayerWantsHalfCover() {
        let spots = [
            HintPlacement.Candidate(coverage: 0.0, clearance: 1, offCentre: 0.2),
            HintPlacement.Candidate(coverage: 0.5, clearance: 1, offCentre: 0.6),
            HintPlacement.Candidate(coverage: 1.0, clearance: 1, offCentre: 0.9),
        ]
        #expect(HintPlacement.best(spots, for: .pinch) == 0)
        #expect(HintPlacement.best(spots, for: .layer) == 1)
    }

    @Test func freeSpotsBeatCrowdedOnes() {
        let spots = [
            HintPlacement.Candidate(coverage: 0.45, clearance: -0.5, offCentre: 0),
            HintPlacement.Candidate(coverage: 0.1, clearance: 0.2, offCentre: 0.8),
        ]
        #expect(HintPlacement.best(spots, for: .layer) == 1)
        #expect(HintPlacement.best([], for: .pinch) == nil)
    }
}
