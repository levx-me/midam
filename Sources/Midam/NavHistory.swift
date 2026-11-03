/// Back and forward through the places read, as in a browser. The caller passes where the
/// reader is now; the history keeps the places left behind on one side and, after going back,
/// the places to return to on the other. Consecutive duplicates merge.
struct NavHistory<Place: Equatable> {
    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Leaving `here` for somewhere new: it becomes the way back, and the way forward is gone.
    mutating func leave(_ here: Place) {
        if back.last != here { back.append(here) }
        forward.removeAll()
    }

    /// The place to go back to from `here`, which becomes the way forward; nil with nowhere to go.
    mutating func goBack(from here: Place) -> Place? {
        guard let to = back.popLast() else { return nil }
        if forward.last != here { forward.append(here) }
        return to
    }

    /// The place to go forward to from `here`, which becomes the way back; nil with nowhere to go.
    mutating func goForward(from here: Place) -> Place? {
        guard let to = forward.popLast() else { return nil }
        if back.last != here { back.append(here) }
        return to
    }
}
