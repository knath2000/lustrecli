import Foundation
import LustreCore

private extension PornHubAuthError {
    var cloudCode: String {
        switch self {
        case .signedOut: "signed_out"
        case .signingIn: "signing_in"
        case .cancelled: "cancelled"
        case .expired: "expired"
        case .helperUnavailable: "auth_helper_unavailable"
        case .helperFailed: "auth_helper_failed"
        case .timeout: "auth_timeout"
        case .invalidCookieState: "invalid_session"
        case .storageUnavailable: "auth_storage_unavailable"
        }
    }
}

struct CloudRemoteCommand: Decodable {
    let id: UUID
    let kind: String
    let payload: Payload

    struct Payload: Decodable {
        let url: URL?
        let title: String?
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
        let profileID: UUID?
        let path: String?
        let urls: [URL]?
        let itemID: UUID?
        let tags: [String]?
        let collection: String?
        let favorite: Bool?

        init(url: URL?, title: String? = nil, preferredQualityLabel: String?, destination: String?, deliveryProtocol: String?, jobID: UUID?, action: JobAction?, siteID: String?, query: String?, page: Int?, name: String?, baseURL: URL?, username: String?, remotePath: String?, allowInvalidCertificate: String?, profileID: UUID? = nil, path: String? = nil, urls: [URL]? = nil, itemID: UUID? = nil, tags: [String]? = nil, collection: String? = nil, favorite: Bool? = nil) {
            self.url = url
            self.title = title
            self.preferredQualityLabel = preferredQualityLabel
            self.destination = destination
            self.deliveryProtocol = deliveryProtocol
            self.jobID = jobID
            self.action = action
            self.siteID = siteID
            self.query = query
            self.page = page
            self.name = name
            self.baseURL = baseURL
            self.username = username
            self.remotePath = remotePath
            self.allowInvalidCertificate = allowInvalidCertificate
            self.profileID = profileID
            self.path = path
            self.urls = urls
            self.itemID = itemID
            self.tags = tags
            self.collection = collection
            self.favorite = favorite
        }
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
    let pornHubAuth: CloudRemotePornHubAuthStatus?
    let googleDriveFolders: [GoogleDriveFolder]?
    let homeReadiness: CloudHomeReadiness?
    let homePreview: [CloudHomePreviewItem]?
    let playback: CloudPlaybackResolution?
    let library: CloudLibrarySnapshot?
    let localDownloadFolder: LocalDownloadFolderStatus?

    init(kind: String, sites: [FeedSite]?, page: FeedPage?, destinations: [CloudRemoteDestination]?, pornHubAuth: CloudRemotePornHubAuthStatus? = nil, googleDriveFolders: [GoogleDriveFolder]? = nil, homeReadiness: CloudHomeReadiness? = nil, homePreview: [CloudHomePreviewItem]? = nil, playback: CloudPlaybackResolution? = nil, library: CloudLibrarySnapshot? = nil, localDownloadFolder: LocalDownloadFolderStatus? = nil) {
        self.kind = kind
        self.sites = sites
        self.page = page
        self.destinations = destinations
        self.pornHubAuth = pornHubAuth
        self.googleDriveFolders = googleDriveFolders
        self.homeReadiness = homeReadiness
        self.homePreview = homePreview
        self.playback = playback
        self.library = library
        self.localDownloadFolder = localDownloadFolder
    }
}

struct CloudPlaybackQuality: Codable, Equatable {
    let label: String
    let url: URL
    let mediaKind: String
    let headers: [String: String]
}

struct CloudPlaybackResolution: Codable, Equatable {
    let sourcePageURL: URL
    let title: String?
    let provider: String
    let qualities: [CloudPlaybackQuality]

