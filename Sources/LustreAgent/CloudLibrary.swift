import Foundation
import LustreCore

struct CloudLibraryStage: Codable, Equatable, Sendable {
    let destination: String
    let state: String
    let updatedAt: Date
}

struct CloudLibraryItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: String
    let sourcePageURL: URL
    let title: String
    let provider: String
    let thumbnailURL: URL?
    let timestamp: Date
    let tags: [String]
    let collection: String?
    let favorite: Bool
    let duplicateKey: String
    let mediaKind: String
    let pipeline: [CloudLibraryStage]
}

struct CloudLibrarySnapshot: Codable, Equatable, Sendable {
    let revision: Int64
    let page: Int
    let hasMore: Bool
    let items: [CloudLibraryItem]
    let verification: CloudLibraryVerification?
}

struct CloudLibraryVerification: Codable, Equatable, Sendable {
    let itemID: UUID
    let states: [CloudLibraryStage]
    let message: String
}

private struct CloudLibraryMetadata: Codable {
    var revision: Int64
    var signature: String
    var organization: [UUID: Organization]
    var removed: Set<UUID>

    struct Organization: Codable {
        var tags: [String]
        var collection: String?
        var favorite: Bool
    }

    static let empty = CloudLibraryMetadata(revision: 0, signature: "", organization: [:], removed: [])
}

actor CloudLibraryStore {
    private let stateURL: URL
    private var metadata: CloudLibraryMetadata

    init(stateURL: URL = AgentPaths.applicationSupport.appending(path: "cloud-library.json")) {
        self.stateURL = stateURL
        metadata = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(CloudLibraryMetadata.self, from: $0) } ?? .empty
    }

    func snapshot(jobs: [DownloadJob], page: Int, verification: CloudLibraryVerification? = nil) -> CloudLibrarySnapshot {
        let allItems = projectedItems(jobs: jobs)
        refreshRevision(for: allItems)
        let start = min((page - 1) * 100, allItems.count)
        let end = min(start + 100, allItems.count)
        return CloudLibrarySnapshot(
            revision: metadata.revision,
            page: page,
            hasMore: end < allItems.count,
            items: Array(allItems[start..<end]),
            verification: verification
        )
    }

    func update(id: UUID, tags: [String], collection: String?, favorite: Bool?, jobs: [DownloadJob]) throws -> CloudLibrarySnapshot {
        guard projectedItems(jobs: jobs).contains(where: { $0.id == id }) else { throw CloudLibraryError.itemNotFound }
        let normalizedTags = Array(Set(tags.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48)) }.filter { !$0.isEmpty })).sorted().prefix(20).map { $0 }
        let normalizedCollection = collection.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
        var organization = metadata.organization[id] ?? .init(tags: [], collection: nil, favorite: false)
        organization.tags = normalizedTags
        organization.collection = normalizedCollection
        if let favorite { organization.favorite = favorite }
        metadata.organization[id] = organization
        bumpRevision()
        return snapshot(jobs: jobs, page: 1)
    }

    func remove(id: UUID, jobs: [DownloadJob]) throws -> CloudLibrarySnapshot {
        guard projectedItems(jobs: jobs).contains(where: { $0.id == id }) else { throw CloudLibraryError.itemNotFound }
        metadata.removed.insert(id)
        metadata.organization.removeValue(forKey: id)
        bumpRevision()
        return snapshot(jobs: jobs, page: 1)
    }

    func verify(id: UUID, jobs: [DownloadJob]) throws -> CloudLibrarySnapshot {
        guard let item = projectedItems(jobs: jobs).first(where: { $0.id == id }) else { throw CloudLibraryError.itemNotFound }
        let states = item.pipeline.map {
            CloudLibraryStage(destination: $0.destination, state: $0.state == "succeeded" ? "confirmed" : $0.state, updatedAt: .now)
        }
        let confirmed = states.filter { $0.state == "confirmed" }.count
        let message = confirmed > 0 ? "Confirmed \(confirmed) completed destination record\(confirmed == 1 ? "" : "s") on the paired Mac." : "No completed destination record is available to verify."
        return snapshot(jobs: jobs, page: 1, verification: CloudLibraryVerification(itemID: id, states: states, message: message))
    }

    private func projectedItems(jobs: [DownloadJob]) -> [CloudLibraryItem] {
        let grouped = Dictionary(grouping: jobs, by: { normalizedURL($0.sourcePageURL) })
        return grouped.values.compactMap { related -> CloudLibraryItem? in
            guard let newest = related.max(by: { $0.updatedAt < $1.updatedAt }),
                  related.contains(where: { $0.status == .completed }),
                  newest.sourcePageURL.scheme?.lowercased() == "https",
                  newest.sourcePageURL.user == nil,
                  newest.sourcePageURL.password == nil,
                  URLSafetyPolicy.isAllowed(newest.sourcePageURL),
                  !metadata.removed.contains(newest.id)
            else { return nil }
            let organization = metadata.organization[newest.id]
            let pipeline = related.reduce(into: [String: CloudLibraryStage]()) { result, job in
                let destination = safeDestination(job.destination)
                let state = job.status == .completed ? "succeeded" : job.status == .running || job.status == .queued ? "running" : job.status.rawValue
                if result[destination]?.updatedAt ?? .distantPast < job.updatedAt {
                    result[destination] = CloudLibraryStage(destination: destination, state: state, updatedAt: job.updatedAt)
                }
            }.values.sorted { $0.destination < $1.destination }
            let title = safeTitle(newest)
            let provider = String((newest.sourcePageURL.host ?? "Web").prefix(64))
            return CloudLibraryItem(
                id: newest.id,
                kind: newest.destination == "local" ? "video" : "upload",
                sourcePageURL: newest.sourcePageURL,
                title: title,
                provider: provider,
                thumbnailURL: nil,
                timestamp: newest.updatedAt,
                tags: organization?.tags ?? [],
                collection: organization?.collection,
                favorite: organization?.favorite ?? false,
                duplicateKey: "\(provider.lowercased())|\(title.lowercased())",
                mediaKind: newest.preferredQualityLabel?.lowercased().contains("audio") == true ? "audio" : "video",
                pipeline: pipeline
            )
        }.sorted { $0.timestamp > $1.timestamp }
    }

    private func safeTitle(_ job: DownloadJob) -> String {
        let component = job.sourcePageURL.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        return String((component.isEmpty ? job.sourcePageURL.host ?? "Downloaded video" : component.replacingOccurrences(of: "-", with: " ")).prefix(512))
    }

    private func normalizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString.lowercased() ?? url.absoluteString.lowercased()
    }

    private func safeDestination(_ raw: String) -> String {
        if raw == "local" { return "Local Downloads" }
        if raw.hasPrefix("gdrive:") { return "Google Drive" }
        if raw.hasPrefix("webdav:") { return "WebDAV" }
        if raw.lowercased().contains("mega") { return "Mega" }
        return "Remote"
    }

    private func refreshRevision(for items: [CloudLibraryItem]) {
        let signature = items.map { "\($0.id.uuidString)|\($0.timestamp.timeIntervalSince1970)|\($0.tags.joined(separator: ","))|\($0.collection ?? "")|\($0.favorite)" }.joined(separator: "\n")
        guard signature != metadata.signature else { return }
        metadata.signature = signature
        bumpRevision()
    }

    private func bumpRevision() {
        metadata.revision = max(metadata.revision + 1, Int64(Date().timeIntervalSince1970 * 1_000))
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(metadata) { try? data.write(to: stateURL, options: .atomic) }
    }
}

enum CloudLibraryError: Error {
    case itemNotFound
}
