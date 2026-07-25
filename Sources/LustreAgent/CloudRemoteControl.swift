import Foundation
import LustreCore

struct CloudRemoteCommand: Decodable {
    let id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Decodable {
        let url: URL?
        let preferredQualityLabel: String?
    }
}

struct CloudRemoteCommandAck: Codable {
    let id: UUID
    let status: String
    let jobID: UUID?
}

struct CloudRemoteJobStatus: Codable {
    let id: UUID
    let status: String
    let progress: Double?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let phase: String?
    let attempts: Int

    init(_ job: DownloadJob) {
        id = job.id; status = job.status.rawValue; progress = job.progress; downloadedBytes = job.downloadedBytes; totalBytes = job.totalBytes; phase = job.transferPhase?.rawValue; attempts = job.attempts
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
            guard let url = command.payload.url else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil); break }
            do {
                let job = try await service.createJob(CreateJobRequest(sourcePageURL: url, preferredQualityLabel: command.payload.preferredQualityLabel))
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: job.id)
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil)
            }
        default:
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil)
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
}
