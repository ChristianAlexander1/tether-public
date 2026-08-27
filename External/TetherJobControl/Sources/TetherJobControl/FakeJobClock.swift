import Foundation

public protocol JobClock: AnyObject {
    func schedule(afterMillis: Int, _ work: @escaping () -> Void) -> JobClockToken
}

public protocol JobClockToken: AnyObject {
    func cancel()
}

public final class FakeJobClock: JobClock {
    public init() {}

    private var time: Int = 0
    private var entries: [(id: Int, fireAt: Int, work: () -> Void, token: FakeClockToken)] = []
    private var nextId: Int = 0

    private final class FakeClockToken: JobClockToken {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    public func advance(millis: Int) {
        time += max(0, millis)
        fireDue()
    }

    public func now() -> Int {
        return time
    }

    public func schedule(afterMillis: Int, _ work: @escaping () -> Void) -> JobClockToken {
        let token = FakeClockToken()
        let id = nextId
        nextId += 1
        entries.append((id: id, fireAt: time + max(0, afterMillis), work: work, token: token))
        return token
    }

    private func fireDue() {
        var fired = true
        while fired {
            fired = false
            // Find due and non-cancelled entries
            let dueIndices = entries.enumerated().compactMap { idx, entry in
                (!entry.token.cancelled && entry.fireAt <= time) ? idx : nil
            }
            // Execute in order of fireAt then id (already in array order, but sort explicitly)
            let dueEntries = dueIndices.map { entries[$0] }.sorted { a, b in
                if a.fireAt != b.fireAt { return a.fireAt < b.fireAt }
                return a.id < b.id
            }
            for entry in dueEntries {
                if entry.token.cancelled || entry.fireAt > time { continue }
                entry.token.cancel()
                entry.work()
                fired = true
            }
            // Remove executed and cancelled
            entries.removeAll { $0.token.cancelled || $0.fireAt <= time }
        }
    }
}
