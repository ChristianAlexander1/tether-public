import XCTest
@testable import TetherVTEngine
final class TokenizerFuzzTests: XCTestCase {
 func testDeterministicThousandChunkings(){var seed:UInt64=0x12345678abcdef; func next()->UInt8 {seed = seed &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: seed >> 32)}; for _ in 0..<1000 {var input=Data(); for _ in 0..<64 {let b=next(); if b % 13 == 0 {input.append(contentsOf:[27,91,49,109])} else if b % 17 == 0 {input.append(contentsOf:[27,93,49,59,63,27,92])} else {input.append(UInt8(32 + (b % 95)))}}; let t=VTStreamTokenizer(); var result=[VTToken](); var i=0; while i<input.count {let n=min(input.count-i,Int(next()%7)+1); result += t.feed(Data(input[i..<i+n])); i += n}; result += t.flush(); var round=Data(); for token in result {round.append(contentsOf:VTToken.serialize(token))}; XCTAssertEqual(round,input)} }
}
