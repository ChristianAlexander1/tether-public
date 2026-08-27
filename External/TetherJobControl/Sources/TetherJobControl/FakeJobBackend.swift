import Foundation

public final class FakeJobBackend: JobBackend {
    public init() {}

    private var deliverableSignals: [JobID: Set<JobSignal>] = [:]
    public private(set) var deliveries: [(JobSignal, JobID)] = []
    public private(set) var forceTerminated: [JobID] = []

    public func setDeliverable(_ signals: Set<JobSignal>, for job: JobID) {
        var current = deliverableSignals[job] ?? Set<JobSignal>()
        current.formUnion(signals)
        deliverableSignals[job] = current
    }

    public func deliver(_ signal: JobSignal, to job: JobID) -> Bool {
        deliveries.append((signal, job))
        let set = deliverableSignals[job] ?? Set<JobSignal>()
        return set.contains(signal)
    }

    public func forceTerminate(_ job: JobID) {
        forceTerminated.append(job)
    }
}
