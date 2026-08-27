import Foundation

public final class JobTable {
    private let backend: JobBackend
    private let clock: JobClock

    private struct JobInfo {
        var spec: JobSpec
        var group: ProcessGroupID
        var state: JobState
        var queuedSignals: Set<JobSignal> = []
        var terminationChain: TerminationChain?
    }

    private struct TerminationChain {
        var killToken: JobClockToken?
        var orphanToken: JobClockToken?
    }

    private var jobs: [JobID: JobInfo] = [:]
    private var groups: [ProcessGroupID: Set<JobID>] = [:]
    private var nextJobId: Int32 = 1000

    public private(set) var foreground: ProcessGroupID?

    public var onOrphanDetected: ((JobID) -> Void)?
    public var onStateChange: ((JobID, JobState) -> Void)?
    public private(set) var diagnostics: [String] = []

    private var isInHandler = false

    public init(backend: JobBackend, clock: JobClock) {
        self.backend = backend
        self.clock = clock
    }

    // MARK: - Internal helpers

    private func addDiagnostic(_ message: String) {
        diagnostics.append(message)
    }

    private func fireOnStateChange(_ id: JobID, _ state: JobState) {
        if isInHandler {
            // Prevent recursive handler calls
            return
        }
        isInHandler = true
        onStateChange?(id, state)
        isInHandler = false
    }

    private func isBlockedByReentrancy() -> Bool {
        if isInHandler {
            addDiagnostic("reentrancy blocked: mutation attempted inside onStateChange handler")
            return true
        }
        return false
    }

    // MARK: - Registration

    @discardableResult
    public func register(_ spec: JobSpec) -> JobID {
        if isBlockedByReentrancy() {
            return JobID(raw: -1)
        }

        let id = JobID(raw: nextJobId)
        nextJobId += 1

        var group: ProcessGroupID
        if let specGroup = spec.group {
            group = specGroup
            if groups[group] == nil {
                groups[group] = Set()
                addDiagnostic("unknown group created: \(group.raw)")
            }
        } else {
            group = ProcessGroupID(raw: id.raw)
            groups[group] = Set()
        }

        groups[group, default: Set()].insert(id)

        var info = JobInfo(
            spec: spec,
            group: group,
            state: .spawning
        )
        jobs[id] = info

        if spec.isForegroundCandidate && foreground == nil {
            foreground = group
        }

        return id
    }

    public func markRunning(_ id: JobID) {
        if isBlockedByReentrancy() {
            return
        }
        guard var info = jobs[id] else { return }
        if info.state == .spawning {
            info.state = .running
            jobs[id] = info
            fireOnStateChange(id, .running)
        }
    }

    public func markExited(_ id: JobID, code: Int32?, signal: String?) {
        if isBlockedByReentrancy() {
            return
        }
        guard var info = jobs[id] else { return }
        if case .exited = info.state {
            return // Already exited, no-op
        }
        info.state = .exited(code: code, signal: signal)
        info.terminationChain?.killToken?.cancel()
        info.terminationChain?.orphanToken?.cancel()
        info.terminationChain = nil
        jobs[id] = info
        fireOnStateChange(id, .exited(code: code, signal: signal))
    }

    public func state(of id: JobID) -> JobState? {
        return jobs[id]?.state
    }

    public func jobs(in group: ProcessGroupID) -> [JobID] {
        let groupJobs = groups[group] ?? Set()
        return groupJobs.sorted { $0.raw < $1.raw }
    }

    public func setForeground(_ group: ProcessGroupID?) {
        if isBlockedByReentrancy() {
            return
        }
        foreground = group
    }

    // MARK: - Signal routing

    public enum Target {
        case job(JobID)
        case group(ProcessGroupID)
        case foreground
    }

    @discardableResult
    public func signal(_ sig: JobSignal, to target: Target) -> SignalOutcome {
        if isBlockedByReentrancy() {
            return SignalOutcome()
        }

        switch target {
        case .job(let id):
            return deliverToJob(id, sig: sig)
        case .group(let g):
            return deliverToGroup(g, sig: sig)
        case .foreground:
            guard let fg = foreground else {
                return SignalOutcome(noSuchTarget: true)
            }
            return deliverToGroup(fg, sig: sig)
        }
    }

    private func deliverToJob(_ id: JobID, sig: JobSignal) -> SignalOutcome {
        guard let info = jobs[id] else {
            return SignalOutcome(noSuchTarget: true)
        }

        if case .exited = info.state {
            return SignalOutcome(noSuchTarget: true)
        }

        return applySignalProcedure(sig: sig, to: id, jobInfo: info)
    }

