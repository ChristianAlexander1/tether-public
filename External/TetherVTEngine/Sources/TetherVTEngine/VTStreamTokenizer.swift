import Foundation

public final class VTStreamTokenizer {
    private var pending = Data(); private var state = 0 // 0 ground, 1 esc, 2 csi, 3 osc, 4 dcs, 5 ignored string
    private var body = Data(); private var utf8Pending = Data(); private var escInter = [UInt8](); private var csiInter = [UInt8](); private var csiPrivate = false
    public init() {}
    private func text(_ d: Data) -> VTToken { .text(d) }
    public func feed(_ bytes: Data) -> [VTToken] {
        if bytes.isEmpty { return [] }; var out=[VTToken](); var textBuf=Data(); var input=utf8Pending; input.append(contentsOf: bytes); utf8Pending.removeAll()
        func emitText() { if !textBuf.isEmpty { out.append(.text(textBuf)); textBuf.removeAll(keepingCapacity:true) } }
        for b in input {
            if state == 0 {
                if b == 0x1b { emitText(); state=1; pending=Data([b]); escInter=[] }
                else if b < 0x20 || b == 0x7f { emitText(); out.append(.c0(b)) }
                else { textBuf.append(b) }
                continue
            }
            pending.append(b)
            if pending.count > 65536 { emitText(); textBuf.append(contentsOf: pending); pending.removeAll(); body.removeAll(); state=0; continue }
            switch state {
            case 1:
                if b == 0x5b { state=2; body.removeAll(); csiInter=[]; csiPrivate=false }
                else if b == 0x5d { state=3; body.removeAll() }
                else if b == 0x50 { state=4; body.removeAll() }
                else if b == 0x58 || b == 0x5e || b == 0x5f { state=5 }
                else if b >= 0x20 && b <= 0x2f { escInter.append(b) }
                else if b >= 0x30 && b <= 0x7e { emitText(); out.append(.esc(final:b, intermediates:escInter)); pending.removeAll(); state=0 }
                else { /* C0 in escape is retained and sequence continues */ }
            case 2:
                if b >= 0x20 && b <= 0x2f { csiInter.append(b) }
                else if b >= 0x40 && b <= 0x7e { emitText(); out.append(parseCSI(final:b)); pending.removeAll(); state=0 }
                else if b >= 0x30 && b <= 0x3f { if (b == 0x3f || b == 0x3e || b == 0x3c || b == 0x3d) && body.isEmpty { csiPrivate=true }; body.append(b) }
                else if b == 0x1b { /* retain; malformed gets flushed eventually */ }
            case 3:
                if b == 0x07 { emitText(); out.append(parseOSC()); pending.removeAll(); state=0 }
                else if b == 0x1b { /* ST handled by following backslash */ }
                else if b == 0x5c && pending.count >= 2 && pending[pending.count-2] == 0x1b { emitText(); out.append(parseOSC()); pending.removeAll(); state=0 }
                else { if pending.count >= 2 && pending[pending.count-2] == 0x1b { body.append(0x1b) }; body.append(b) }
            case 4:
                if b == 0x5c && pending.count >= 2 && pending[pending.count-2] == 0x1b { emitText(); out.append(.dcs(payload: body)); pending.removeAll(); body.removeAll(); state=0 } else { if pending.count >= 2 && pending[pending.count-2] == 0x1b { body.append(0x1b) }; body.append(b) }
            case 5:
                if b == 0x5c && pending.count >= 2 && pending[pending.count-2] == 0x1b { emitText(); textBuf.append(contentsOf: pending); pending.removeAll(); state=0 }
                else if b != 0x1b { /* ignored string remains buffered for lossless flush */ }
            default: break
            }
        }
        if state == 0 && !textBuf.isEmpty {
            let q=Array(textBuf); var start=q.count-1
            while start > 0 && q[start] >= 0x80 && q[start] <= 0xBF { start -= 1 }
            if start < q.count { let lead=q[start]; let need = lead >= 0xC2 && lead <= 0xDF ? 2 : (lead >= 0xE0 && lead <= 0xEF ? 3 : (lead >= 0xF0 && lead <= 0xF4 ? 4 : 0)); let have=q.count-start; if need > 0 && have < need { utf8Pending=Data(q[start..<q.count]); textBuf=Data(q[0..<start]) } }
        }
        emitText(); return out
    }
    private func parseCSI(final: UInt8) -> VTToken { var raw=body; if let marker = raw.first, marker == 0x3f || marker == 0x3e || marker == 0x3c || marker == 0x3d { raw.removeFirst(); if marker == 0x3e || marker == 0x3c { csiInter.insert(marker, at: 0) } }; let parts=String(decoding:raw,as:UTF8.self).split(separator:";",omittingEmptySubsequences:false); let p=parts.map { Self.clampedParameter(String($0)) }; return .csi(params:p, intermediates:csiInter, final:final, isPrivate:csiPrivate) }
    private static func clampedParameter(_ s:String) -> Int { if s.isEmpty { return 0 }; var n:Int64=0; for u in s.utf8 { guard u >= 48 && u <= 57 else { return 0 }; if n > (Int64(Int32.max) - Int64(u-48))/10 { return Int(Int32.max) }; n=n*10+Int64(u-48) }; return Int(n) }
    private func parseOSC() -> VTToken { let sep=body.firstIndex(of:0x3b); let code=sep.flatMap { Int(String(decoding:body[..<$0],as:UTF8.self)) } ?? -1; let payload=sep.map { Data(body[body.index(after:$0)...]) } ?? Data(); return .osc(code:code,payload:payload) }
    public func flush() -> [VTToken] { var a=[VTToken](); var d=utf8Pending; d.append(contentsOf: pending); if !d.isEmpty { a.append(.text(d)) }; utf8Pending.removeAll(); pending.removeAll(); body.removeAll(); state=0; return a }
}
