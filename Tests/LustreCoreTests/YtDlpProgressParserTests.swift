import XCTest
@testable import LustreAgent
@testable import LustreCore

final class YtDlpProgressParserTests: XCTestCase {
    func testParsesExactTotalAndSafeComponent() throws {
        let sample = try YtDlpProgressParser.parse(Data("LUSTRE_PROGRESS:v1\tdownloading\t50\t100\t120\t10.5\t5\t1\t2\tvideo".utf8))
        XCTAssertEqual(sample.phase, .materializing)
        XCTAssertEqual(sample.message, "Downloading video…")
        XCTAssertEqual(sample.progress.bytesWritten, 50)
        XCTAssertEqual(sample.progress.totalBytes, 100)
        XCTAssertFalse(sample.progress.totalIsEstimated)
        XCTAssertEqual(sample.progress.fraction, 0.5)
    }

    func testEstimatedTotalAndPostProcessingAreSafe() throws {
        let estimated = try YtDlpProgressParser.parse(Data("LUSTRE_PROGRESS:v1\tdownloading\t150\tNA\t100\tNA\tNA\tNA\tNA\taudio".utf8))
        XCTAssertEqual(estimated.progress.totalBytes, 100)
        XCTAssertTrue(estimated.progress.totalIsEstimated)
        XCTAssertEqual(estimated.progress.fraction, 1)

        let post = try YtDlpProgressParser.parse(Data("LUSTRE_PROGRESS:v1\tpostprocessing\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA".utf8))
        XCTAssertEqual(post.phase, .postProcessing)
        XCTAssertEqual(post.message, "Merging video and audio…")
        XCTAssertNil(post.progress.fraction)
    }

    func testRejectsMalformedOrSecretBearingRecords() {
        for raw in [
            "wrong\tdownloading\t0\tNA\tNA\tNA\tNA\tNA\tNA\tNA",
            "LUSTRE_PROGRESS:v1\tdownloading\t-1\tNA\tNA\tNA\tNA\tNA\tNA\tNA",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNaN\tNA\tNA\tNA\tNA",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNA\tNA\tNA\tNA\thttps://example.test",
            "LUSTRE_PROGRESS:v1\tunknown\t1\tNA\tNA\tNA\tNA\tNA\tNA\tNA"
        ] {
            XCTAssertThrowsError(try YtDlpProgressParser.parse(Data(raw.utf8)))
        }
    }

    func testRejectsCaseVariantsControlsBoundsAndFragmentInconsistency() {
        let base = "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNA\tNA\tNA\tNA\tNA"
        let invalid = [
            base + "\u{1b}",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNA\tNA\t1\t0\tmedia",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\t999999999999999999999\tNA\tNA\tNA\tmedia",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNA\t9999999999\tNA\tNA\tmedia",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNA\tNA\tNA\tNA\tHTTPS://example.test",
            "LUSTRE_PROGRESS:v1\tdownloading\t1\tNA\tNA\tNA\tNA\tNA\tNA\tcookie:bad"
        ]
        for line in invalid { XCTAssertThrowsError(try YtDlpProgressParser.parse(Data(line.utf8))) }
        XCTAssertThrowsError(try YtDlpProgressParser.parse(Data(repeating: 65, count: YtDlpProgressParser.maximumLineBytes + 1)))
    }

    func testFinishedRequiresFinalByteAccounting() throws {
        XCTAssertThrowsError(try YtDlpProgressParser.parse(Data("LUSTRE_PROGRESS:v1\tfinished\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tmedia".utf8)))
        let finished = try YtDlpProgressParser.parse(Data("LUSTRE_PROGRESS:v1\tfinished\t100\t100\tNA\tNA\tNA\tNA\tNA\tmedia".utf8))
        XCTAssertEqual(finished.progress.fraction, 1)
    }
}
