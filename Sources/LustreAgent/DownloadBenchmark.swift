import Foundation

public struct DownloadBenchmarkReport: Codable, Sendable {
    public let url: String
    public let concurrency: Int
    public let trials: Int
    public let meanThroughputMBps: Double
    public let p95ThroughputMBps: Double
    public let meanPerTickWriteMillis: Double
    public let httpMaximumConnectionsPerHost: Int
    public let samples: [TrialSample]

    public struct TrialSample: Codable, Sendable {
        public let durationMillis: Double
        public let bytesTransferred: Int64
        public let throughputMBps: Double
        public let perTickWriteMillis: Double
    }
}

public enum DownloadBenchmark {
    public static func run(url: URL, concurrency: Int, trials: Int) async throws -> DownloadBenchmarkReport {
        let limit = max(1, min(concurrency, 8))
        var samples: [DownloadBenchmarkReport.TrialSample] = []
        for _ in 0..<max(1, trials) {
            let trial = try await runTrial(url: url, concurrency: limit)
            samples.append(trial)
        }
        let throughputs = samples.map(\.throughputMBps)
        let mean = throughputs.isEmpty ? 0 : throughputs.reduce(0, +) / Double(throughputs.count)
        let sorted = throughputs.sorted()
        let p95Index = sorted.isEmpty ? 0 : Int(Double(sorted.count - 1) * 0.95)
        let p95 = sorted.isEmpty ? 0 : sorted[p95Index]
        let meanPerTick = samples.isEmpty ? 0 : samples.map(\.perTickWriteMillis).reduce(0, +) / Double(samples.count)
        return DownloadBenchmarkReport(
            url: url.absoluteString,
            concurrency: limit,
            trials: max(1, trials),
            meanThroughputMBps: mean,
            p95ThroughputMBps: p95,
            meanPerTickWriteMillis: meanPerTick,
            httpMaximumConnectionsPerHost: 6,
            samples: samples
        )
    }

    private static func runTrial(url: URL, concurrency: Int) async throws -> DownloadBenchmarkReport.TrialSample {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = max(concurrency, 4)
        let delegate = AgentDownloadRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let started = Date()
        let (bytes, _) = try await session.bytes(for: request)
        var totalWritten: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var tickDurations: [Double] = []
        var lastTick = Date()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                let tickBegin = Date()
                totalWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                _ = lastTick
                lastTick = Date()
                tickDurations.append(lastTick.timeIntervalSince(tickBegin) * 1000)
            }
        }
        if !buffer.isEmpty {
            totalWritten += Int64(buffer.count)
        }
        let duration = Date().timeIntervalSince(started)
        let meanPerTick = tickDurations.isEmpty ? 0 : tickDurations.reduce(0, +) / Double(tickDurations.count)
        let mbps = duration > 0 ? Double(totalWritten) / duration / 1_048_576.0 : 0
        return DownloadBenchmarkReport.TrialSample(
            durationMillis: duration * 1000,
            bytesTransferred: totalWritten,
            throughputMBps: mbps,
            perTickWriteMillis: meanPerTick
        )
    }
}
