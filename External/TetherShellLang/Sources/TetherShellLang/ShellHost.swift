import Foundation

/// `ShellHost` is the bridge between the Tether shell evaluator and the outside
/// world.
///
/// TetherShellLang is a *pure language* component: it never spawns OS
/// processes, touches the environment, or writes to a terminal on its own.
/// Every external command is forwarded to the host as a single, fully
/// expanded command line. All output flows back through `write`/`writeError`,
/// and exported variables live in the host environment.
///
/// Production apps implement this protocol against their real runtime;
/// tests drive the evaluator with a mock host (see `Tests/`).
public protocol ShellHost: AnyObject {
    /// Run a fully-expanded external command line. Returns its exit status.
    func run(commandLine: String) -> Int32
    /// Write text to standard output.
    func write(_ text: String)
    /// Write text to standard error.
    func writeError(_ text: String)
    /// Read a variable from the host environment.
    func value(for name: String) -> String?
    /// Set (or remove, with `nil`) a variable in the host environment.
    func setValue(_ value: String?, for name: String)
}

/// A parse-time failure. Carries a 1-based source line for diagnostics.
public struct TetherShellParseError: Error, CustomStringConvertible {
    public let message: String
    public let line: Int

    public init(_ message: String, line: Int) {
        self.message = message
        self.line = line
    }

    public var description: String {
        "syntax error at line \(line): \(message)"
    }
}
