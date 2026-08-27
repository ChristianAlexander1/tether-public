/// Error codes defined by the TJIP/2 wire spec. They are errno-style identifiers.
public enum JIPErrorCode {
    public static let enoent = "ENOENT"
    public static let eacces = "EACCES"
    public static let eperm = "EPERM"
    public static let einval = "EINVAL"
    public static let esrch = "ESRCH"
    public static let epipe = "EPIPE"
    public static let enosys = "ENOSYS"
    public static let eproto = "EPROTO"
    public static let emsgsize = "EMSGSIZE"
    public static let eagain = "EAGAIN"
    /// Transport-level I/O failure (socket write/read). Used by integrator
    /// transports; HANDOFF.md's reference `JIPTransport` throws it directly.
    public static let eio = "EIO"
}

/// A structured error carried in a `res` body (`code` + `message`) or surfaced as a
/// protocol failure via `onProtocolError`.
public struct JIPError: Error, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
