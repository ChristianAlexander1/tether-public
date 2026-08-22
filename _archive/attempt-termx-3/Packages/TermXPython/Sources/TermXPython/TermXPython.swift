import Foundation
public protocol PythonService { func run(argv:[String], cwd:String, env:[String:String], stdinFD:Int32, stdoutFD:Int32, stderrFD:Int32, interactive:Bool) async -> Int32; func interrupt() }
public final class EmbeddedPythonService: PythonService { public init(){}; public func run(argv:[String],cwd:String,env:[String:String],stdinFD:Int32,stdoutFD:Int32,stderrFD:Int32,interactive:Bool) async -> Int32 { 127 }; public func interrupt(){} }
