import XCTest
@testable import TetherVTEngine
final class TokenizerTests: XCTestCase {
 func testEscapeSplitAtEveryBoundary(){let source=Data("\u{1b}[?1049h".utf8); for cut in 0..<source.count {let t=VTStreamTokenizer(); let a=t.feed(Data(source.prefix(cut))); let b=t.feed(Data(source.dropFirst(cut)))+t.flush(); XCTAssertEqual(a+b,[.csi(params:[1049],intermediates:[],final:104,isPrivate:true)])}}
 func testEmojiSplit(){let bytes=Data("😀".utf8); let t=VTStreamTokenizer(); XCTAssertTrue(t.feed(Data(bytes.prefix(2))).isEmpty); XCTAssertEqual(t.feed(Data(bytes.dropFirst(2)))+t.flush(),[.text(bytes)])}
 func testOverlongOSCIsRaw(){let p=Data(repeating:65,count:100_000); let input=Data([27,93,49,48,59])+p+Data([7]); let t=VTStreamTokenizer(); var output=t.feed(input); output += t.flush(); XCTAssertEqual(output.reduce(Data()){var d=$0;d.append(contentsOf:VTToken.serialize($1));return d},input)}
 func testEmptyAndFlush(){let t=VTStreamTokenizer(); XCTAssertTrue(t.feed(Data()).isEmpty); XCTAssertEqual(t.feed(Data([27])).count,0); XCTAssertEqual(t.flush(),[.text(Data([27]))])}
 func testLargeParamsClamp(){let t=VTStreamTokenizer(); let x=t.feed(Data("\u{1b}[1;\(String(repeating:"9",count:20))m".utf8)); guard case .csi(let p,_,_,_)=x[0] else {return XCTFail()}; XCTAssertEqual(p.count,2); XCTAssertEqual(p[1],Int(Int32.max))}
}