    private func applySignalProcedure(sig: JobSignal, to id: JobID, jobInfo: JobInfo) -> SignalOutcome {
        guard var info = jobs[id] else {
            return SignalOutcome()
        }

        switch sig {
        case .cont:
            if info.state == .stopped {
                // Change state first
                info.state = .running
                jobs[id] = info
                fireOnStateChange(id, .running)

                // Deliver CONT to backend
                backend.deliver(.cont, to: id)

                // Deliver queued signals (disable queuing during queued delivery)
                let queued = info.queuedSignals
                info.queuedSignals.removeAll()
                jobs[id] = info

                var delivered: [JobID] = [id] // CONT delivered
                var failed: [JobID] = []

                for queuedSig in JobSignal.allCases {
                    if queued.contains(queuedSig) {
                        let result = applyQueuedSignal(queuedSig, to: id, jobInfo: info)
                        if var updatedInfo = jobs[id] {
                            info = updatedInfo
                        }
                        delivered.append(contentsOf: result.delivered)
                        failed.append(contentsOf: result.failed)
                    }
                }

                var allDelivered = [id] + delivered.filter { $0 != id }
                allDelivered.sort { $0.raw < $1.raw }
                var allFailed = failed.filter { $0 != id }
                allFailed.sort { $0.raw < $1.raw }
                return SignalOutcome(delivered: allDelivered, failed: allFailed)
            } else {
                // CONT to non-stopped job: deliver to backend, count as delivered
                backend.deliver(.cont, to: id)
                return SignalOutcome(delivered: [id], failed: [])
            }

        case .tstp:
            if info.state == .running {
                let backendResult = backend.deliver(.tstp, to: id)
                if backendResult {
                    info.state = .stopped
                    jobs[id] = info
                    fireOnStateChange(id, .stopped)
                    return SignalOutcome(delivered: [id], failed: [])
                } else {
                    return SignalOutcome(delivered: [], failed: [id])
                }
            } else if info.state == .stopped {
                // Queue it (not CONT, not KILL)
                info.queuedSignals.insert(.tstp)
                jobs[id] = info
                return SignalOutcome(delivered: [], failed: [])
            } else {
                // spawning or exited (exited handled before)
                backend.deliver(.tstp, to: id)
                // For spawning, no state change regardless of backend result
                return SignalOutcome(delivered: [id], failed: [])
            }

        case .kill, .term:
            let backendResult = backend.deliver(sig, to: id)
            if !backendResult {
                backend.forceTerminate(id)
            }
            return SignalOutcome(delivered: [id], failed: [])

        case .winch, .hup, .int, .quit:
            if info.state == .stopped {
                info.queuedSignals.insert(sig)
                jobs[id] = info
                return SignalOutcome(delivered: [], failed: [])
            } else {
                let backendResult = backend.deliver(sig, to: id)
                if backendResult {
                    return SignalOutcome(delivered: [id], failed: [])
                } else {
                    return SignalOutcome(delivered: [], failed: [id])
                }
            }
        }
    }

    private func applyQueuedSignal(_ sig: JobSignal, to id: JobID, jobInfo: JobInfo) -> SignalOutcome {
        // Queued signals are delivered with queuing disabled
        guard var info = jobs[id] else {
            return SignalOutcome()
        }

        switch sig {
        case .cont:
            // CONT shouldn't be queued, but handle it
            if info.state == .stopped {
                info.state = .running
                jobs[id] = info
                fireOnStateChange(id, .running)
                backend.deliver(.cont, to: id)
                return SignalOutcome(delivered: [id], failed: [])
            } else {
                backend.deliver(.cont, to: id)
                return SignalOutcome(delivered: [id], failed: [])
            }

        case .tstp:
            if info.state == .running {
                let backendResult = backend.deliver(.tstp, to: id)
                if backendResult {
                    info.state = .stopped
                    jobs[id] = info
                    fireOnStateChange(id, .stopped)
                    return SignalOutcome(delivered: [id], failed: [])
                } else {
                    return SignalOutcome(delivered: [], failed: [id])
                }
            } else if info.state == .stopped {
                // During queued delivery, don't queue again
                let backendResult = backend.deliver(.tstp, to: id)
                // Even if backend returns false, don't change state (already stopped)
                return SignalOutcome(delivered: [id], failed: backendResult ? [] : [id])
            } else {
                backend.deliver(.tstp, to: id)
                return SignalOutcome(delivered: [id], failed: [])
            }

        case .kill, .term:
            let backendResult = backend.deliver(sig, to: id)
            if !backendResult {
                backend.forceTerminate(id)
            }
            return SignalOutcome(delivered: [id], failed: [])

        case .winch, .hup, .int, .quit:
            // During queued delivery, don't queue again. Deliver directly.
            let backendResult = backend.deliver(sig, to: id)
            if backendResult {
                return SignalOutcome(delivered: [id], failed: [])
            } else {
                return SignalOutcome(delivered: [], failed: [id])
            }
        }
    }

