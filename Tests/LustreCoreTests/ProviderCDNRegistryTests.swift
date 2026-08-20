import Foundation
import LustreAgent
import LustreCore
import XCTest

final class ProviderCDNRegistryTests: XCTestCase {
    func testPersistsBoundedDeduplicatedObservationsWithoutTrustingHosts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "lustre-cdn-registry-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "observations.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamps = LockedDates([
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20),
            Date(timeIntervalSince1970: 30)
        ])
        let registry = ProviderCDNRegistry(fileURL: file, maximumEntries: 2, now: timestamps.next)

        await registry.observe(url: URL(string: "https://s1.bigcdn.cc/pubs/a/1080.mp4")!, provider: .hqPorner, probeSucceeded: nil)
        await registry.observe(url: URL(string: "https://s1.bigcdn.cc/pubs/b/720.mp4")!, provider: .hqPorner, probeSucceeded: false)
        await registry.observe(url: URL(string: "https://future-cdn.example/media.mp4")!, provider: .hqPorner, probeSucceeded: true)

        let observations = await registry.all()
        XCTAssertEqual(observations.map(\.host), ["future-cdn.example", "s1.bigcdn.cc"])
        XCTAssertEqual(observations[1].discoveryCount, 2)
        XCTAssertEqual(observations[1].failedProbeCount, 1)
        XCTAssertEqual(observations[1].successfulProbeCount, 0)

        let reloaded = ProviderCDNRegistry(fileURL: file, maximumEntries: 2)
        let reloadedObservations = await reloaded.all()
        XCTAssertEqual(reloadedObservations, observations)
    }

    func testHQPornerTransferRefreshesDeadGeneratedCDNUntilAValidatedCandidateAppears() async throws {
        actor State {
            var embedFetches = 0
            var probes: [URL] = []

            func nextEmbed() -> Int {
                embedFetches += 1
                return embedFetches
            }

            func probe(_ quality: ResolvedQuality) -> Bool {
                probes.append(quality.url)
                return quality.url.host == "s2.bigcdn.cc"
            }

            func snapshot() -> (Int, [URL]) {
                (embedFetches, probes)
            }
        }

        let state = State()
        let source = URL(string: "https://hqporner.com/hdporn/127495-weekend_plans.html")!
        let embed = URL(string: "https://mydaddy.cc/video/fixture/")!
        let resolver = StaticProviderResolver(fetch: { url, _ in
            if url == source {
                return HTTPPage(body: #"<title>Weekend Plans | HQPorner</title><iframe src="//mydaddy.cc/video/fixture/"></iframe>"#, finalURL: source, statusCode: 200)
            }
            XCTAssertEqual(url, embed)
            let attempt = await state.nextEmbed()
            return HTTPPage(
                body: #"<source src="//s\#(attempt).bigcdn.cc/pubs/generated/1080.mp4" title="1080p Full HD">"#,
                finalURL: embed,
                statusCode: 200
            )
        }, randomSuffix: { "unused" }, nowMilliseconds: { "0" })
        let root = FileManager.default.temporaryDirectory.appending(path: "lustre-hq-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        let database = root.appending(path: "jobs.sqlite3")
        let downloads = root.appending(path: "downloads", directoryHint: .isDirectory)
        let registry = ProviderCDNRegistry(fileURL: root.appending(path: "cdn.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: downloads,
            automaticallyStartsDownloads: false,
            progressDownloader: { _, quality, directory, _ in
                XCTAssertEqual(quality.url.host, "s2.bigcdn.cc")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appending(path: "Weekend Plans.mp4")
                try Data(repeating: 1, count: 1_024).write(to: output)
                return output
            },
            providerCDNRegistry: registry,
            mediaProbe: { quality in await state.probe(quality) }
        )

        let job = try await service.createJob(CreateJobRequest(sourcePageURL: source, preferredQualityLabel: "1080p Full HD"))
        await service.processQueuedJob(id: job.id)

        let stored = try await service.job(id: job.id)
        let completed = try XCTUnwrap(stored)
        XCTAssertEqual(completed.status, .completed)
        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.0, 2)
        XCTAssertEqual(snapshot.1.map(\.host), ["s1.bigcdn.cc", "s2.bigcdn.cc"])
        let observations = await registry.all()
        XCTAssertEqual(observations.first(where: { $0.host == "s1.bigcdn.cc" })?.failedProbeCount, 1)
        XCTAssertEqual(observations.first(where: { $0.host == "s2.bigcdn.cc" })?.successfulProbeCount, 1)
    }
}

private final class LockedDates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(_ values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? .now : values.removeFirst()
    }
}
