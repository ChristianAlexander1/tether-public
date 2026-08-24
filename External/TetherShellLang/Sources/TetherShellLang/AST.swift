import Foundation

// MARK: - Words

/// A shell word, kept in its *raw* (unexpanded) form — quotes, `$`, glob
/// characters and all — so that expansion happens at evaluation time with
/// access to the live environment.
public struct TetherWord {
    public var raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// A collected here-document body attached to a `<<` / `<<-` redirection.
public struct TetherHereDoc {
    /// Delimiter with quotes removed.
    public var delimiter: String
    /// Raw body text (tabs already stripped when `stripTabs` is set).
    public var body: String
    /// `<<-` form: leading tabs were stripped from body lines.
    public var stripTabs: Bool
    /// When `false` (delimiter was quoted) the body undergoes no expansion.
    public var expand: Bool

    public init(delimiter: String, body: String, stripTabs: Bool, expand: Bool) {
        self.delimiter = delimiter
        self.body = body
        self.stripTabs = stripTabs
        self.expand = expand
    }
}

// MARK: - Redirections

public enum TetherRedirOp {
    case input        // <
    case output       // >
    case append       // >>
    case clobber      // >|
    case readWrite    // <>
    case inputDup     // <&
    case outputDup    // >&
    case heredoc      // <<
    case heredocTabs  // <<-
    case hereString   // <<<  (mksh extension)
}

public struct TetherRedirect {
    /// Explicit file descriptor (from an `N<` / `N>` io-number), or nil.
    public var fd: Int?
    public var op: TetherRedirOp
    /// Target word (file name / fd word). Empty for here-doc operators.
    public var target: TetherWord
    /// Collected body for here-doc operators.
    public var hereDoc: TetherHereDoc?

    public init(fd: Int?, op: TetherRedirOp, target: TetherWord, hereDoc: TetherHereDoc? = nil) {
        self.fd = fd
        self.op = op
        self.target = target
        self.hereDoc = hereDoc
    }
}

// MARK: - Simple commands

public struct TetherAssignment {
    public var name: String
    public var value: TetherWord

    public init(name: String, value: TetherWord) {
        self.name = name
        self.value = value
    }
}

public struct TetherSimpleCommand {
    public var assignments: [TetherAssignment] = []
    public var words: [TetherWord] = []
    public var redirects: [TetherRedirect] = []

    public init() {}
}

// MARK: - Lists, pipelines, and/or

public enum TetherAndOrOp { case and, or }

public struct TetherAndOrTail {
    public var op: TetherAndOrOp
    public var pipeline: TetherPipeline
}

public struct TetherAndOr {
    public var first: TetherPipeline
    public var rest: [TetherAndOrTail] = []
}

public struct TetherPipeline {
    public var negated: Bool = false       // leading `!`
    public var commands: [TetherCommand] = []
}

/// One item of a complete command list; `async` marks a `&` terminator
/// (executed synchronously in this implementation, yielding status 0).
public struct TetherListItem {
    public var andOr: TetherAndOr
    public var async: Bool = false
}

// MARK: - Compound commands

public struct TetherElifClause {
    public var condition: [TetherListItem]
    public var body: [TetherListItem]
}

public struct TetherIfClause {
    public var condition: [TetherListItem]
    public var thenBody: [TetherListItem]
    public var elifs: [TetherElifClause] = []
    public var elseBody: [TetherListItem]?
}

public struct TetherArithFor {
    public var start: String
    public var condition: String
    public var step: String
}

public struct TetherForClause {
    public var varName: String = ""
    /// `nil` → iterate over `"$@"`.
    public var words: [TetherWord]? = nil
    /// mksh-style `for ((init; cond; step))`.
    public var arithmetic: TetherArithFor? = nil
    public var body: [TetherListItem] = []
}

public enum TetherCaseTerminator {
    case stop        // ;;
    case fallThru    // ;&   (mksh: keep executing the next body)
    case retest      // ;;&  (mksh: keep matching the next pattern)
}

public struct TetherCaseItem {
    public var patterns: [TetherWord]
    public var body: [TetherListItem]
    public var terminator: TetherCaseTerminator
}

public struct TetherCaseClause {
    public var subject: TetherWord
    public var items: [TetherCaseItem]
}

public struct TetherFunctionDef {
    /// The body is a compound command; redirects stored on it apply on *every
    /// call*, not at definition time.
    public var name: String
    public var body: TetherCommand
}

public indirect enum TetherCommand {
    case simple(TetherSimpleCommand)
    case braceGroup(body: [TetherListItem], redirects: [TetherRedirect])
    case subshell(body: [TetherListItem], redirects: [TetherRedirect])
    case ifClause(TetherIfClause, redirects: [TetherRedirect])
    case loop(condition: [TetherListItem], body: [TetherListItem], until: Bool, redirects: [TetherRedirect])
    case forClause(TetherForClause, redirects: [TetherRedirect])
    case caseClause(TetherCaseClause, redirects: [TetherRedirect])
    case functionDef(TetherFunctionDef)
    case arithmetic(expression: String, redirects: [TetherRedirect])
}

public struct TetherProgram {
    public var items: [TetherListItem]
    public init(items: [TetherListItem]) { self.items = items }
}
