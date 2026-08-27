import Foundation
public final class TUIStateTracker {
 public private(set) var state=TUIModeState(); public init() {}
 public func reset(){state=TUIModeState()}
 public func observe(_ t:VTToken){
  switch t {
  case .esc(let f,_): if f==0x37 {state.savedCursor=true}; if f==0x38 {state.savedCursor=false}; if f==0x3d {state.applicationKeypad=true}; if f==0x3e {state.applicationKeypad=false}; if f==0x63 {reset()}
  case .csi(let p,let i,let f,let priv):
   if f==0x70 && i == [0x21] {reset();return}
   if f==0x68 || f==0x6c { let on=f==0x68; if priv { for n in p { set(n,on:on) } } }
   if f==0x72 { state.scrollRegionSet = !(p.isEmpty || (p.count==1 && p[0]==0)) }
   if f==0x75 && i == [0x3e] { state.kittyKeyboardDepth += (p.first ?? 0) == 0 ? 1 : p[0] }
   if f==0x75 && i == [0x3c] { state.kittyKeyboardDepth=max(0,state.kittyKeyboardDepth-(((p.first ?? 0) == 0) ? 1 : p[0])) }
  default: break }
 }
 private func set(_ n:Int,on:Bool){ switch n { case 1:state.applicationCursorKeys=on; case 25:state.cursorHidden = !on; case 47,1047,1049:state.alternateScreen=on; case 9,1000,1002,1003,1005,1006,1015: if on {state.mouseModes.insert(n)} else {state.mouseModes.remove(n)}; case 2004:state.bracketedPaste=on; case 1004:state.focusReporting=on; case 2026:state.synchronizedOutput=on; default:break } }
 public func restoreSequence()->Data { if state.isClean{return Data()}; var d=Data(); func a(_ s:String){d.append(contentsOf:s.utf8)}; if state.synchronizedOutput{a("\u{1b}[?2026l")}; for m in state.mouseModes.sorted(){a("\u{1b}[?\(m)l")}; if state.bracketedPaste{a("\u{1b}[?2004l")}; if state.focusReporting{a("\u{1b}[?1004l")}; if state.kittyKeyboardDepth>0{for _ in 0..<state.kittyKeyboardDepth{a("\u{1b}[<u")}}; if state.scrollRegionSet{a("\u{1b}[r")}; if state.savedCursor{a("\u{1b}8")}; if state.alternateScreen{a("\u{1b}[?1049l")}; if state.applicationCursorKeys{a("\u{1b}[?1l")}; if state.applicationKeypad{a("\u{1b}>")}; a("\u{1b}[0m"); if state.cursorHidden{a("\u{1b}[?25h")}; return d }
}
