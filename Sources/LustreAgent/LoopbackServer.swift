import Foundation
import LustreCore
import Network

public final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let service: AgentService
    private let token: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: AgentService, token: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: AgentPaths.loopbackPort)!)
        self.listener = try NWListener(using: parameters)
        self.service = service
        self.token = token
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    public func cancel() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        HTTPConnection(connection: connection) { [weak self] request in
            guard let self else { return .text(status: 503, "Agent unavailable.") }
            return await self.route(request)
        }.start()
    }

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == "/" {
            return .html(WebPanel.index)
        }
        if request.method == "GET", request.path == "/health" {
            return json(status: 200, value: await service.health())
        }
        guard request.path.hasPrefix("/v1/") else { return .text(status: 404, "Not found.") }
        guard request.headers["authorization"] == "Bearer \(token)" else {
            return json(status: 401, value: ErrorResponse(error: "Authorization required."))
        }

        do {
            if request.method == "GET", request.path == "/v1/jobs" {
                return json(status: 200, value: try await service.allJobs())
            }
            if request.method == "GET", request.path == "/v1/destinations" {
                return json(status: 200, value: await service.allRemoteDestinations())
            }
            if request.method == "POST", request.path == "/v1/destinations/webdav" {
                let input = try decoder.decode(WebDAVDestinationRequest.self, from: request.body)
                return json(status: 201, value: try await service.saveWebDAVDestination(input))
            }
            if request.method == "POST", request.path.hasPrefix("/v1/destinations/"), request.path.hasSuffix("/test") {
                let segments = request.path.split(separator: "/")
                guard segments.count == 4, let id = UUID(uuidString: String(segments[2])) else {
                    return json(status: 400, value: ErrorResponse(error: "Invalid destination id."))
                }
                return json(status: 200, value: try await service.testRemoteDestination(id: id))
            }
            if request.method == "DELETE", request.path.hasPrefix("/v1/destinations/") {
                let segments = request.path.split(separator: "/")
                guard segments.count == 3, let id = UUID(uuidString: String(segments[2])) else {
                    return json(status: 400, value: ErrorResponse(error: "Invalid destination id."))
                }
                try await service.removeRemoteDestination(id: id)
                return json(status: 200, value: ["status": "removed"])
            }
            if request.method == "POST", request.path == "/v1/extract" {
                let input = try decoder.decode(ExtractRequest.self, from: request.body)
                return json(status: 200, value: try await service.extract(url: input.url))
            }
            if request.method == "POST", request.path == "/v1/jobs" {
                let input = try decoder.decode(CreateJobRequest.self, from: request.body)
                return json(status: 201, value: try await service.createJob(input))
            }
            if request.method == "POST", request.path == "/v1/folders/select" {
                return json(status: 200, value: FolderSelection(path: try await service.selectDownloadFolder()))
            }
            if request.method == "POST", request.path.hasPrefix("/v1/jobs/"), request.path.hasSuffix("/action") {
                let segments = request.path.split(separator: "/")
                guard segments.count == 4, let id = UUID(uuidString: String(segments[2])) else {
                    return json(status: 400, value: ErrorResponse(error: "Invalid job id."))
                }
                let input = try decoder.decode(ActionRequest.self, from: request.body)
                return json(status: 200, value: try await service.apply(input.action, to: id))
            }
            return .text(status: 404, "Not found.")
        } catch {
            return json(status: 400, value: ErrorResponse(error: error.localizedDescription))
        }
    }

    private func json<T: Encodable>(status: Int, value: T) -> HTTPResponse {
        do {
            return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: try encoder.encode(value))
        } catch {
            return .text(status: 500, "Response encoding failed.")
        }
    }
}

private struct ExtractRequest: Decodable {
    let url: URL
}

private struct ActionRequest: Decodable {
    let action: JobAction
}

private struct FolderSelection: Encodable {
    let path: String
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func text(status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(body.utf8))
    }

    static func html(_ body: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(body.utf8))
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var buffer = Data()
    private var selfRetain: HTTPConnection?

    init(connection: NWConnection, handler: @escaping (HTTPRequest) async -> HTTPResponse) {
        self.connection = connection
        self.handler = handler
    }

    func start() {
        selfRetain = self
        connection.start(queue: .global(qos: .userInitiated))
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let request = self.parseRequest() {
                Task {
                    self.send(await self.handler(request))
                }
            } else if complete || error != nil {
                self.send(.text(status: 400, "Malformed request."))
            } else {
                self.receive()
            }
        }
    }

    private func parseRequest() -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }
        guard let header = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                headers[String(pair[0]).lowercased()] = String(pair[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        guard buffer.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func send(_ response: HTTPResponse) {
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error", 503: "Service Unavailable"][response.status] ?? "OK"
        var header = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { header += "\(name): \(value)\r\n" }
        header += "\r\n"
        connection.send(content: Data(header.utf8) + response.body, completion: .contentProcessed { [weak self, connection] _ in
            self?.selfRetain = nil
            connection.cancel()
        })
    }
}
