import Foundation
public struct TUIModeState: Equatable, Sendable {
 public var alternateScreen=false, cursorHidden=false, bracketedPaste=false, applicationCursorKeys=false, applicationKeypad=false, focusReporting=false, synchronizedOutput=false, scrollRegionSet=false, savedCursor=false
 public var mouseModes=Set<Int>(); public var kittyKeyboardDepth=0
 public var isClean: Bool { !alternateScreen && !cursorHidden && mouseModes.isEmpty && !bracketedPaste && !applicationCursorKeys && !applicationKeypad && !focusReporting && !synchronizedOutput && !scrollRegionSet && !savedCursor && kittyKeyboardDepth == 0 }
 public init() {}
}
