// Scheduler: virtual time plus a priority queue of (time, sequence, action). The sequence
// number breaks ties, so the order of events is total and replays exactly from a seed.

struct Scheduler<Action> {
    private struct Entry {
        let time: UInt64
        let sequence: UInt64
        let action: Action

        func precedes(_ other: Entry) -> Bool {
            time != other.time ? time < other.time : sequence < other.sequence
        }
    }

    private var heap: [Entry] = []
    private var nextSequence: UInt64 = 0
    private(set) var now: UInt64 = 0

    var isEmpty: Bool { heap.isEmpty }

    mutating func schedule(_ action: Action, afterMillis delay: UInt64) {
        heap.append(Entry(time: now + delay, sequence: nextSequence, action: action))
        nextSequence += 1
        siftUp(heap.count - 1)
    }

    /// Removes the earliest action and advances virtual time to it.
    mutating func next() -> Action? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let entry = heap.removeLast()
        if !heap.isEmpty { siftDown(0) }
        now = entry.time
        return entry.action
    }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].precedes(heap[parent]) else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var first = parent
            if left < heap.count, heap[left].precedes(heap[first]) { first = left }
            if right < heap.count, heap[right].precedes(heap[first]) { first = right }
            guard first != parent else { return }
            heap.swapAt(parent, first)
            parent = first
        }
    }
}
