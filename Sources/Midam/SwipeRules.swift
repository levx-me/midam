import Foundation

// Whether a trackpad gesture is a swipe back or forward, the rule that needs no window.
// Checked by tools/SwipeTest.
enum SwipeRules {
    enum Verdict: Equatable { case undecided, swipe, scroll }

    /// Sideways travel that makes a swipe.
    static let distance = 15.0

    /// What a gesture is from how far the fingers have moved since it began: up or down by
    /// half the sideways distance or more is a scroll, so a diagonal one still scrolls;
    /// mostly sideways for `distance` is a swipe; less is not known yet. As in Safari.
    static func verdict(dx: Double, dy: Double) -> Verdict {
        if abs(dy) >= abs(dx) / 2 { return .scroll }
        return abs(dx) >= distance ? .swipe : .undecided
    }
}
