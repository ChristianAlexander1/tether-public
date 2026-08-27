import Foundation
public final class VTQueryResponder {
 public var identity:TerminalIdentity { didSet { if oldValue.colorSchemeIsDark != identity.colorSchemeIsDark && reporting { onUnsolicitedReply?(colorReply()) } } }
 let policy:ResponsePolicy; public var onUnsolicitedReply:((Data)->Void)?; private let tok=VTStreamTokenizer(); private var reporting=false; private var mirror=[Int:Bool]()
 public init(identity:TerminalIdentity,policy:ResponsePolicy){self.identity=identity;self.policy=policy}
 private func dat(_ s:String)->Data{Data(s.utf8)}
 private func colorReply()->Data{dat("\u{1b}[?997;\(identity.colorSchemeIsDark ? 1:2)n")}
 public func process(_ input:Data)->(forward:Data,replies:Data){ var f=Data(),r=Data(); for t in tok.feed(input){ switch t {
 case .csi(let p,let i,let fin,let priv):
  let raw=VTToken.serialize(t); if priv && i.isEmpty && fin==0x68 || priv && i.isEmpty && fin==0x6c { for n in p {if policy.answerDECRQM.contains(n){mirror[n]=fin==0x68}} }
  if policy.answerColorScheme && priv && p.count==1 && p[0]==2031 && i.isEmpty && (fin==0x68 || fin==0x6c){reporting=fin==0x68}
  else if policy.answerColorScheme && priv && p.count==1 && p[0]==996 && fin==0x6e {r.append(colorReply())}
  else if policy.answerColorScheme && priv && p.count==1 && p[0]==2031 && i == [0x24] && fin==0x70 {r.append(dat("\u{1b}[?2031;\(reporting ? 1:2)$y"))}
  else if priv && i == [0x24] && fin==0x70 && p.count==1 && policy.answerDECRQM.contains(p[0]) {r.append(dat("\u{1b}[?\(p[0]);\(mirror[p[0]] == true ? 1:2)$y"))}
  else {f.append(raw)}
 case .osc(let code,let payload) where policy.answerOSCColorQueries && (code==10 || code==11) && payload==Data([0x3f]): let v=identity.colorSchemeIsDark ? (code==10 ? "rgb:ffff/ffff/ffff":"rgb:0000/0000/0000") : (code==10 ? "rgb:0000/0000/0000":"rgb:ffff/ffff/ffff"); r.append(dat("\u{1b}]\(code);\(v)\u{1b}\\"))
 case .dcs(let p) where policy.answerXTGETTCAP && p.first==0x2b && p.dropFirst().first==0x71: let names=String(decoding:p.dropFirst(2),as:UTF8.self).split(separator:";"); var hit=false; for n in names {if let bytes=Data(hex:String(n)),let name=String(data:bytes,encoding:.utf8),let val=identity.capabilities[name]{hit=true;r.append(dat("\u{1b}P1+r\(Data(name.utf8).hex) =\(Data(val.utf8).hex)\u{1b}\\".replacingOccurrences(of:" ",with:"")))}}; if !hit{r.append(dat("\u{1b}P0+r\u{1b}\\"))}
 default:f.append(VTToken.serialize(t)) } }; return(f,r) }
}
private extension Data { init?(hex:String){var d=Data();var s=hex;while s.count>=2{let x=String(s.prefix(2));guard let b=UInt8(x,radix:16) else{return nil};d.append(b);s=String(s.dropFirst(2))};guard s.isEmpty else{return nil};self=d};var hex:String{map{String(format:"%02x",$0)}.joined()} }
