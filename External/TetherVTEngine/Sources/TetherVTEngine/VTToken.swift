import Foundation

public enum VTToken: Equatable, Sendable {
    case text(Data)
    case c0(UInt8)
    case esc(final: UInt8, intermediates: [UInt8])
    case csi(params: [Int], intermediates: [UInt8], final: UInt8, isPrivate: Bool)
    case osc(code: Int, payload: Data)
    case dcs(payload: Data)
    case incomplete

    public static func serialize(_ token: VTToken) -> Data {
        switch token {
        case .text(let d): return d
        case .c0(let b): return Data([b])
        case .esc(let f, let i): return Data([0x1b] + i + [f])
        case .csi(let p, let i, let f, let priv):
            var a = Data([0x1b, 0x5b]); let marker = i.first(where: { $0 == 0x3c || $0 == 0x3e }) ?? (priv ? 0x3f : 0); if marker != 0 { a.append(marker) }
            a.append(contentsOf: Data(p.map(String.init).joined(separator: ";").utf8)); a.append(contentsOf: i.filter { $0 != 0x3c && $0 != 0x3e }); a.append(f); return a
        case .osc(let c, let p): var a = Data([0x1b,0x5d]); a.append(contentsOf: Data(String(c).utf8)); a.append(0x3b); a.append(contentsOf: p); a.append(contentsOf: [0x1b,0x5c]); return a
        case .dcs(let p): var a = Data([0x1b,0x50]); a.append(contentsOf: p); a.append(contentsOf: [0x1b,0x5c]); return a
        case .incomplete: return Data()
        }
    }
}
