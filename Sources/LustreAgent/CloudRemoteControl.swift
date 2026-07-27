import Foundation
import LustreCore

struct CloudRemoteCommand: Decodable {
    let id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Decodable {
        let url: URL?
        let preferredQualityLabel: String?
        let destination: String?
        let deliveryProtocol: String?
        let jobID: UUID?
        let action: JobAction?
        let siteID: String?
        let query: String?
        let page: Int?
        let name: String?
        let baseURL: URL?
        let username: String?
        let remotePath: String?
        let allowInvalidCertificate: String?
    }
}

struct CloudRemoteCommandAck: Codable {
    let id: UUID
    let status: String
    let jobID: UUID?
    let result: CloudRemoteResult?
    let code: String?

    init(id: UUID, status: String, jobID: UUID?, result: CloudRemoteResult?, code: String? = nil) {
        self.id = id
        self.status = status
        self.jobID = jobID
        self.result = result
        self.code = code
    }
}

struct CloudRemoteResult: Codable {
    let kind: String
    let sites: [FeedSite]?
    let page: FeedPage?
    let destinations: [CloudRemoteDestination]?
}

struct CloudRemoteDestination: Codable, Equatable {
    let id: UUID
    let name: String
    let baseURL: URL
    let username: String
    let remotePath: String
    let allowInvalidCertificate: Bool

    init?(_ profile: WebDAVDestinationProfile) {
        guard profile.name.count <= 128,
              profile.username.count <= 256,
              profile.remotePath.count <= 1_024,
              profile.baseURL.absoluteString.count <= 2_048,
              profile.baseURL.scheme?.lowercased() == "https",
              profile.baseURL.host?.isEmpty == false,
              profile.baseURL.user == nil,
              profile.baseURL.password == nil,
              profile.baseURL.query == nil,
              profile.baseURL.fragment == nil,
              profile.remotePath.hasPrefix("/"),
              !profile.remotePath.split(separator: "/", omittingEmptySubsequences: true).contains("."),
              !profile.remotePath.split(separator: "/", omittingEmptySubsequences: true).contains("..")
        else { return nil }
        id = profile.id
        name = profile.name
        baseURL = profile.baseURL
        username = profile.username
        remotePath = profile.remotePath
        allowInvalidCertificate = profile.allowInvalidCertificate
    }
}

struct CloudRemoteJobStatus: Codable {
    let id: UUID
    let sourcePageURL: URL
    let displayName: String
    let preferredQualityLabel: String?
    let status: String
    let progress: Double?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let phase: String?
    let attempts: Int
    let updatedAt: Date

    init(_ job: DownloadJob) {
        id = job.id; sourcePageURL = job.sourcePageURL; displayName = job.sourcePageURL.deletingLastPathComponent().lastPathComponent.isEmpty ? "Download" : job.sourcePageURL.lastPathComponent.removingPercentEncoding ?? job.sourcePageURL.lastPathComponent; preferredQualityLabel = job.preferredQualityLabel; status = job.status.rawValue; progress = job.progress; downloadedBytes = job.downloadedBytes; totalBytes = job.totalBytes; phase = job.transferPhase?.rawValue; attempts = job.attempts; updatedAt = job.updatedAt
    }
}

struct CloudHeartbeat: Encodable {
    let version = 1
    let type = "heartbeat"
    let sequence: Int
    let sentAt: String
    let agentVersion: String
    let correlationID: String
    let commandAcks: [CloudRemoteCommandAck]
    let jobs: [CloudRemoteJobStatus]
}

struct CloudHeartbeatResponse: Decodable {
    let version: Int
    let type: String
    let sequence: Int?
    let reason: String?
    let command: CloudRemoteCommand?
    let acknowledgedCommandAcks: [CloudRemoteCommandAck]?
}

struct CloudGatewayHelloResponse: Decodable {
    let version: Int
    let type: String
    let capabilities: [String]?
}

struct CloudCommandDelivery: Decodable {
    let version: Int
    let type: String
    let sequence: Int
    let correlationID: String
    let acknowledgedCommandAckIDs: [UUID]
    let command: CloudRemoteCommand?
}

