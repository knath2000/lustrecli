import XCTest
@testable import LustreAgent

final class BoundedLineDecoderTests: XCTestCase {
    func testDecodesSplitMixedDelimitersWithoutCRLFDuplicate() throws {
        var decoder = BoundedLineDecoder(maximumLineBytes: 8)
        XCTAssertEqual(try decoder.append(Data("one\rtwo\r".utf8)), [Data("one".utf8), Data("two".utf8)])
        XCTAssertEqual(try decoder.append(Data("\nthree".utf8)), [])
        XCTAssertEqual(try decoder.finish(), [Data("three".utf8)])
        XCTAssertEqual(try decoder.finish(), [])
    }

    func testRejectsOversizedBufferedLine() throws {
        var decoder = BoundedLineDecoder(maximumLineBytes: 3)
        XCTAssertThrowsError(try decoder.append(Data("abcd".utf8)))
        XCTAssertThrowsError(try decoder.finish())
    }

    func testDelimiterBoundariesEmptyLinesAndBinaryPassThrough() throws {
        var decoder = BoundedLineDecoder(maximumLineBytes: 3)
        XCTAssertEqual(try decoder.append(Data("a\n\nb\r\nc".utf8)), [Data("a".utf8), Data("b".utf8)])
        XCTAssertEqual(try decoder.finish(), [Data("c".utf8)])
        XCTAssertEqual(try decoder.append(Data([0xff, 10])), [Data([0xff])])

        var exact = BoundedLineDecoder(maximumLineBytes: 3)
        XCTAssertEqual(try exact.append(Data("abc\n".utf8)), [Data("abc".utf8)])
        XCTAssertThrowsError(try exact.append(Data("abcd".utf8)))
    }
}
