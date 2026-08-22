import Foundation
public protocol LinuxService { func run(argv:[String], cwd:String, stdinFD:Int32, stdoutFD:Int32, stderrFD:Int32, interactive:Bool) async -> Int32; func prepare() async throws }
public final class BlinkLinuxService: LinuxService { public let rootfs:URL; public init(rootfs:URL){self.rootfs=rootfs}; public func prepare() async throws { try FileManager.default.createDirectory(at:rootfs,withIntermediateDirectories:true) }; public func run(argv:[String],cwd:String,stdinFD:Int32,stdoutFD:Int32,stderrFD:Int32,interactive:Bool) async -> Int32 { 127 } }
