import Foundation
public struct TerminalSize: Equatable { public var columns:Int; public var rows:Int; public init(columns:Int,rows:Int){self.columns=columns;self.rows=rows} }
public protocol TerminalViewModel: AnyObject { var size:TerminalSize {get}; func send(_ bytes:[UInt8]); func resize(_ size:TerminalSize) }
public final class BasicTerminalViewModel: TerminalViewModel { public private(set) var size=TerminalSize(columns:80,rows:24); public var onInput:(([UInt8])->Void)?; public init(){}; public func send(_ bytes:[UInt8]){onInput?(bytes)}; public func resize(_ size:TerminalSize){self.size=size} }