    init?(result: ExtractionResult) {
        guard let resolution = result.resolution else { return nil }
        let allowedHeaders = Set(["referer", "origin", "user-agent"])
        var seen = Set<String>()
        let qualities = resolution.qualities.compactMap { quality -> CloudPlaybackQuality? in
            guard quality.url.scheme?.lowercased() == "https",
                  quality.url.user == nil,
                  quality.url.password == nil,
                  URLSafetyPolicy.isAllowed(quality.url),
                  seen.insert(quality.url.absoluteString).inserted
            else { return nil }
            let headers = quality.headers.reduce(into: [String: String]()) { result, pair in
                guard allowedHeaders.contains(pair.key.lowercased()),
                      pair.key.count <= 32,
                      pair.value.count <= 2_048
                else { return }
                result[pair.key] = pair.value
            }
            return CloudPlaybackQuality(
                label: String(quality.label.prefix(80)),
                url: quality.url,
                mediaKind: quality.mediaKind.rawValue,
                headers: headers
            )
        }.prefix(12).map { $0 }
        guard !qualities.isEmpty else { return nil }
        sourcePageURL = result.sourcePageURL
        title = resolution.title.map { String($0.prefix(512)) }
        provider = String(resolution.provider.rawValue.prefix(64))
        self.qualities = qualities
    }
}

struct CloudHomeReadiness: Codable, Equatable {
    let ytDlp: Bool
    let ffmpeg: Bool
    let browserBridge: Bool

    static func current(fileManager: FileManager = .default) -> CloudHomeReadiness {
        let ytDlp = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/opt/local/bin/yt-dlp"]
            .contains(where: fileManager.isExecutableFile(atPath:))
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .contains(where: fileManager.isExecutableFile(atPath:))
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let nativeHosts = [
            applicationSupport.appending(path: "Google/Chrome/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json"),
            applicationSupport.appending(path: "BraveSoftware/Brave-Browser/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json"),
            applicationSupport.appending(path: "Mozilla/NativeMessagingHosts/\(BrowserCaptureConstants.nativeHostName).json")
        ]
        let extensionInstalled = fileManager.fileExists(atPath: BrowserCaptureConstants.extensionURL.path)
            || fileManager.fileExists(atPath: BrowserCaptureConstants.firefoxExtensionURL.path)
        return CloudHomeReadiness(
            ytDlp: ytDlp,
            ffmpeg: ffmpeg,
            browserBridge: extensionInstalled && nativeHosts.contains { fileManager.fileExists(atPath: $0.path) }
        )
    }
}

struct CloudHomePreviewQuality: Codable, Equatable {
    let label: String
    let mediaKind: String
}

struct CloudHomePreviewItem: Codable, Equatable {
    let sourcePageURL: URL
    let state: String
    let title: String?
    let thumbnailURL: URL?
    let provider: String?
    let qualities: [CloudHomePreviewQuality]
    let errorCode: String?

    init(result: ExtractionResult) {
        sourcePageURL = result.sourcePageURL
        let resolution = result.resolution
        title = resolution?.title.map { String($0.prefix(512)) }
        provider = resolution.map { String($0.provider.rawValue.prefix(64)) }
        if let candidate = resolution?.thumbnailURL,
           candidate.scheme?.lowercased() == "https",
           candidate.user == nil,
           candidate.password == nil,
           URLSafetyPolicy.isAllowed(candidate) {
            thumbnailURL = candidate
        } else {
            thumbnailURL = nil
        }
        var seen = Set<String>()
        qualities = (resolution?.qualities ?? []).compactMap { quality in
            let label = String(quality.label.prefix(80))
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { return nil }
            return CloudHomePreviewQuality(label: label, mediaKind: quality.mediaKind.rawValue)
        }.prefix(20).map { $0 }
        switch result.resolutionState {
        case "resolved" where !qualities.isEmpty:
            state = "resolved"
            errorCode = nil
        case "verificationRequired":
            state = "verificationRequired"
            errorCode = "provider_verification_required"
        case "pendingProviderResolver":
            state = "unsupported"
            errorCode = "provider_changed"
        default:
            state = "failed"
            errorCode = result.resolutionState == "noProviderResolved" ? "provider_changed" : "provider_unreachable"
        }
    }

    init(sourcePageURL: URL, errorCode: String) {
        self.sourcePageURL = sourcePageURL
        state = "failed"
        title = nil
        thumbnailURL = nil
        provider = nil
        qualities = []
        self.errorCode = errorCode
    }
}

struct CloudRemotePornHubAuthStatus: Codable, Equatable {
    let state: PornHubAuthState
    let lastValidatedAt: Date?
    let code: String?

