import XCTest
@testable import LustreAgent

final class CloudWebSocketMailboxTests: XCTestCase {
    func testMultipleWakeFramesCoalesceWithoutDroppingNextDelivery() async throws {
        let mailbox = CloudWebSocketMailbox(capacity: 2)
        let wake = CloudWebSocketMessage.text(#"{"version":1,"type":"command-available"}"#)
        await mailbox.offer(wake)
        await mailbox.offer(wake)
        await mailbox.offer(.text(#"{"version":1,"type":"command-delivery"}"#))
        let first = try await mailbox.next()
        let second = try await mailbox.next()
        XCTAssertTrue(first.isCommandAvailable)
        XCTAssertFalse(second.isCommandAvailable)
        let firstWake = await mailbox.consumeWake()
        let secondWake = await mailbox.consumeWake()
        XCTAssertTrue(firstWake)
        XCTAssertFalse(secondWake)
    }

    func testBoundedMailboxRetainsOnlyNewestMessages() async throws {
        let mailbox = CloudWebSocketMailbox(capacity: 2)
        await mailbox.offer(.text(#"{"version":1,"type":"one"}"#))
        await mailbox.offer(.text(#"{"version":1,"type":"two"}"#))
        await mailbox.offer(.text(#"{"version":1,"type":"three"}"#))
        let first = try await mailbox.next()
        let second = try await mailbox.next()
        XCTAssertTrue(String(decoding: first.data, as: UTF8.self).contains("two"))
        XCTAssertTrue(String(decoding: second.data, as: UTF8.self).contains("three"))
    }
}