actor CloudRemoteControl {
    static let maximumFeedPageAcknowledgementBytes = 65_536
    static let maximumDestinationsAcknowledgementBytes = 32_768
    static let maximumDestinations = 64
    private let service: AgentService
    private var acknowledgements: [CloudRemoteCommandAck] = []
    private var completed: [UUID: CloudRemoteCommandAck]
    private let receiptsURL = AgentPaths.applicationSupport.appending(path: "cloud-command-receipts.json")

    init(service: AgentService) {
        self.service = service
        if let receipts = try? JSONDecoder.cloud.decode([CloudRemoteCommandAck].self, from: Data(contentsOf: receiptsURL)) {
            completed = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0) })
        } else if let ids = try? JSONDecoder.cloud.decode([UUID].self, from: Data(contentsOf: receiptsURL)) {
            completed = Dictionary(uniqueKeysWithValues: ids.map { ($0, CloudRemoteCommandAck(id: $0, status: "completed", jobID: nil, result: nil)) })
        } else {
            completed = [:]
        }
    }

    func heartbeatPayload() async -> (acks: [CloudRemoteCommandAck], jobs: [CloudRemoteJobStatus]) {
        let jobs = ((try? await service.allJobs()) ?? []).prefix(50).map(CloudRemoteJobStatus.init)
        return (acknowledgements, jobs)
    }

    func handle(_ command: CloudRemoteCommand?) async -> Bool {
        guard let command else { return false }
        if let acknowledgement = completed[command.id] {
            if command.kind == "queue_url", acknowledgement.status == "completed" {
                guard let url = command.payload.url,
                      command.payload.deliveryProtocol == "gateway-v1",
                      command.payload.preferredQualityLabel == nil,
                      let existing = try? await service.job(id: command.id),
                      let destination = try? await service.normalizedCloudDestination(command.payload.destination),
                      existing.sourcePageURL == url,
                      existing.destination == destination
                else {
                    enqueue(CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil))
                    return true
                }
            }
            enqueue(acknowledgement)
            return true
        }
        let acknowledgement: CloudRemoteCommandAck
        switch command.kind {
        case "queue_url":
            guard let url = command.payload.url,
                  command.payload.deliveryProtocol == "gateway-v1",
                  command.payload.preferredQualityLabel == nil
            else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do {
                if let existing = try await service.job(id: command.id) {
                    let destination = try await service.normalizedCloudDestination(command.payload.destination)
                    guard existing.sourcePageURL == url, existing.destination == destination else {
                        acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil)
                        break
                    }
                    acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: existing.id, result: nil)
                    break
                }
                let job = try await service.createJob(CreateJobRequest(id: command.id, sourcePageURL: url, destination: command.payload.destination))
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: job.id, result: nil)
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil)
            }
        case "job_action":
            guard let jobID = command.payload.jobID, let action = command.payload.action else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            guard action == .pause || action == .resume || action == .cancel || action == .retry else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do {
                _ = try await service.apply(action, to: jobID)
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: jobID, result: nil)
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil)
            }
        case "feed_sites":
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "feed_sites", sites: await service.feedSites(), page: nil, destinations: nil))
        case "feed_page":
            guard let rawSite = command.payload.siteID, let site = FeedSiteID(rawValue: rawSite), let page = command.payload.page, page > 0 else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do { acknowledgement = Self.boundedFeedPageAcknowledgement(id: command.id, page: try await service.feedPage(site: site, query: command.payload.query, page: page)) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: Self.feedFailureCode(error)) }
        case "destinations_list":
            acknowledgement = Self.boundedDestinationsAcknowledgement(id: command.id, profiles: await service.allRemoteDestinations())
        case "webdav_add":
            guard let name = command.payload.name, let baseURL = command.payload.baseURL, let username = command.payload.username, let remotePath = command.payload.remotePath, let password = try? Self.promptForWebDAVPassword(name: name) else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do { _ = try await service.saveWebDAVDestination(WebDAVDestinationRequest(name: name, baseURL: baseURL, username: username, password: password, remotePath: remotePath, allowInvalidCertificate: command.payload.allowInvalidCertificate == "true")); acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: nil) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil) }
        default:
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil)
        }
        completed[command.id] = acknowledgement
        try? AgentPaths.prepare()
        try? JSONEncoder.cloud.encode(Array(completed.values)).write(to: receiptsURL, options: .atomic)
        enqueue(acknowledgement)
        return true
    }

    func acknowledgedByCloud(_ acknowledgements: [CloudRemoteCommandAck]) {
        let ids = Set(acknowledgements.map(\.id))
        self.acknowledgements.removeAll { ids.contains($0.id) }
    }

    func acknowledgedByCloud(ids: [UUID]) {
        let confirmed = Set(ids)
        acknowledgements.removeAll { confirmed.contains($0.id) }
    }

    static func boundedFeedPageAcknowledgement(id: UUID, page: FeedPage) -> CloudRemoteCommandAck {
        let completed = CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "feed_page", sites: nil, page: page, destinations: nil))
        guard let encoded = try? JSONEncoder.cloud.encode(completed), encoded.count <= maximumFeedPageAcknowledgementBytes else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil, code: "result_too_large")
        }
        return completed
    }

    static func boundedDestinationsAcknowledgement(id: UUID, profiles: [WebDAVDestinationProfile]) -> CloudRemoteCommandAck {
        guard profiles.count <= maximumDestinations else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        }
        let orderedProfiles = profiles.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
        let destinations = orderedProfiles.compactMap(CloudRemoteDestination.init)
        guard destinations.count == orderedProfiles.count else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        }
        let completed = CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "destinations_list", sites: nil, page: nil, destinations: destinations))
        guard let encoded = try? JSONEncoder.cloud.encode(completed), encoded.count <= maximumDestinationsAcknowledgementBytes else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        }
        return completed
    }

    private func enqueue(_ acknowledgement: CloudRemoteCommandAck) {
        Self.appendAcknowledgement(acknowledgement, to: &acknowledgements)
    }

    private static func feedFailureCode(_ error: Error) -> String {
        if let feedError = error as? FeedError {
            switch feedError {
            case .challengeRequired: return "provider_verification_required"
            case .authenticationRequired, .authenticationUnavailable: return "authentication_required"
            case .network: return "provider_http_error"
            case .missingStructuredData, .invalidStructuredData: return "provider_changed"
            case .invalidPage, .invalidQuery, .unsupportedSite: return "invalid_request"
            }
        }
        if error is URLError { return "provider_unreachable" }
        return "provider_changed"
    }

    static func appendAcknowledgement(_ acknowledgement: CloudRemoteCommandAck, to acknowledgements: inout [CloudRemoteCommandAck]) {
        acknowledgements.removeAll { $0.id == acknowledgement.id }
        acknowledgements.append(acknowledgement)
        if acknowledgements.count > 8 { acknowledgements.removeFirst(acknowledgements.count - 8) }
    }

    private static func promptForWebDAVPassword(name _: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", "text returned of (display dialog \"Enter the WebDAV password\" default answer \"\" with hidden answer)"]
        let output = Pipe(); process.standardOutput = output; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, let password = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else { throw RemoteDestinationError.missingCredentials }
        return password
    }
}
