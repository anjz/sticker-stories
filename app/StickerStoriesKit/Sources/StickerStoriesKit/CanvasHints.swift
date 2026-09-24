import Foundation

/// A gesture the canvas can teach with a short demo when a child has never
/// used it: pinching a sticker (to scale or turn it) and the layer button
/// (to send it behind the scenery).
public enum CanvasHint: String, CaseIterable, Sendable {
    case pinch
    case layer
}

/// Remembers, app-wide and on this device only, which gestures the child
/// has ever used. Local UI state like the recent stories — never sent
/// anywhere (docs/compliance.md).
public protocol HintProgressStore: Sendable {
    func usedHints() -> Set<CanvasHint>
    func markUsed(_ hint: CanvasHint)
}

/// When to show the canvas's hints: after `idleDelay` seconds with no
/// touch, each gesture the child has never used, in `CanvasHint` order,
/// at most once per visit to a story. A demo that starts plays to its end
/// whatever the child does; the next one waits for another idle spell.
/// Pure — the scene tells it how long it has been idle — so it is
/// unit-tested.
public struct CanvasHintSchedule: Sendable {
    public static let idleDelay: TimeInterval = 10

    public private(set) var used: Set<CanvasHint>
    public private(set) var shown: Set<CanvasHint> = []
    public var idleDelay: TimeInterval

    public init(used: Set<CanvasHint>, idleDelay: TimeInterval = Self.idleDelay) {
        self.used = used
        self.idleDelay = idleDelay
    }

    /// The hints to play now, in order, or none; those returned count as
    /// shown for this visit.
    public mutating func due(idleFor seconds: TimeInterval) -> [CanvasHint] {
        guard seconds >= idleDelay else { return [] }
        let hints = CanvasHint.allCases.filter { !used.contains($0) && !shown.contains($0) }
        shown.formUnion(hints)
        return hints
    }

    /// Hints that were due but did not get to play (the child started
    /// playing during the one before): offered again after the next idle
    /// spell.
    public mutating func postpone(_ hints: [CanvasHint]) {
        shown.subtract(hints)
    }

    /// The child used the gesture: its hint never shows again.
    public mutating func markUsed(_ hint: CanvasHint) {
        used.insert(hint)
    }

    /// Whether anything could still be shown this visit.
    public var hasPending: Bool {
        CanvasHint.allCases.contains { !used.contains($0) && !shown.contains($0) }
    }
}

/// Where a hint's sample sticker goes. Each candidate spot comes with how
/// much of a sticker there would be covered by the scene's foreground art
/// (0…1) and how clear it is of the stickers already placed (in sticker
/// sizes; negative = overlapping). The pinch demo wants open ground; the
/// layer demo wants the sticker half over the foreground art, so going
/// behind it shows.
public enum HintPlacement {
    public struct Candidate: Equatable, Sendable {
        public var coverage: Double
        public var clearance: Double
        /// 0 at the middle of the view, 1 at its edge.
        public var offCentre: Double

        public init(coverage: Double, clearance: Double, offCentre: Double) {
            self.coverage = coverage
            self.clearance = clearance
            self.offCentre = offCentre
        }
    }

    /// The index of the best candidate for `hint`, or nil when there are
    /// none. Free spots always beat crowded ones.
    public static func best(_ candidates: [Candidate], for hint: CanvasHint) -> Int? {
        func score(_ c: Candidate) -> Double {
            let fit: Double
            switch hint {
            case .pinch: fit = -c.coverage * 4 - c.offCentre
            case .layer: fit = -abs(c.coverage - 0.45) * 4 - c.offCentre * 0.5
            }
            return (c.clearance >= 0 ? 10 : 0) + fit
        }
        return candidates.indices.max { score(candidates[$0]) < score(candidates[$1]) }
    }
}
