import Foundation
import LustreAgent
import LustreCore
import XCTest

final class ParallelRangeEndToEndTests: XCTestCase {
    func testParallelRangeDownloadReassemblesFile() async throws {
        setenv("LUSTRE_TEST_SKIP_SAFETY", "1", 1)
        defer { unsetenv("LUSTRE_TEST_SKIP_SAFETY") }
        try await TestServer.withServer { port, baseURL in
            try FileManager.default.createDirectory(at: LoopbackTestServer.tmpDirectory, withIntermediateDirectories: true)
            let data = Data((0..<128 * 1024).map { UInt8($0 & 0xFF) })
            try data.write(to: LoopbackTestServer.tmpDirectory.appending(path: "source.bin"))
            let server = LoopbackTestServer(port: port, sourcePath: LoopbackTestServer.tmpDirectory.appending(path: "source.bin"))
            try await server.start()
            defer { Task { await server.stop() } }
            let jobID = UUID()
            let downloadDirectory = LoopbackTestServer.tmpDirectory.appending(path: "out-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            let destination = downloadDirectory.appending(path: "video.mp4")
            let capturedBox = CapturedBytesBox()
            let request = ParallelRangeRequest(
                jobID: jobID,
                sourcePageURL: URL(string: "https://example.com/source")!,
                title: "Example",
                mediaURL: baseURL,
                headers: [:],
                destinationDirectory: downloadDirectory,
                destinationFilename: destination,
                maxStreams: 4,
                chunkSize: 16 * 1024,
                resumeState: nil,
                onProgress: { progress in
                    await capturedBox.append(progress.bytesWritten)
                },
                onWorkerEvent: { _ in }
            )
            let result = try await ParallelRangeDownloader.download(request)
            let assembled = try Data(contentsOf: result.destination)
            XCTAssertEqual(assembled, data)
            let captured = await capturedBox.snapshot()
            XCTAssertGreaterThan(captured.count, 1)
        }
    }

    func testRemoveJobInvokesPartialCleanup() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appending(path: "agent-service-resume-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = try AgentService(databaseURL: databaseURL, automaticallyStartsDownloads: false)
        let job = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://example.com/video")!))
        let directory = ParallelRangeDownloader.partialDirectory(for: job.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appending(path: "sentinel.part")
        try Data().write(to: sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        try await service.removeJob(id: job.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

enum TestServer {
    static let tmpDirectory = FileManager.default.temporaryDirectory.appending(path: "parallel-range-test-\(UUID().uuidString)", directoryHint: .isDirectory)

    static func withServer(_ body: (UInt16, URL) async throws -> Void) async throws {
        let port: UInt16 = 37845 + UInt16.random(in: 0...200)
        let url = URL(string: "http://127.0.0.1:\(port)/file.bin")!
        try await body(port, url)
    }
}

actor LoopbackTestServer {
    static let tmpDirectory = FileManager.default.temporaryDirectory.appending(path: "parallel-range-test-\(UUID().uuidString)", directoryHint: .isDirectory)

    private let port: UInt16
    private let sourcePath: URL
    private var listener: FileHandle?
    init(port: UInt16, sourcePath: URL) {
        self.port = port
        self.sourcePath = sourcePath
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "TestServer", code: 1) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else { throw NSError(domain: "TestServer", code: 2) }
        guard listen(fd, 16) >= 0 else { throw NSError(domain: "TestServer", code: 3) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        self.listener = handle
        Task { await self.acceptLoop() }
    }

    func stop() {
        if let handle = listener {
            close(handle.fileDescriptor)
            listener = nil
        }
    }

    private func acceptLoop() async {
        guard let handle = listener else { return }
        while true {
            let clientFD = accept(handle.fileDescriptor, nil, nil)
            if clientFD < 0 { return }
            let sourcePath = self.sourcePath
            Task.detached { LoopbackTestServer.serveClient(clientFD, sourcePath: sourcePath) }
        }
    }

    private static func serveClient(_ fd: Int32, sourcePath: URL) {
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let headerRead = read(fd, &buffer, 4096)
        guard headerRead > 0 else { return }
        let request = String(decoding: buffer[0..<Int(headerRead)], as: UTF8.self)
        let rangeLine = request.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("range:") })
        let range = rangeLine.flatMap { LoopbackTestServer.parseRange(String($0)) }
        let data: Data
        do {
            data = try Data(contentsOf: sourcePath)
        } catch {
            return
        }
        let total = data.count
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? (total - 1)
        let status = range == nil ? "200 OK" : "206 Partial Content"
        let body = data.subdata(in: start..<min(end + 1, total))
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
    }

    private static func parseRange(_ header: String) -> ClosedRange<Int>? {
        let value = header.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let body = value.hasPrefix("bytes=") ? String(value.dropFirst("bytes=".count)) : value
        let parts = body.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? nil : Int(parts[1])
        return start...(end ?? start)
    }
}

actor CapturedBytesBox {
    private var storage: [Int64] = []
    func append(_ value: Int64) { storage.append(value) }
    func snapshot() -> [Int64] { storage }
}