    init(_ status: PornHubAuthStatus) {
        state = status.state
        lastValidatedAt = status.lastValidatedAt
        code = Self.code(for: status.message)
    }

    private static func code(for message: String?) -> String? {
        guard let message else { return nil }
        return PornHubAuthError.allCases.first { $0.errorDescription == message }?.cloudCode
    }
}

struct CloudRemoteDestination: Codable, Equatable {
    let id: UUID
    let name: String
    let kind: String
    let baseURL: URL?
    let username: String?
    let remotePath: String
    let allowInvalidCertificate: Bool?
    let remoteName: String?

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
        kind = "webdav"
        baseURL = profile.baseURL
        username = profile.username
        remotePath = profile.remotePath
        allowInvalidCertificate = profile.allowInvalidCertificate
        remoteName = nil
    }

    init?(_ profile: GoogleDriveDestinationProfile) {
        guard profile.name.count <= 128,
              profile.remoteName.count <= 64,
              profile.remotePath.count <= 1_024 else { return nil }
        id = profile.id
        name = profile.name
        kind = "google_drive"
        baseURL = nil
        username = nil
        remotePath = profile.remotePath
        allowInvalidCertificate = nil
        remoteName = profile.remoteName
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
        id = job.id; sourcePageURL = job.sourcePageURL; displayName = job.title ?? (job.sourcePageURL.deletingLastPathComponent().lastPathComponent.isEmpty ? "Download" : job.sourcePageURL.lastPathComponent.removingPercentEncoding ?? job.sourcePageURL.lastPathComponent); preferredQualityLabel = job.preferredQualityLabel; status = job.status.rawValue; progress = job.progress; downloadedBytes = job.downloadedBytes; totalBytes = job.totalBytes; phase = job.transferPhase?.rawValue; attempts = job.attempts; updatedAt = job.updatedAt
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
    static let maximumFeedPageAcknowledgementBytes = 118_000
    static let maximumDestinationsAcknowledgementBytes = 32_768
    static let maximumDestinations = 64
    static let maximumHomePreviewAcknowledgementBytes = 64_000
    private let service: AgentService
    private var acknowledgements: [CloudRemoteCommandAck] = []
    private var completed: [UUID: CloudRemoteCommandAck]
    private var inFlightFeedCommands: [UUID: Task<Void, Never>] = [:]
    private var inFlightHomeCommands: [UUID: Task<Void, Never>] = [:]
    private var completionHandler: (@Sendable () async -> Void)?
    private let libraryStore = CloudLibraryStore()
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

    func setCompletionHandler(_ handler: (@Sendable () async -> Void)?) {
        completionHandler = handler
    }

    func handle(_ command: CloudRemoteCommand?) async -> Bool {
        guard let command else { return false }
        if let acknowledgement = completed[command.id] {
            if command.kind == "queue_url", acknowledgement.status == "completed" {
                guard let url = command.payload.url,
                      command.payload.deliveryProtocol == "gateway-v1",
                      let existing = try? await service.job(id: command.id),
                      let destination = try? await service.normalizedCloudDestination(command.payload.destination),
                      existing.sourcePageURL == url,
                      existing.destination == destination,
                      command.payload.title == nil || existing.title == command.payload.title,
                      existing.preferredQualityLabel == command.payload.preferredQualityLabel
                else {
                    enqueue(CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil))
                    return true
                }
            }
            enqueue(acknowledgement)
            return true
        }
        if command.kind == "extract_preview" {
            guard command.payload.deliveryProtocol == "gateway-v1",
                  let urls = command.payload.urls,
                  (1...10).contains(urls.count),
                  urls.allSatisfy({
                      $0.scheme?.lowercased() == "https"
                          && $0.user == nil
                          && $0.password == nil
                          && URLSafetyPolicy.isAllowed($0)
                  })
            else {
                complete(
                    commandID: command.id,
                    acknowledgement: CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
                )
                return true
            }
            if inFlightHomeCommands[command.id] != nil { return false }
            let service = self.service
            inFlightHomeCommands[command.id] = Task { [weak self] in
                let items = await Self.previewItems(service: service, urls: urls)
                let acknowledgement = Self.boundedHomePreviewAcknowledgement(id: command.id, items: items)
                await self?.completeAsync(commandID: command.id, acknowledgement: acknowledgement)
            }
            return false
        }
        if command.kind == "feed_resolve" {
            guard command.payload.deliveryProtocol == "gateway-v1",
                  let url = command.payload.url,
                  url.scheme?.lowercased() == "https",
                  url.user == nil,
                  url.password == nil,
                  URLSafetyPolicy.isAllowed(url)
            else {
                complete(commandID: command.id, acknowledgement: CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"))
                return true
            }
            if inFlightHomeCommands[command.id] != nil { return false }
            let service = self.service
            inFlightHomeCommands[command.id] = Task { [weak self] in
                let acknowledgement: CloudRemoteCommandAck
                do {
                    let extraction = try await service.extract(url: url)
                    if let playback = CloudPlaybackResolution(result: extraction) {
                        acknowledgement = Self.boundedPlaybackAcknowledgement(id: command.id, playback: playback)
                    } else {
                        acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "provider_changed")
                    }
                } catch {
                    acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: error is URLError ? "provider_unreachable" : "provider_changed")
                }
                await self?.completeAsync(commandID: command.id, acknowledgement: acknowledgement)
            }
            return false
        }
        if command.kind == "feed_page", command.payload.siteID == FeedSiteID.allPornStream.rawValue {
            guard let page = command.payload.page, page > 0 else {
                let acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
                complete(commandID: command.id, acknowledgement: acknowledgement)
                return true
            }
            if inFlightFeedCommands[command.id] != nil { return false }
            let service = self.service
            inFlightFeedCommands[command.id] = Task { [weak self] in
                let acknowledgement: CloudRemoteCommandAck
                do {
                    let result = try await service.feedPage(site: .allPornStream, query: command.payload.query, page: page)
                    acknowledgement = Self.boundedFeedPageAcknowledgement(id: command.id, page: result)
                } catch {
                    acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: Self.feedFailureCode(error))
                }
                await self?.completeAsync(commandID: command.id, acknowledgement: acknowledgement)
            }
            return false
        }
        let acknowledgement: CloudRemoteCommandAck
        switch command.kind {
        case "library_list":
            guard command.payload.deliveryProtocol == "gateway-v1",
                  let page = command.payload.page,
                  (1...100).contains(page)
            else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            let snapshot = await libraryStore.snapshot(jobs: (try? await service.allJobs()) ?? [], page: page)
            acknowledgement = Self.libraryAcknowledgement(id: command.id, snapshot: snapshot)
        case "library_update":
            guard command.payload.deliveryProtocol == "gateway-v1",
                  let itemID = command.payload.itemID,
                  (command.payload.tags?.count ?? 0) <= 20,
                  (command.payload.collection?.count ?? 0) <= 80
            else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                let snapshot = try await libraryStore.update(id: itemID, tags: command.payload.tags ?? [], collection: command.payload.collection, favorite: command.payload.favorite, jobs: (try? await service.allJobs()) ?? [])
                acknowledgement = Self.libraryAcknowledgement(id: command.id, snapshot: snapshot)
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "library_remove":
            guard command.payload.deliveryProtocol == "gateway-v1", let itemID = command.payload.itemID
            else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                let snapshot = try await libraryStore.remove(id: itemID, jobs: (try? await service.allJobs()) ?? [])
                acknowledgement = Self.libraryAcknowledgement(id: command.id, snapshot: snapshot)
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "library_verify":
            guard command.payload.deliveryProtocol == "gateway-v1", let itemID = command.payload.itemID
            else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                let snapshot = try await libraryStore.verify(id: itemID, jobs: (try? await service.allJobs()) ?? [])
                acknowledgement = Self.libraryAcknowledgement(id: command.id, snapshot: snapshot)
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "home_status":
            guard command.payload.deliveryProtocol == "gateway-v1" else {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
                break
            }
            acknowledgement = CloudRemoteCommandAck(
                id: command.id,
                status: "completed",
                jobID: nil,
                result: CloudRemoteResult(
                    kind: "home_status",
                    sites: nil,
                    page: nil,
                    destinations: nil,
                    homeReadiness: .current()
                )
            )
        case "queue_url":
            guard let url = command.payload.url,
                  command.payload.deliveryProtocol == "gateway-v1"
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
                let job = try await service.createJob(CreateJobRequest(id: command.id, sourcePageURL: url, title: command.payload.title, preferredQualityLabel: command.payload.preferredQualityLabel, destination: command.payload.destination))
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
            acknowledgement = Self.boundedDestinationsAcknowledgement(id: command.id, webDAV: await service.allRemoteDestinations(), googleDrive: await service.allGoogleDriveDestinations())
        case "local_folder_status":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "local_download_folder", sites: nil, page: nil, destinations: nil, localDownloadFolder: await service.localDownloadFolderStatus()))
        case "local_folder_choose":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                _ = try await service.selectDownloadFolder()
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "local_download_folder", sites: nil, page: nil, destinations: nil, localDownloadFolder: await service.localDownloadFolderStatus()))
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "cancelled")
            }
        case "local_folder_reset":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                try await service.resetDownloadFolder()
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "local_download_folder", sites: nil, page: nil, destinations: nil, localDownloadFolder: await service.localDownloadFolderStatus()))
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "gdrive_connect":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                _ = try await service.connectGoogleDrive()
                acknowledgement = Self.boundedDestinationsAcknowledgement(id: command.id, webDAV: await service.allRemoteDestinations(), googleDrive: await service.allGoogleDriveDestinations())
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "gdrive_folders":
            guard command.payload.deliveryProtocol == "gateway-v1", let profileID = command.payload.profileID, let path = command.payload.path else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                let folders = try await service.googleDriveFolders(profileID: profileID, path: path)
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "google_drive_folders", sites: nil, page: nil, destinations: nil, googleDriveFolders: folders))
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "gdrive_create_folder":
            guard command.payload.deliveryProtocol == "gateway-v1", let profileID = command.payload.profileID, let path = command.payload.path else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                try await service.createGoogleDriveFolder(profileID: profileID, path: path)
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "destination_test", sites: nil, page: nil, destinations: nil))
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "gdrive_select_folder":
            guard command.payload.deliveryProtocol == "gateway-v1", let profileID = command.payload.profileID, let path = command.payload.path else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                _ = try await service.selectGoogleDriveFolder(profileID: profileID, path: path)
                acknowledgement = Self.boundedDestinationsAcknowledgement(id: command.id, webDAV: await service.allRemoteDestinations(), googleDrive: await service.allGoogleDriveDestinations())
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "gdrive_test":
            guard command.payload.deliveryProtocol == "gateway-v1", let profileID = command.payload.profileID else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do {
                let result = try await service.testGoogleDriveDestination(id: profileID)
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "destination_test", sites: nil, page: nil, destinations: nil, googleDriveFolders: nil))
                _ = result
            } catch {
                acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
            }
        case "pornhub_auth_status":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            acknowledgement = Self.pornHubAuthAcknowledgement(id: command.id, status: await service.pornHubAuthStatus())
        case "pornhub_auth_login":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do { acknowledgement = Self.pornHubAuthAcknowledgement(id: command.id, status: try await service.signInWithPornHub()) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: Self.pornHubAuthFailureCode(error)) }
        case "pornhub_auth_cancel":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            acknowledgement = Self.pornHubAuthAcknowledgement(id: command.id, status: await service.cancelPornHubSignIn())
        case "pornhub_auth_logout":
            guard command.payload.deliveryProtocol == "gateway-v1" else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: "invalid_request"); break }
            do { acknowledgement = Self.pornHubAuthAcknowledgement(id: command.id, status: try await service.signOutOfPornHub()) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil, code: Self.pornHubAuthFailureCode(error)) }
        case "webdav_add":
            guard let name = command.payload.name, let baseURL = command.payload.baseURL, let username = command.payload.username, let remotePath = command.payload.remotePath, let password = try? Self.promptForWebDAVPassword(name: name) else { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil); break }
            do { _ = try await service.saveWebDAVDestination(WebDAVDestinationRequest(name: name, baseURL: baseURL, username: username, password: password, remotePath: remotePath, allowInvalidCertificate: command.payload.allowInvalidCertificate == "true")); acknowledgement = CloudRemoteCommandAck(id: command.id, status: "completed", jobID: nil, result: nil) }
            catch { acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil) }
        default:
            acknowledgement = CloudRemoteCommandAck(id: command.id, status: "failed", jobID: nil, result: nil)
        }
        complete(commandID: command.id, acknowledgement: acknowledgement)
        return true
    }

    static func libraryAcknowledgement(id: UUID, snapshot: CloudLibrarySnapshot) -> CloudRemoteCommandAck {
        let acknowledgement = CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "library_snapshot", sites: nil, page: nil, destinations: nil, library: snapshot))
        guard let data = try? JSONEncoder.cloud.encode(acknowledgement), data.count <= 118_000 else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil, code: "result_too_large")
        }
        return acknowledgement
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
        func acknowledgement(_ candidate: FeedPage) -> CloudRemoteCommandAck {
            CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "feed_page", sites: nil, page: candidate, destinations: nil))
        }
        var completed = acknowledgement(page)
        if let encoded = try? JSONEncoder.cloud.encode(completed), encoded.count <= maximumFeedPageAcknowledgementBytes {
            return completed
        }
        for maximumPreviews in stride(from: 3, through: 0, by: -1) {
            let items = page.items.map { item in
                let distinctPreviews = item.previewURLs.filter { $0 != item.thumbnailURL }
                return FeedItem(
                    id: item.id,
                    siteID: item.siteID,
                    title: item.title,
                    sourcePageURL: item.sourcePageURL,
                    thumbnailURL: item.thumbnailURL,
                    previewURLs: Array(distinctPreviews.prefix(maximumPreviews)),
                    uploadedAt: item.uploadedAt,
                    uploadedAtIsApproximate: item.uploadedAtIsApproximate,
                    viewCount: item.viewCount,
                    studio: item.studio,
                    queueCapability: item.queueCapability,
                    downloadedAt: item.downloadedAt
                )
            }
            completed = acknowledgement(FeedPage(items: items, page: page.page, hasMore: page.hasMore))
            if let encoded = try? JSONEncoder.cloud.encode(completed), encoded.count <= maximumFeedPageAcknowledgementBytes {
                return completed
            }
        }
        return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil, code: "result_too_large")
    }

    static func boundedDestinationsAcknowledgement(id: UUID, webDAV: [WebDAVDestinationProfile], googleDrive: [GoogleDriveDestinationProfile]) -> CloudRemoteCommandAck {
        guard webDAV.count + googleDrive.count <= maximumDestinations else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        }
        let destinations = (webDAV.compactMap(CloudRemoteDestination.init) + googleDrive.compactMap(CloudRemoteDestination.init)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard destinations.count == webDAV.count + googleDrive.count else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        }
        let completed = CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "destinations_list", sites: nil, page: nil, destinations: destinations))
        guard let encoded = try? JSONEncoder.cloud.encode(completed), encoded.count <= maximumDestinationsAcknowledgementBytes else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil)
        }
        return completed
    }

    static func boundedDestinationsAcknowledgement(id: UUID, profiles: [WebDAVDestinationProfile]) -> CloudRemoteCommandAck {
        boundedDestinationsAcknowledgement(id: id, webDAV: profiles, googleDrive: [])
    }

    static func pornHubAuthAcknowledgement(id: UUID, status: PornHubAuthStatus) -> CloudRemoteCommandAck {
        CloudRemoteCommandAck(id: id, status: "completed", jobID: nil, result: CloudRemoteResult(kind: "pornhub_auth", sites: nil, page: nil, destinations: nil, pornHubAuth: CloudRemotePornHubAuthStatus(status)))
    }

    static func boundedHomePreviewAcknowledgement(id: UUID, items: [CloudHomePreviewItem]) -> CloudRemoteCommandAck {
        guard (1...10).contains(items.count) else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil, code: "invalid_request")
        }
        let acknowledgement = CloudRemoteCommandAck(
            id: id,
            status: "completed",
            jobID: nil,
            result: CloudRemoteResult(
                kind: "extract_preview",
                sites: nil,
                page: nil,
                destinations: nil,
                homePreview: items
            )
        )
        guard let encoded = try? JSONEncoder.cloud.encode(acknowledgement),
              encoded.count <= maximumHomePreviewAcknowledgementBytes
        else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil, code: "result_too_large")
        }
        return acknowledgement
    }

    static func boundedPlaybackAcknowledgement(id: UUID, playback: CloudPlaybackResolution) -> CloudRemoteCommandAck {
        let acknowledgement = CloudRemoteCommandAck(
            id: id,
            status: "completed",
            jobID: nil,
            result: CloudRemoteResult(kind: "feed_resolve", sites: nil, page: nil, destinations: nil, playback: playback)
        )
        guard let encoded = try? JSONEncoder.cloud.encode(acknowledgement),
              encoded.count <= maximumHomePreviewAcknowledgementBytes
        else {
            return CloudRemoteCommandAck(id: id, status: "failed", jobID: nil, result: nil, code: "result_too_large")
        }
        return acknowledgement
    }

    private static func previewItems(service: AgentService, urls: [URL]) async -> [CloudHomePreviewItem] {
        var items = Array<CloudHomePreviewItem?>(repeating: nil, count: urls.count)
        for start in stride(from: 0, to: urls.count, by: 3) {
            let end = min(start + 3, urls.count)
            await withTaskGroup(of: (Int, CloudHomePreviewItem).self) { group in
                for index in start..<end {
                    let url = urls[index]
                    group.addTask {
                        do {
                            return (index, CloudHomePreviewItem(result: try await service.extract(url: url)))
                        } catch {
                            let code = error is URLError ? "provider_unreachable" : "provider_changed"
                            return (index, CloudHomePreviewItem(sourcePageURL: url, errorCode: code))
                        }
                    }
                }
                for await (index, item) in group {
                    items[index] = item
                }
            }
        }
        return zip(urls, items).map { url, item in
            item ?? CloudHomePreviewItem(sourcePageURL: url, errorCode: "provider_changed")
        }
    }

    private static func pornHubAuthFailureCode(_ error: Error) -> String {
        (error as? PornHubAuthError)?.cloudCode ?? "auth_helper_failed"
    }

    private func enqueue(_ acknowledgement: CloudRemoteCommandAck) {
        Self.appendAcknowledgement(acknowledgement, to: &acknowledgements)
    }

    private static func feedFailureCode(_ error: Error) -> String {
        if let error = error as? BrowserCaptureError {
            switch error {
            case .browserExtensionRequired: return "browser_extension_required"
            case .timeout, .cancelled, .browserClosed: return "provider_verification_required"
            case .invalidCapture: return "provider_changed"
            }
        }
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

    private func complete(commandID: UUID, acknowledgement: CloudRemoteCommandAck) {
        completed[commandID] = acknowledgement
        try? AgentPaths.prepare()
        try? JSONEncoder.cloud.encode(Array(completed.values)).write(to: receiptsURL, options: .atomic)
        enqueue(acknowledgement)
    }

    private func completeAsync(commandID: UUID, acknowledgement: CloudRemoteCommandAck) async {
        inFlightFeedCommands[commandID] = nil
        inFlightHomeCommands[commandID] = nil
        complete(commandID: commandID, acknowledgement: acknowledgement)
        await completionHandler?()
    }

    private static func promptForWebDAVPassword(name _: String) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", "text returned of (display dialog \"Enter the WebDAV password\" default answer \"\" with hidden answer)"]
        let output = Pipe(); process.standardOutput = output; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0, let password = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else { throw RemoteDestinationError.missingCredentials }
        return password
    }
}
