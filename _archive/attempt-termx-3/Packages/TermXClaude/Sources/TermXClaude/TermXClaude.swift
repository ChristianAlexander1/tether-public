import Foundation
import TermXNode
public final class ClaudeCodeLauncher { private let node:NodeService; public init(node:NodeService){self.node=node}; public func run(cwd:String, env:[String:String], stdinFD:Int32, stdoutFD:Int32, stderrFD:Int32, interactive:Bool) async -> Int32 { await node.run(argv:["claude"],cwd:cwd,env:env,stdinFD:stdinFD,stdoutFD:stdoutFD,stderrFD:stderrFD,interactive:interactive) }; public func interrupt(){node.interrupt()} }
