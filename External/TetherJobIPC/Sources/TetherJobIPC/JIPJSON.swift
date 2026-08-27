import Foundation

/// A small JSON *encoder* that produces deterministic output so that golden wire
/// fixtures are stable (object keys are emitted in sorted order). Used for every
/// frame the session writes. Parsing (for inbound messages) uses
/// `JSONSerialization` and is unaffected by key order.
internal enum JIPJSON {

    /// Serialize a Foundation/Swift value tree to a compact JSON string.
    static func encode(_ value: Any) -> String {
        serialize(value)
    }

    private static func serialize(_ value: Any) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case is NSNull:
            return "null"
        case let i as Int:
            return String(i)
        case let i as Int32:
            return String(i)
        case let i as Int64:
            return String(i)
        case let i as UInt:
            return String(i)
        case let i as UInt64:
            return String(i)
        case let i as UInt32:
            return String(i)
        case let i as UInt16:
            return String(i)
        case let d as Double:
            return number(d)
        case let s as String:
            return string(s)
        case let arr as [Any]:
            return "[" + arr.map(serialize).joined(separator: ",") + "]"
        case let arr as [String]:
            return "[" + arr.map(string).joined(separator: ",") + "]"
        case let arr as [Int]:
            return "[" + arr.map(String.init).joined(separator: ",") + "]"
        case let arr as [Int32]:
            return "[" + arr.map(String.init).joined(separator: ",") + "]"
        case let arr as [Int64]:
            return "[" + arr.map(String.init).joined(separator: ",") + "]"
        case let obj as [String: Any]:
            let keys = obj.keys.sorted()
            var parts: [String] = []
            parts.reserveCapacity(keys.count)
            for k in keys {
                parts.append(string(k) + ":" + serialize(obj[k]!))
            }
            return "{" + parts.joined(separator: ",") + "}"
        case let str as Substring:
            return string(String(str))
        default:
            return "null"
        }
    }

    private static func number(_ d: Double) -> String {
        if d.isNaN || d.isInfinite {
            return "null"
        }
        // Emit integers without a trailing ".0" for cleanliness; otherwise use the
        // Swift textual representation (valid JSON number syntax).
        if d == d.rounded() && abs(d) < 9.007_199_254_740_992 {
            return String(Int64(d))
        }
        return String(d)
    }

    private static func string(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: // "
                out.append("\\\"")
            case 0x5C: // \
                out.append("\\\\")
            case 0x08:
                out.append("\\b")
            case 0x0C:
                out.append("\\f")
            case 0x0A:
                out.append("\\n")
            case 0x0D:
                out.append("\\r")
            case 0x09:
                out.append("\\t")
            case 0x00...0x1F:
                out.append(String(format: "\\u%04x", scalar.value))
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out.append("\"")
        return out
    }
}
