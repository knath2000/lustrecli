import Foundation
import LustreCore

struct CloudRemoteCommand: Decodable {
    let id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Decodable {
        let url: URL?
        let preferredQualityLabel: String?
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
}

struct CloudRemoteResult: Codable {
    let kind: String
    let sites: [FeedSite]?
    let page: FeedPage?
}

struct CloudRemoteJobStatus: Codable {
    let id: UUID
    let displayName: String
    let preferredQualityLabel: String?
    let status: String
    let progress: Double?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let phase: String?
    let attempts: Int

    init(_ job: DownloadJob) {
        id = job.id; displayName = job.sourcePageURL.deletingLastPathComponent().lastPathComponent.isEmpty ? "Download" : job.sourcePageURL.lastPathComponent.removingPercentEncoding ?? job.sourcePageURL.lastPathComponent; preferredQualityLabel = job.preferredQualityLabel; status = job.status.rawValue; progress = job.progress; downloadedBytes = job.downloadedBytes; totalBytes = job.totalBytes; phase = job.transferPhase?.rawValue; attempts = job.attempts
    }
}

struct CloudHeartbeat: Encodable {
    let version = 1
    let type = "heartbeat"
    let sequence: Int
    let sentAt: String
    let agentVersion: String
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

actor CloudRemoteControl {
    private let service: AgentService
    private var acknowledgements: [CloudRemoteCommandAck] = []
    private var completed: Set<UUID>
    private let receiptsURL = AgentPaths.applicationSupport.appending(path: "cloud-command-receipts.json")

    init(service: AgentService) {
        self.service = service
        completed = (try? JSONDecoder.cloud.decode([UUID].self, from: Data(contentsOf: receiptsURL))).map(Set.init) ?? []
    }

    func heartbeatPayload() async -> (acks: [CloudRemoteCommandAck], jobs: [CloudRemoteJobStatus]) {
        let jobs = ((try? await service.allJobs()) ?? []).prefix(50).map(CloudRemoteJobStatus.init)
        return (acknowledgements, jobs)
    }

    func handle(_ command: CloudRemoteCommand?) async {
        guard let command, !completed.contains(command.id) else { return }
        let acknowledgement: CloudRemoteCommandAck
        switch command.kind {
        case "queue_url":
            guard let url = command.payload.url else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do {
                let job = try await service.createJob(CreateJobRequest(sourcePageURL: url, preferredQualityLabel: command.payload.preferredQualityLabel))
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
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "feed_sites", sites: await service.feedSites(), page: nil))
        case "feed_page":
            guard let rawSite = command.payload.siteID, let site = FeedSiteID(rawValue: rawSite), let page = command.payload.page else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "feed_page", sites: nil, page: try await service.feedPage(site: site, query: command.payload.query, page: page))) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil) }
        case "webdav_add":
            guard let name = command.payload.name, let baseURL = command.payload.baseURL, let username = command.payload.username, let remotePath = command.payload.remotePath, let password = try? Self.promptForWebDAVPassword(name: name) else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do { _ = try await service.saveWebDAVDestination(WebDAVDestinationRequest(name: name, baseURL: baseURL, username: username, password: password, remotePath: remotePath, allowInvalidCertificate: command.payload.allowInvalidCertificate == "true")); acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: nil) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil) }
        default:
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil)
        }
        completed.insert(command.id)
        try? AgentPaths.prepare()
        try? JSONEncoder.cloud.encode(Array(completed)).write(to: receiptsURL, options: .atomic)
        acknowledgements.append(acknowledgement)
        if acknowledgements.count > 8 { acknowledgements.removeFirst(acknowledgements.count - 8) }
    }

    func acknowledgedByCloud(_ acknowledgements: [CloudRemoteCommandAck]) {
        let ids = Set(acknowledgements.map(\.id))
        self.acknowledgements.removeAll { ids.contains($0.id) }
    }

    private static func promptForWebDAVPassword(name: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", "text returned of (display dialog \"Enter the WebDAV password for \\(name)\" default answer \"\" with hidden answer)"]
        let output = Pipe(); process.standardOutput = output; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, let password = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else { throw RemoteDestinationError.missingCredentials }
        return password
    }
}
