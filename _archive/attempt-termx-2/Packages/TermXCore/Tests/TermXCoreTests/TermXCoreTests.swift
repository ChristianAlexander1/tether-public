import XCTest
@testable import TermXCore
final class TermXCoreTests:XCTestCase {
    func testTokenizerHonorsQuotes(){ XCTAssertEqual(ShellParser().tokenize("echo 'hello world' \"x y\""),["echo","hello world","x y"]) }
    func testBuiltinsAndRedirect(){ let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try!FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);var cwd=dir.path;var env=["HOME":dir.path];var out="";let s=ShellCore().run("echo hello > out.txt",cwd:&cwd,env:&env,output:{out += $0},error:{out += $0});XCTAssertEqual(s,0);XCTAssertEqual(try!String(contentsOf:dir.appendingPathComponent("out.txt")),"hello\n");XCTAssertEqual(out,"")}
    func testDirectoryLifecycle(){let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try!FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);var cwd=dir.path;var env=[String:String]();var out="";let shell=ShellCore();XCTAssertEqual(shell.run("mkdir child; cd child; pwd",cwd:&cwd,env:&env,output:{out += $0},error:{out += $0}),0);XCTAssertEqual(cwd,dir.appendingPathComponent("child").path);XCTAssertTrue(out.contains("child"))}
}
