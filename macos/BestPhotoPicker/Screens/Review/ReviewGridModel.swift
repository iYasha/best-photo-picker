import Foundation

// MARK: - Review grid model
//
// Pure, view-agnostic derivation of what the Review grid shows: the per-mark
// counts (for the filter chips, issue 6) and, per burst, the visible frames
// after the active `MarkFilter`, sorted best → worst. Keeping this off the view
// lets issue 6 (chips) and the grid share the exact same counts/visibility, and
// makes the fixed-sort rule testable.
//
// **Fixed sort (not user-sortable):** keeper first, then descending sharpness.
// Enforced here even though the fixture is pre-sorted (issue 3 acceptance).

/// Per-mark frame counts across the whole result (for the filter-chip badges).
struct MarkCounts {
    var all = 0
    var keeper = 0
    var maybe = 0
    var rejected = 0

    init(result: ScoreResult?) {
        guard let result else { return }
        for burst in result.bursts {
            for frame in burst.frames {
                all += 1
                switch frame.mark {
                case .keeper: keeper += 1
                case .maybe: maybe += 1
                case .rejected: rejected += 1
                }
            }
        }
    }
}

extension ScoreBurst {
    /// Frames to show for `filter`, sorted best → worst (keeper first, then by
    /// descending sharpness). Empty when nothing in the burst matches the filter.
    func visibleFrames(filter: MarkFilter) -> [ScoreFrame] {
        let kept = filter.mark.map { mark in frames.filter { $0.mark == mark } } ?? frames
        return kept.sorted { a, b in
            let ak = a.mark == .keeper
            let bk = b.mark == .keeper
            if ak != bk { return ak } // keeper first
            return a.sharpness > b.sharpness // then sharpest first
        }
    }
}
