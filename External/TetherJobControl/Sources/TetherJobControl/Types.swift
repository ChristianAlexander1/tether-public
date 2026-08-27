import Foundation

public struct JobID: Hashable, Sendable {
    public let raw: Int32
    public init(raw: Int32) { self.raw = raw }
}

public struct ProcessGroupID: Hashable, Sendable {
    public let raw: Int32
    public init(raw: Int32) { self.raw = raw }
}

public enum JobState: Equatable, Sendable {
    case spawning
    case running
    case stopped
    case exited(code: Int32?, signal: String?)
}

public enum JobSignal: String, Sendable, CaseIterable {
    case int = "SIGINT"
    case term = "SIGTERM"
    case kill = "SIGKILL"
    case hup = "SIGHUP"
    case winch = "SIGWINCH"
    case tstp = "SIGTSTP"
    case cont = "SIGCONT"
    case quit = "SIGQUIT"
}

public protocol JobBackend: AnyObject {
    func deliver(_ signal: JobSignal, to job: JobID) -> Bool
    func forceTerminate(_ job: JobID)
}

public struct JobSpec: Sendable {
    public var argv: [String]
    public var group: ProcessGroupID?
    public var isForegroundCandidate: Bool
    public init(argv: [String], group: ProcessGroupID?, isForegroundCandidate: Bool) {
        self.argv = argv
        self.group = group
        self.isForegroundCandidate = isForegroundCandidate
    }
}

public struct SignalOutcome: Equatable, Sendable {
    public var delivered: [JobID]
    public var failed: [JobID]
    public var noSuchTarget: Bool
    public init(delivered: [JobID] = [], failed: [JobID] = [], noSuchTarget: Bool = false) {
        self.delivered = delivered
        self.failed = failed
        self.noSuchTarget = noSuchTarget
    }
}