    private func deliverToGroup(_ groupId: ProcessGroupID, sig: JobSignal) -> SignalOutcome {
        guard let groupJobs = groups[groupId], !groupJobs.isEmpty else {
            return SignalOutcome(noSuchTarget: true)
        }

        let jobIds = groupJobs
        // Check for exited state properly
        let nonExitedIds = jobIds.sorted { $0.raw < $1.raw }.filter { id in
            guard let info = jobs[id] else { return false }
            if case .exited = info.state { return false }
            return true
        }

        var delivered: [JobID] = []
        var failed: [JobID] = []

        for id in nonExitedIds {
            guard let info = jobs[id] else { continue }
            let result = applySignalProcedure(sig: sig, to: id, jobInfo: info)
            delivered.append(contentsOf: result.delivered)
            failed.append(contentsOf: result.failed)
        }

        return SignalOutcome(delivered: delivered, failed: failed, noSuchTarget: false)
    }

    // MARK: - Termination

    public func terminate(_ id: JobID, graceMillis: Int) {
        if isBlockedByReentrancy() {
            return
        }
        guard jobs[id] != nil else {
            return
        }

        // Send TERM
        _ = signal(.term, to: .job(id))

        // Cancel existing termination chain for this job
        if var info = jobs[id], let chain = info.terminationChain {
            chain.killToken?.cancel()
            chain.orphanToken?.cancel()
            info.terminationChain = nil
            jobs[id] = info
        }

        // Create new chain
        guard var info = jobs[id] else { return }

        let killToken = clock.schedule(afterMillis: max(0, graceMillis)) {
            self.handleKillEscalation(for: id)
        }
        let orphanToken = clock.schedule(afterMillis: max(0, 2 * graceMillis)) {
            self.handleOrphanCheck(for: id)
        }

        info.terminationChain = TerminationChain(killToken: killToken, orphanToken: orphanToken)
        jobs[id] = info
    }

    private func handleKillEscalation(for id: JobID) {
        guard var info = jobs[id] else {
            return
        }
        // If job has exited, cancel orphan and remove chain
        if case .exited = info.state {
            info.terminationChain?.killToken?.cancel()
            info.terminationChain?.orphanToken?.cancel()
            info.terminationChain = nil
            jobs[id] = info
            return
        }

        // Apply KILL (forceTerminate) as portable default
        backend.forceTerminate(id)

        // The kill token has fired; keep orphan token active
        info.terminationChain?.killToken = nil
        jobs[id] = info
    }

    private func handleOrphanCheck(for id: JobID) {
        guard var info = jobs[id] else {
            return
        }

        if case .exited = info.state {
            info.terminationChain?.orphanToken?.cancel()
            info.terminationChain = nil
            jobs[id] = info
            return
        }

        // Job still not exited after 2*grace - fire orphan
        onOrphanDetected?(id)
        info.terminationChain?.orphanToken = nil
        // Keep kill token cancelled (it's already fired)
        info.terminationChain?.killToken = nil
        info.terminationChain = nil
        jobs[id] = info
    }

    public func reapExited() -> [JobID] {
        if isBlockedByReentrancy() {
            return []
        }

        var exitedIds: [JobID] = []
        for (id, info) in jobs {
            if case .exited = info.state {
                exitedIds.append(id)
            }
        }
        exitedIds.sort { $0.raw < $1.raw }

        for id in exitedIds {
            guard var info = jobs[id] else { continue }
            // Clean up termination chain
            info.terminationChain?.killToken?.cancel()
            info.terminationChain?.orphanToken?.cancel()

            // Remove from group
            groups[info.group]?.remove(id)
            if groups[info.group]?.isEmpty == true {
                groups.removeValue(forKey: info.group)
            }

            // If this was the foreground group and it's now empty, clear foreground
            if foreground == info.group && (groups[info.group]?.isEmpty ?? true) {
                foreground = nil
            }

            jobs.removeValue(forKey: id)
        }

        return exitedIds
    }

    // MARK: - Termination chain cancellation on exit

    private func cancelTerminationChain(for id: JobID) {
        guard var info = jobs[id] else { return }
        info.terminationChain?.killToken?.cancel()
        info.terminationChain?.orphanToken?.cancel()
        info.terminationChain = nil
        jobs[id] = info
    }

}
