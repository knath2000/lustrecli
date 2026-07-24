import XCTest
@testable import LustreAgent
@testable import LustreCore

final class YtDlpProgressEventChannelTests: XCTestCase {
    func testWaitingConsumerReceivesOfferedSampleExactlyOnce() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        try await channel.offer(sample(1))

        let result = await consumer.value
        XCTAssertEqual(try result.get()?.progress.bytesWritten, 1)
        await channel.finish()
        let drained = try await channel.next()
        XCTAssertNil(drained)
    }

    func testBufferedSamplesPreserveFIFOAndCoalescing() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 5)
        try await channel.offer(sample(.materializing, .downloading, .video, 1))
        try await channel.offer(sample(.materializing, .downloading, .video, 2))
        try await channel.offer(sample(.materializing, .downloading, .video, 3))
        try await channel.offer(sample(.materializing, .downloading, .audio, 4))
        try await channel.offer(sample(.postProcessing, .postProcessing, .media, 5))
        try await channel.offer(sample(.materializing, .finished, .media, 6))

        let first = try await channel.next()
        let second = try await channel.next()
        let third = try await channel.next()
        let fourth = try await channel.next()
        let fifth = try await channel.next()
        XCTAssertEqual(first?.progress.bytesWritten, 1)
        XCTAssertEqual(second?.progress.bytesWritten, 3)
        XCTAssertEqual(third?.component, .audio)
        XCTAssertEqual(fourth?.phase, .postProcessing)
        XCTAssertEqual(fifth?.status, .finished)
    }

    func testSlowConsumerKeepsSameCategoryPendingEventsBounded() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(1))
        let first = try await channel.next()
        XCTAssertEqual(first?.progress.bytesWritten, 1)

        for bytes in 2...100 { try await channel.offer(sample(Int64(bytes))) }

        let pendingFirst = try await channel.next()
        let pendingLatest = try await channel.next()
        XCTAssertEqual(pendingFirst?.progress.bytesWritten, 2)
        XCTAssertEqual(pendingLatest?.progress.bytesWritten, 100)
        await channel.finish()
        let drained = try await channel.next()
        XCTAssertNil(drained)
    }

    func testCapacityErrorPreservesContentsAndChannelRemainsUsable() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(.materializing, .downloading, .video, 1))
        try await channel.offer(sample(.materializing, .downloading, .audio, 2))

        await XCTAssertThrowsChannelError(try await channel.offer(sample(.postProcessing, .postProcessing, .media, 3)), .capacityExceeded)
        try await channel.offer(sample(.materializing, .downloading, .audio, 4))

        let first = try await channel.next()
        let second = try await channel.next()
        XCTAssertEqual(first?.progress.bytesWritten, 1)
        XCTAssertEqual(second?.progress.bytesWritten, 4)
    }

    func testFinishDrainsBufferedEventsThenReturnsNil() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(.materializing, .downloading, .video, 1))
        try await channel.offer(sample(.materializing, .downloading, .audio, 2))

        await channel.finish()
        await channel.finish()

        let first = try await channel.next()
        let second = try await channel.next()
        let drained = try await channel.next()
        XCTAssertEqual(first?.progress.bytesWritten, 1)
        XCTAssertEqual(second?.progress.bytesWritten, 2)
        XCTAssertNil(drained)
        await XCTAssertThrowsChannelError(try await channel.offer(sample(3)), .closed)
    }

    func testFinishWakesEmptyWaiterWithNil() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        await channel.finish()

        let result = await consumer.value
        XCTAssertNil(try result.get())
    }

    func testCancelDiscardsPendingAndTerminatesWaiterAndFutureCalls() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(1))

        await channel.cancel()
        await channel.cancel()
        await channel.finish()

        await XCTAssertThrowsChannelError(try await channel.next(), .cancelled)
        await XCTAssertThrowsChannelError(try await channel.offer(sample(2)), .cancelled)

        let waitingChannel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: waitingChannel)
        await waitForWaiter(waitingChannel)
        await waitingChannel.cancel()
        XCTAssertChannelError(await consumer.value, .cancelled)
    }

    func testSecondWaiterFailsAndSequentialCallsRemainValid() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let first = consumer(for: channel)
        await waitForWaiter(channel)

        let second = consumer(for: channel)
        XCTAssertChannelError(await second.value, .multipleConsumers)

        try await channel.offer(sample(1))
        let firstResult = await first.value
        XCTAssertEqual(try firstResult.get()?.progress.bytesWritten, 1)
        try await channel.offer(sample(2))
        let secondSample = try await channel.next()
        XCTAssertEqual(secondSample?.progress.bytesWritten, 2)
    }

    func testCancelledWaiterCanBeReplacedWithoutAffectingTheNewWaiter() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let cancelled = consumer(for: channel)
        await waitForWaiter(channel)

        cancelled.cancel()
        XCTAssertChannelError(await cancelled.value, .cancelled)

        let replacement = consumer(for: channel)
        await waitForWaiter(channel)
        try await channel.offer(sample(2))
        let result = await replacement.value
        XCTAssertEqual(try result.get()?.progress.bytesWritten, 2)
    }

    func testCancelledWaiterLeavesChannelOpenForBufferedDelivery() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        consumer.cancel()
        XCTAssertChannelError(await consumer.value, .cancelled)
        try await channel.offer(sample(1))

        let buffered = try await channel.next()
        XCTAssertEqual(buffered?.progress.bytesWritten, 1)
    }

    func testOfferRaceWithWaiterCancellationDeliversOrBuffersExactlyOnce() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        consumer.cancel()
        try await channel.offer(sample(1))

        switch await consumer.value {
        case .success(let sample):
            XCTAssertEqual(sample?.progress.bytesWritten, 1)
            await channel.finish()
            let drained = try await channel.next()
            XCTAssertNil(drained)
        case .failure(let error):
            XCTAssertEqual(error as? YtDlpProgressEventChannelError, .cancelled)
            let sample = try await channel.next()
            XCTAssertEqual(sample?.progress.bytesWritten, 1)
        }
    }

    func testOfferFinishRaceCompletesWaiterExactlyOnce() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)
        let offeredSample = sample(1)

        async let offered: Result<Void, Error> = {
            do {
                try await channel.offer(offeredSample)
                return .success(())
            } catch {
                return .failure(error)
            }
        }()
        async let finished: Void = channel.finish()

        let offerResult = await offered
        await finished
        let consumerResult = await consumer.value
        switch offerResult {
        case .success:
            XCTAssertEqual(try consumerResult.get()?.progress.bytesWritten, 1)
        case .failure(let error):
            XCTAssertEqual(error as? YtDlpProgressEventChannelError, .closed)
            XCTAssertNil(try consumerResult.get())
        }
    }

    func testAlreadyCancelledCallerDoesNotRegister() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let cancelled = Task<Result<YtDlpProgressSample?, Error>, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            do { return .success(try await channel.next()) }
            catch { return .failure(error) }
        }

        XCTAssertChannelError(await cancelled.value, .cancelled)
        let replacement = consumer(for: channel)
        await waitForWaiter(channel)
        try await channel.offer(sample(1))
        let result = await replacement.value
        XCTAssertEqual(try result.get()?.progress.bytesWritten, 1)
    }

    func testFinishThenCancelPreservesGracefulDrain() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(1))

        await channel.finish()
        await channel.cancel()

        let first = try await channel.next()
        let drained = try await channel.next()
        XCTAssertEqual(first?.progress.bytesWritten, 1)
        XCTAssertNil(drained)
        await XCTAssertThrowsChannelError(try await channel.offer(sample(2)), .closed)
    }

    func testCancelThenFinishPreservesCancellation() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(1))

        await channel.cancel()
        await channel.finish()

        await XCTAssertThrowsChannelError(try await channel.next(), .cancelled)
        await XCTAssertThrowsChannelError(try await channel.offer(sample(2)), .cancelled)
    }

    func testFinishRaceWithConsumerTaskCancellationCompletesExactlyOnce() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        consumer.cancel()
        await channel.finish()

        switch await consumer.value {
        case .success(let sample):
            XCTAssertNil(sample)
        case .failure(let error):
            XCTAssertEqual(error as? YtDlpProgressEventChannelError, .cancelled)
        }
        let next = try await channel.next()
        XCTAssertNil(next)
    }

    func testChannelCancelRaceWithConsumerTaskCancellationCompletesExactlyOnce() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        consumer.cancel()
        await channel.cancel()

        XCTAssertChannelError(await consumer.value, .cancelled)
        await XCTAssertThrowsChannelError(try await channel.next(), .cancelled)
    }

    func testConcurrentFinishAndCancelWithWaitingConsumerUsesFirstTerminalState() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        let consumer = consumer(for: channel)
        await waitForWaiter(channel)

        async let finished: Void = channel.finish()
        async let cancelled: Void = channel.cancel()
        await finished
        await cancelled

        switch await consumer.value {
        case .success(let received):
            XCTAssertNil(received)
            let next = try await channel.next()
            XCTAssertNil(next)
            await XCTAssertThrowsChannelError(try await channel.offer(sample(1)), .closed)
        case .failure(let error):
            XCTAssertEqual(error as? YtDlpProgressEventChannelError, .cancelled)
            await XCTAssertThrowsChannelError(try await channel.next(), .cancelled)
            await XCTAssertThrowsChannelError(try await channel.offer(sample(1)), .cancelled)
        }
    }

    func testConcurrentFinishAndCancelWithBufferedProgressUsesFirstTerminalState() async throws {
        let channel = YtDlpProgressEventChannel(capacity: 2)
        try await channel.offer(sample(1))

        async let finished: Void = channel.finish()
        async let cancelled: Void = channel.cancel()
        await finished
        await cancelled

        do {
            let first = try await channel.next()
            let drained = try await channel.next()
            XCTAssertEqual(first?.progress.bytesWritten, 1)
            XCTAssertNil(drained)
            await XCTAssertThrowsChannelError(try await channel.offer(sample(2)), .closed)
        } catch {
            XCTAssertEqual(error as? YtDlpProgressEventChannelError, .cancelled)
            await XCTAssertThrowsChannelError(try await channel.offer(sample(2)), .cancelled)
        }
    }

    func testWaiterRegistrationObservationDoesNotStrandAtTerminalState() async throws {
        let finished = YtDlpProgressEventChannel(capacity: 2)
        let finishObserver = Task { await finished.waitForWaiterRegistrationForTesting() }
        await finished.finish()
        let finishResult = await finishObserver.value
        XCTAssertFalse(finishResult)

        let cancelled = YtDlpProgressEventChannel(capacity: 2)
        let cancelObserver = Task { await cancelled.waitForWaiterRegistrationForTesting() }
        await cancelled.cancel()
        let cancelResult = await cancelObserver.value
        XCTAssertFalse(cancelResult)
    }

    private func sample(_ bytes: Int64) -> YtDlpProgressSample {
        sample(.materializing, .downloading, .video, bytes)
    }

    private func sample(_ phase: TransferPhase, _ status: YtDlpProgressStatus, _ component: YtDlpProgressComponent, _ bytes: Int64) -> YtDlpProgressSample {
        YtDlpProgressSample(status: status, component: component, phase: phase, message: "safe", progress: DownloadProgress(bytesWritten: bytes, totalBytes: 100, phase: phase))
    }

    private func consumer(for channel: YtDlpProgressEventChannel) -> Task<Result<YtDlpProgressSample?, Error>, Never> {
        Task {
            do { return .success(try await channel.next()) }
            catch { return .failure(error) }
        }
    }

    private func waitForWaiter(_ channel: YtDlpProgressEventChannel, file: StaticString = #filePath, line: UInt = #line) async {
        let registered = await channel.waitForWaiterRegistrationForTesting()
        XCTAssertTrue(registered, file: file, line: line)
    }
}

private func XCTAssertThrowsChannelError<T>(_ expression: @autoclosure () async throws -> T, _ expected: YtDlpProgressEventChannelError, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? YtDlpProgressEventChannelError, expected, file: file, line: line)
    }
}

private func XCTAssertChannelError(_ result: Result<YtDlpProgressSample?, Error>, _ expected: YtDlpProgressEventChannelError, file: StaticString = #filePath, line: UInt = #line) {
    switch result {
    case .success:
        XCTFail("Expected \(expected)", file: file, line: line)
    case .failure(let error):
        XCTAssertEqual(error as? YtDlpProgressEventChannelError, expected, file: file, line: line)
    }
}
