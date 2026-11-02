import Foundation

public enum PlaybackMode: String, Codable, CaseIterable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle
}

/// Ordered list of track IDs plus a cursor. In shuffle mode the order is a
/// shuffled deck that is rebuilt after each full cycle.
public struct PlaybackQueue {
    public private(set) var trackIDs: [UUID]
    public private(set) var mode: PlaybackMode

    private var index: Int
    private var shuffleOrder: [UUID] = []
    private var shuffleCursor = 0

    public init(trackIDs: [UUID], currentIndex: Int = 0, mode: PlaybackMode = .sequential) {
        self.trackIDs = trackIDs
        self.index = trackIDs.isEmpty ? 0 : min(max(currentIndex, 0), trackIDs.count - 1)
        self.mode = mode
        if mode == .shuffle {
            rebuildShuffleDeck(keepingCurrentLast: true)
        }
    }

    public var currentID: UUID? {
        trackIDs.indices.contains(index) ? trackIDs[index] : nil
    }

    @discardableResult
    public mutating func next() -> UUID? {
        guard !trackIDs.isEmpty else { return nil }
        switch mode {
        case .repeatOne:
            return currentID
        case .sequential, .repeatAll:
            if index + 1 < trackIDs.count {
                index += 1
                return trackIDs[index]
            }
            guard mode == .repeatAll else { return nil }
            index = 0
            return currentID
        case .shuffle:
            if shuffleCursor >= shuffleOrder.count {
                rebuildShuffleDeck(keepingCurrentLast: false)
            }
            let id = shuffleOrder[shuffleCursor]
            shuffleCursor += 1
            advanceIndex(to: id)
            return id
        }
    }

    @discardableResult
    public mutating func previous() -> UUID? {
        guard !trackIDs.isEmpty else { return nil }
        switch mode {
        case .repeatOne:
            return currentID
        case .sequential, .repeatAll:
            if index > 0 {
                index -= 1
                return trackIDs[index]
            }
            guard mode == .repeatAll else { return nil }
            index = trackIDs.count - 1
            return currentID
        case .shuffle:
            guard shuffleCursor >= 2 else { return nil }
            shuffleCursor -= 2
            let id = shuffleOrder[shuffleCursor]
            shuffleCursor += 1
            advanceIndex(to: id)
            return id
        }
    }

    public mutating func setMode(_ newMode: PlaybackMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .shuffle {
            rebuildShuffleDeck(keepingCurrentLast: true)
        } else {
            shuffleOrder = []
            shuffleCursor = 0
        }
    }

    public mutating func replace(with trackIDs: [UUID], startAt index: Int) {
        self.trackIDs = trackIDs
        self.index = trackIDs.isEmpty ? 0 : min(max(index, 0), trackIDs.count - 1)
        if mode == .shuffle {
            rebuildShuffleDeck(keepingCurrentLast: true)
        }
    }

    private mutating func advanceIndex(to id: UUID) {
        if let position = trackIDs.firstIndex(of: id) {
            index = position
        }
    }

    /// Builds a fresh shuffled deck. The current track is moved to the end so
    /// the first `next()` after entering shuffle never repeats it immediately.
    private mutating func rebuildShuffleDeck(keepingCurrentLast: Bool) {
        var deck = trackIDs.shuffled()
        if keepingCurrentLast, deck.count > 1, let current = currentID,
           let position = deck.firstIndex(of: current) {
            deck.remove(at: position)
            deck.append(current)
        }
        shuffleOrder = deck
        shuffleCursor = 0
    }
}
