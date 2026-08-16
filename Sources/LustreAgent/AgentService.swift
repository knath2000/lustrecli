import Foundation
import LustreCore
import Security

public struct LocalDownloadFolderStatus: Codable, Equatable, Sendable {
    public let mode: String
    public let folderName: String

    public init(mode: String, folderName: String) {
        self.mode = mode
        self.folderName = folderName
    }
}

private struct LocalDownloadFolderConfiguration: Codable {
    let path: String
}

public actor AgentService {
    public typealias Downloader = @Sendable (ProviderResolution, ResolvedQuality, URL) async throws -> URL
    public typealias ProgressDownloader = @Sendable (ProviderResolution, ResolvedQuality, URL, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias RemoteProgressDownloader = @Sendable (ProviderResolution, ResolvedQuality, WebDAVDestinationProfile, String, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias HLSMaterializer = @Sendable (ProviderResolution, ResolvedQuality, URL, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias PornHubResolver = @Sendable (URL) async throws -> ProviderResolution
    public typealias GenericYtDlpResolver = @Sendable (URL) async throws -> ProviderResolution
    public typealias YtDlpMaterializer = @Sendable (ProviderResolution, ResolvedQuality, URL, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias StagedRemoteUploader = @Sendable (ProviderResolution, ResolvedQuality, URL, WebDAVDestinationProfile, String, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias RemoteDestinationTester = @Sendable (WebDAVDestinationProfile, String) async throws -> RemoteDestinationTestResult
    public typealias FolderPicker = @Sendable () throws -> String
    public typealias AllPornStreamHTML = @Sendable (URL) async throws -> String

    private struct ActiveDownload {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct LastProgressUpdate {
        let phase: TransferPhase?
        let bytesWritten: Int64
        let totalBytes: Int64?
        let totalIsEstimated: Bool
        let fraction: Double?
        let timestamp: Date
    }

    private let jobs: JobStore
    private let resolver: StaticProviderResolver
    private var downloadsDirectory: URL
    private let defaultDownloadsDirectory: URL
    private let localDownloadConfigurationURL: URL?
    private let automaticallyStartsDownloads: Bool
    private let progressDownloader: ProgressDownloader
    private let remoteDownloader: RemoteProgressDownloader
    private let hlsMaterializer: HLSMaterializer
    private let pornHubResolver: PornHubResolver
    private let genericYtDlpResolver: GenericYtDlpResolver
    private let ytDlpMaterializer: YtDlpMaterializer
    private let stagedRemoteUploader: StagedRemoteUploader
    private let remoteDestinationTester: RemoteDestinationTester
    private let destinationProfiles: RemoteDestinationProfileStore
    private let destinationSecrets: RemoteDestinationSecretStore
    private let googleDriveProfiles: GoogleDriveDestinationStore
    private let googleDriveClient: GoogleDriveClient
    private let folderPicker: FolderPicker
    private let feed: FeedService
    private let feedAssetProxy: FeedAssetProxy
    private let pornHubAuth: PornHubAuthService
    private let allPornStreamCapture: AllPornStreamCaptureCoordinator?
    private let allPornStreamHTML: AllPornStreamHTML?
    private let directExtractor: DirectExtractor
    private var maximumConcurrentDownloads: Int
    private var activeDownloadTasks: [UUID: ActiveDownload] = [:]
    private var lastProgressUpdates: [UUID: LastProgressUpdate] = [:]

    public init(
        databaseURL: URL = AgentPaths.database,
        resolver: StaticProviderResolver = StaticProviderResolver(),
        downloadsDirectory: URL = AgentPaths.downloads,
        automaticallyStartsDownloads: Bool = true,
        downloader: Downloader? = nil,
        progressDownloader: ProgressDownloader? = nil,
        folderPicker: FolderPicker? = nil,
        destinationProfiles: RemoteDestinationProfileStore? = nil,
        googleDriveProfiles: GoogleDriveDestinationStore? = nil,
        destinationSecrets: RemoteDestinationSecretStore = KeychainRemoteDestinationSecretStore(),
        remoteDownloader: RemoteProgressDownloader? = nil,
        hlsMaterializer: HLSMaterializer? = nil,
        pornHubResolver: PornHubResolver? = nil,
        genericYtDlpResolver: GenericYtDlpResolver? = nil,
        ytDlpMaterializer: YtDlpMaterializer? = nil,
        stagedRemoteUploader: StagedRemoteUploader? = nil,
        remoteDestinationTester: RemoteDestinationTester? = nil,
        feed: FeedService? = nil,
        feedAssetProxy: FeedAssetProxy = FeedAssetProxy(),
        pornHubAuth: PornHubAuthService = PornHubAuthService(),
        allPornStreamCapture: AllPornStreamCaptureCoordinator? = nil,
        allPornStreamHTML: AllPornStreamHTML? = nil,
        maximumConcurrentDownloads: Int = 1
    ) throws {
        self.jobs = try JobStore(databaseURL: databaseURL)
        self.resolver = resolver
        self.defaultDownloadsDirectory = downloadsDirectory
        self.localDownloadConfigurationURL = downloadsDirectory.standardizedFileURL == AgentPaths.downloads.standardizedFileURL ? AgentPaths.localDownloadConfiguration : nil
        self.downloadsDirectory = Self.savedDownloadDirectory(at: self.localDownloadConfigurationURL) ?? downloadsDirectory
        self.automaticallyStartsDownloads = automaticallyStartsDownloads
        if let progressDownloader {
            self.progressDownloader = progressDownloader
        } else if let downloader {
            self.progressDownloader = { resolution, quality, directory, _ in
                try await downloader(resolution, quality, directory)
            }
        } else {
            self.progressDownloader = AgentService.downloadToLocalDirectory
        }
        self.destinationProfiles = try destinationProfiles ?? RemoteDestinationProfileStore(fileURL: AgentPaths.remoteDestinations)
        self.googleDriveProfiles = try googleDriveProfiles ?? GoogleDriveDestinationStore(fileURL: AgentPaths.googleDriveDestinations)
        self.googleDriveClient = GoogleDriveClient()
        self.destinationSecrets = destinationSecrets
        self.remoteDownloader = remoteDownloader ?? AgentService.uploadToWebDAV
        self.hlsMaterializer = hlsMaterializer ?? FFmpegHLSMaterializer.materialize
        self.pornHubAuth = pornHubAuth
        self.allPornStreamCapture = allPornStreamCapture
        self.allPornStreamHTML = allPornStreamHTML
        self.pornHubResolver = pornHubResolver ?? { source in
            let cookies = (try? await pornHubAuth.cookiesForYtDlp()) ?? []
            do { return try await PornHubYtDlp.resolve(source: source, cookies: cookies) }
            catch let error as PornHubYtDlpError {
                if !cookies.isEmpty { await pornHubAuth.recordYtDlpFailure(error) }
                throw error
            }
        }
        self.genericYtDlpResolver = genericYtDlpResolver ?? GenericYtDlp.resolve
        self.directExtractor = DirectExtractor(
            resolver: resolver,
            pornHubResolver: self.pornHubResolver,
            genericResolver: self.genericYtDlpResolver,
            allPornStreamHTML: allPornStreamHTML
        )
        self.ytDlpMaterializer = ytDlpMaterializer ?? { resolution, quality, directory, reportProgress in
            guard let selector = quality.formatSelector else { throw PornHubYtDlpError.invalidFormat }
            if resolution.provider != .pornHub {
                return try await GenericYtDlp.materialize(source: resolution.sourcePageURL, title: resolution.title, formatSelector: selector, directory: directory, onProgress: reportProgress)
            }
            let cookies = (try? await pornHubAuth.cookiesForYtDlp()) ?? []
            do { return try await PornHubYtDlp.materialize(source: resolution.sourcePageURL, title: resolution.title, formatSelector: selector, directory: directory, cookies: cookies, onProgress: reportProgress) }
            catch let error as PornHubYtDlpError {
                if !cookies.isEmpty { await pornHubAuth.recordYtDlpFailure(error) }
                throw error
            }
        }
        self.stagedRemoteUploader = stagedRemoteUploader ?? AgentService.uploadMaterializedFileToWebDAV
        self.remoteDestinationTester = remoteDestinationTester ?? AgentService.testWebDAVDestination
        self.folderPicker = folderPicker ?? AgentService.chooseDownloadFolder
        self.feed = feed ?? FeedService(
            fetch: PornHubFeedRequest.fetch,
            pornHubCookieHeader: { url in try await pornHubAuth.cookieHeader(for: url) },
            pornHubHomepageSession: { url in
                do {
                    guard let cookieHeader = try await pornHubAuth.regularHomepageCookieHeader(for: url) else { return .anonymous }
                    return .authenticated(cookieHeader: cookieHeader)
                } catch {
                    throw FeedError.authenticationUnavailable
                }
            }
        )
        self.feedAssetProxy = feedAssetProxy
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        Task { [weak self] in
            await self?.recoverDurableJobs()
        }
    }

    public func health() async -> AgentHealth {
        let storedJobs = try? await jobs.allJobs()
        return AgentHealth(
            status: storedJobs == nil ? "degraded" : "ok",
            runtimeVersion: ProcessInfo.processInfo.environment["LUSTRE_RUNTIME_VERSION"] ?? "development",
            databaseReady: storedJobs != nil,
            activeJobs: storedJobs?.filter { $0.status == .running }.count ?? 0
        )
    }

    public func setMaximumConcurrentDownloads(_ limit: Int) async {
        maximumConcurrentDownloads = min(max(limit, 1), 8)
        await scheduleQueuedDownloads()
    }

    public func allJobs() async throws -> [DownloadJob] {
        try await jobs.allJobs()
    }

    public func feedSites() async -> [FeedSite] {
        let sites = feed.sites()
        return await pornHubAuth.status().state == .signedIn ? sites + FeedSite.authenticatedPornHub : sites
    }

    public func feedPage(site: FeedSiteID, query: String? = nil, page: Int) async throws -> FeedPage {
        let result: FeedPage
        if site == .allPornStream {
            guard let allPornStreamCapture else { throw BrowserCaptureError.browserExtensionRequired }
            let feedQuery = try FeedQuery(site: site, text: query, page: page)
            guard var components = URLComponents(url: FeedSite.allPornStream.homeURL, resolvingAgainstBaseURL: false) else { throw FeedError.invalidPage }
            var items: [URLQueryItem] = []
            if let text = feedQuery.text { items.append(URLQueryItem(name: "s", value: text)) }
            if page > 1 { items.append(URLQueryItem(name: "page", value: String(page))) }
            components.queryItems = items.isEmpty ? nil : items
            guard let url = components.url else { throw FeedError.invalidPage }
            result = try await allPornStreamCapture.capture(url: url, page: page)
        } else {
            result = try await feed.page(FeedQuery(site: site, text: query, page: page))
        }
        return DownloadedFeedHistory(jobs: try await jobs.allJobs()).decorate(result)
    }

    public func verifyAllPornStream() async throws {
        _ = try await feedPage(site: .allPornStream, page: 1)
    }

    public func feedAsset(url: URL, kind: FeedAssetKind) async throws -> FeedAssetResponse {
        try await feedAssetProxy.load(url: url, kind: kind)
    }

    public func pornHubAuthStatus() async -> PornHubAuthStatus { await pornHubAuth.status() }
    public func signInWithPornHub() async throws -> PornHubAuthStatus { try await pornHubAuth.login() }
    public func cancelPornHubSignIn() async -> PornHubAuthStatus { await pornHubAuth.cancelLogin() }
    public func signOutOfPornHub() async throws -> PornHubAuthStatus {
        try await pornHubAuth.logout()
    }

    public func allRemoteDestinations() async -> [WebDAVDestinationProfile] {
        await destinationProfiles.all()
    }

    public func saveWebDAVDestination(_ request: WebDAVDestinationRequest) async throws -> WebDAVDestinationProfile {
        let profile = try await destinationProfiles.save(request)
        do {
            try destinationSecrets.save(password: request.password, for: profile.id)
            return profile
        } catch {
            try? await destinationProfiles.remove(id: profile.id)
            throw error
        }
    }

    public func removeRemoteDestination(id: UUID) async throws {
        try await destinationProfiles.remove(id: id)
        try destinationSecrets.remove(profileID: id)
    }

    public func testRemoteDestination(id: UUID) async throws -> RemoteDestinationTestResult {
        guard let profile = await destinationProfiles.profile(id: id) else { throw RemoteDestinationError.notFound }
        guard let password = try destinationSecrets.password(for: id), !password.isEmpty else {
            throw RemoteDestinationError.missingCredentials
        }
        return try await remoteDestinationTester(profile, password)
    }

    public func allGoogleDriveDestinations() async -> [GoogleDriveDestinationProfile] {
        await googleDriveProfiles.all()
    }

    public func connectGoogleDrive(remoteName: String? = nil) async throws -> GoogleDriveDestinationProfile {
        let remotes = try await googleDriveClient.configuredDriveRemotes()
        let selected = remoteName.flatMap { requested in
            remotes.first { $0.caseInsensitiveCompare(requested) == .orderedSame }
        } ?? remotes.first(where: { $0.caseInsensitiveCompare("gdrive") == .orderedSame }) ?? remotes.first
        guard let selected else { throw GoogleDriveClientError.remoteUnavailable }
        return try await googleDriveProfiles.save(remoteName: selected, remotePath: "/")
    }

    public func googleDriveFolders(profileID: UUID, path: String) async throws -> [GoogleDriveFolder] {
        guard let profile = await googleDriveProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
        return try await googleDriveClient.folders(remoteName: profile.remoteName, path: path)
    }

    public func createGoogleDriveFolder(profileID: UUID, path: String) async throws {
        guard let profile = await googleDriveProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
        try await googleDriveClient.createFolder(remoteName: profile.remoteName, path: path)
    }

    public func selectGoogleDriveFolder(profileID: UUID, path: String) async throws -> GoogleDriveDestinationProfile {
        guard let profile = await googleDriveProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
        _ = try await googleDriveClient.folders(remoteName: profile.remoteName, path: path)
        return try await googleDriveProfiles.save(name: profile.name, remoteName: profile.remoteName, remotePath: path, id: profile.id)
    }

    public func testGoogleDriveDestination(id: UUID) async throws -> RemoteDestinationTestResult {
        guard let profile = await googleDriveProfiles.profile(id: id) else { throw RemoteDestinationError.notFound }
        return try await googleDriveClient.test(profile: profile)
    }

    public func removeGoogleDriveDestination(id: UUID) async throws {
        try await googleDriveProfiles.remove(id: id)
    }

    public func extract(url: URL) async throws -> ExtractionResult {
        try await directExtractor.extract(url: url)
    }

    public func createJob(_ request: CreateJobRequest) async throws -> DownloadJob {
        guard URLSafetyPolicy.isAllowed(request.sourcePageURL) else {
            throw AgentServiceError.invalidURL
        }
        let destination = try await normalizedDestination(request.destination)
        let preferredQualityLabel = request.preferredQualityLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedTitle = title.flatMap { $0.isEmpty ? nil : String($0.prefix(512)) }
        var job = DownloadJob(
            id: request.id ?? UUID(),
            sourcePageURL: request.sourcePageURL,
            title: boundedTitle,
            preferredQualityLabel: preferredQualityLabel?.isEmpty == false ? preferredQualityLabel : nil,
            qualitySelector: request.qualitySelector,
            assistedResolution: request.assistedResolution,
            destination: destination
        )
        let queueMessage = if RemoteDestination.googleDriveProfileID(from: destination) != nil {
            "Queued for Google Drive upload."
        } else if RemoteDestination.webDAVProfileID(from: destination) != nil {
            "Queued for remote WebDAV download."
        } else {
            "Queued for local download."
        }
        record(&job, level: .info, message: queueMessage)
        try await jobs.create(job)
        if automaticallyStartsDownloads { await enqueueDownload(job.id) }
        return job
    }

    public func job(id: UUID) async throws -> DownloadJob? {
        try await jobs.job(id: id)
    }

    func normalizedCloudDestination(_ destination: String?) async throws -> String {
        try await normalizedDestination(destination)
    }

    public func selectDownloadFolder() async throws -> String {
        let picker = folderPicker
        let selectedPath = try await Task.detached(operation: picker).value
        let normalized = try await normalizedDestination(selectedPath)
        downloadsDirectory = URL(fileURLWithPath: normalized).standardizedFileURL
        try saveDownloadDirectory()
        return normalized
    }

    public func resetDownloadFolder() throws {
        downloadsDirectory = defaultDownloadsDirectory
        if let localDownloadConfigurationURL {
            try? FileManager.default.removeItem(at: localDownloadConfigurationURL)
        }
    }

    public func localDownloadFolderStatus() -> LocalDownloadFolderStatus {
        LocalDownloadFolderStatus(
            mode: downloadsDirectory.standardizedFileURL == defaultDownloadsDirectory.standardizedFileURL ? "default" : "custom",
            folderName: String(downloadsDirectory.lastPathComponent.prefix(128))
        )
    }

    private static func chooseDownloadFolder() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "POSIX path of (choose folder with prompt \"Choose Lustre download folder\")"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw AgentServiceError.folderSelectionCancelled
        }
        return path
    }

    private static func savedDownloadDirectory(at fileURL: URL?) -> URL? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let configuration = try? JSONDecoder().decode(LocalDownloadFolderConfiguration.self, from: data)
        else { return nil }
        let directory = URL(fileURLWithPath: configuration.path).standardizedFileURL
        guard directory.path.hasPrefix("/"),
              (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return directory
    }

    private func saveDownloadDirectory() throws {
        guard let localDownloadConfigurationURL else { return }
        try FileManager.default.createDirectory(at: localDownloadConfigurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(LocalDownloadFolderConfiguration(path: downloadsDirectory.path))
        try data.write(to: localDownloadConfigurationURL, options: .atomic)
    }

    public func apply(_ action: JobAction, to id: UUID) async throws -> DownloadJob {
        var job = try await jobs.apply(action, to: id)
        record(&job, level: .info, message: job.message)
        try await jobs.update(job)
        switch action {
        case .pause, .cancel:
            activeDownloadTasks[id]?.task.cancel()
        case .resume, .retry:
            await enqueueDownload(id)
        case .forceStart:
            startDownload(id)
        }
        return job
    }

    public func processQueuedJob(id: UUID) async {
        await processQueuedJob(id: id, taskID: nil)
    }

    private func processQueuedJob(id: UUID, taskID: UUID?) async {
        do {
            guard ownsDownload(id, taskID: taskID),
                  var job = try await jobs.job(id: id), job.status == .queued else { return }
            job.status = .running
            record(&job, level: .info, message: "Resolving source page.")
            job.updatedAt = .now
            try await jobs.update(job)

            let extraction = try await extractionForJob(job)
            guard !Task.isCancelled,
                  ownsDownload(id, taskID: taskID),
                  var active = try await jobs.job(id: id),
                  active.status == .running else { return }
            if extraction.resolutionState == "verificationRequired" {
                active.status = .verificationRequired
                record(&active, level: .error, message: "Provider requires interactive browser verification.")
                active.updatedAt = .now
                try await jobs.update(active)
                return
            }
            guard var resolution = extraction.resolution else {
                throw AgentServiceError.noProviderResolved
            }
            guard !resolution.qualities.isEmpty else {
                throw AgentServiceError.noProviderResolved
            }
            guard let quality = selectedQuality(in: resolution, selector: active.qualitySelector, preferredLabel: active.preferredQualityLabel) else {
                throw AgentServiceError.noSelectedQuality
            }
            let resolvedTitle = active.title ?? resolution.title
            active.title = resolvedTitle
            resolution = ProviderResolution(
                sourcePageURL: resolution.sourcePageURL,
                provider: resolution.provider,
                title: resolvedTitle,
                thumbnailURL: resolution.thumbnailURL,
                qualities: resolution.qualities,
                trace: resolution.trace
            )

            guard ownsDownload(id, taskID: taskID) else { return }
            record(&active, level: .info, message: "Downloading \(quality.label).")
            active.progress = nil
            active.downloadedBytes = 0
            active.totalBytes = nil
            active.transferPhase = quality.mediaKind == .direct ? .downloading : .materializing
            active.updatedAt = .now
            try await jobs.update(active)
            guard !Task.isCancelled,
                  ownsDownload(id, taskID: taskID),
                  let current = try await jobs.job(id: id),
                  current.status == .running else { return }
            let reportProgress: @Sendable (DownloadProgress) async -> Void = { [weak self] progress in
                guard let self else { return }
                await self.updateProgress(progress, for: id, taskID: taskID)
            }
            let output: URL
            if let profileID = RemoteDestination.googleDriveProfileID(from: current.destination) {
                guard let profile = await googleDriveProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
                record(&active, level: .info, message: "Preparing \(quality.label) for \(profile.name).")
                active.transferPhase = .materializing
                active.phaseProgress = nil
                active.phaseBytes = 0
                active.phaseTotalBytes = nil
                active.progress = nil
                active.downloadedBytes = 0
                active.totalBytes = nil
                try await jobs.update(active)
                let staging = FileManager.default.temporaryDirectory.appending(path: "lustre-gdrive-\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: staging) }
                let media: URL
                switch quality.mediaKind {
                case .direct:
                    media = try await progressDownloader(resolution, quality, staging, reportProgress)
                case .hls:
                    media = try await hlsMaterializer(resolution, quality, staging, reportProgress)
                case .ytDlp:
                    media = try await ytDlpMaterializer(resolution, quality, staging, reportProgress)
                }
                guard var uploading = try await jobs.job(id: id), uploading.status == .running else { return }
                let size = (try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                uploading.transferPhase = .uploading
                uploading.phaseProgress = 0
                uploading.phaseBytes = 0
                uploading.phaseTotalBytes = size
                uploading.progress = 0
                uploading.downloadedBytes = 0
                uploading.totalBytes = size
                record(&uploading, level: .info, message: "Uploading \(quality.label) to \(profile.name).")
                uploading.updatedAt = .now
                try await jobs.update(uploading)
                output = try await googleDriveClient.upload(file: media, profile: profile, onProgress: reportProgress)
            } else if quality.mediaKind != .direct, let profileID = RemoteDestination.webDAVProfileID(from: current.destination) {
                guard let profile = await destinationProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
                guard let password = try destinationSecrets.password(for: profileID), !password.isEmpty else {
                    throw RemoteDestinationError.missingCredentials
                }
                record(&active, level: .info, message: "Materializing \(quality.label) before upload to \(profile.name).")
                active.transferPhase = .materializing
                active.phaseProgress = nil
                active.phaseBytes = 0
                active.phaseTotalBytes = nil
                active.phaseTotalIsEstimated = false
                active.phaseBytesPerSecond = nil
                active.phaseETASeconds = nil
                active.progress = nil
                active.downloadedBytes = 0
                active.totalBytes = nil
                try await jobs.update(active)
                let staging = FileManager.default.temporaryDirectory.appending(path: "lustre-materialized-\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: staging) }
                let media = quality.mediaKind == .hls
                    ? try await hlsMaterializer(resolution, quality, staging, reportProgress)
                    : try await ytDlpMaterializer(resolution, quality, staging, reportProgress)
                guard var uploading = try await jobs.job(id: id), uploading.status == .running else { return }
                let size = (try? media.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                uploading.transferPhase = .uploading
                uploading.phaseProgress = 0
                uploading.phaseBytes = 0
                uploading.phaseTotalBytes = size
                uploading.phaseTotalIsEstimated = false
                uploading.phaseBytesPerSecond = nil
                uploading.phaseETASeconds = nil
                uploading.progress = 0
                uploading.downloadedBytes = 0
                uploading.totalBytes = size
                record(&uploading, level: .info, message: "Uploading \(quality.label) to \(profile.name).")
                uploading.updatedAt = .now
                try await jobs.update(uploading)
                output = try await stagedRemoteUploader(resolution, quality, media, profile, password, reportProgress)
            } else if quality.mediaKind == .hls {
                output = try await hlsMaterializer(resolution, quality, try downloadDirectory(for: current.destination), reportProgress)
            } else if quality.mediaKind == .ytDlp {
                active.transferPhase = .materializing
                active.phaseProgress = nil
                active.phaseBytes = 0
                active.phaseTotalBytes = nil
                active.phaseTotalIsEstimated = false
                active.phaseBytesPerSecond = nil
                active.phaseETASeconds = nil
                active.progress = nil
                active.downloadedBytes = 0
                active.totalBytes = nil
                record(&active, level: .info, message: "Materializing media.")
                active.updatedAt = .now
                try await jobs.update(active)
                output = try await ytDlpMaterializer(resolution, quality, try downloadDirectory(for: current.destination), reportProgress)
            } else if let profileID = RemoteDestination.webDAVProfileID(from: current.destination) {
                guard let profile = await destinationProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
                guard let password = try destinationSecrets.password(for: profileID), !password.isEmpty else {
                    throw RemoteDestinationError.missingCredentials
                }
                record(&active, level: .info, message: "Streaming \(quality.label) to \(profile.name).")
                try await jobs.update(active)
                output = try await remoteDownloader(resolution, quality, profile, password, reportProgress)
            } else {
                output = try await progressDownloader(resolution, quality, try downloadDirectory(for: current.destination), reportProgress)
            }

            guard !Task.isCancelled,
                  ownsDownload(id, taskID: taskID),
                  var completed = try await jobs.job(id: id),
                  completed.status == .running else { return }
            completed.status = .completed
            completed.progress = 1
            completed.assistedResolution = nil
            completed.completionArtifact = completionArtifact(output: output, destination: completed.destination)
            completed.phaseBytesPerSecond = nil
            completed.phaseETASeconds = nil
            record(&completed, level: .info, message: "Completed: \(output.lastPathComponent)")
            completed.updatedAt = .now
            try await jobs.update(completed)
        } catch is CancellationError {
            // Pause and cancel persist their state before cancelling the active task.
        } catch {
            do {
                guard ownsDownload(id, taskID: taskID),
                      var failed = try await jobs.job(id: id), failed.status == .running else { return }
                failed.status = .failed
                record(&failed, level: .error, message: "Download failed: \(error.localizedDescription)")
                failed.updatedAt = .now
                try await jobs.update(failed)
            } catch {
                // The job store is the source of truth; there is no secondary error channel here.
            }
        }
    }

    private func enqueueDownload(_ id: UUID) async {
        if let activeTask = activeDownloadTasks[id] {
            if activeTask.task.isCancelled { startDownload(id) }
            return
        }
        guard activeDownloadTasks.count < maximumConcurrentDownloads else { return }
        startDownload(id)
    }

    private func startDownload(_ id: UUID) {
        if let activeTask = activeDownloadTasks[id], !activeTask.task.isCancelled { return }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processQueuedJob(id: id, taskID: token)
            await self.finishDownload(id: id, taskID: token)
        }
        activeDownloadTasks[id] = ActiveDownload(token: token, task: task)
    }

    private func finishDownload(id: UUID, taskID: UUID) async {
        guard activeDownloadTasks[id]?.token == taskID else { return }
        activeDownloadTasks[id] = nil
        lastProgressUpdates[id] = nil
        await scheduleQueuedDownloads()
    }

    private func scheduleQueuedDownloads() async {
        guard automaticallyStartsDownloads,
              activeDownloadTasks.count < maximumConcurrentDownloads,
              let allJobs = try? await jobs.allJobs() else { return }
        let queued = allJobs
            .filter { $0.status == .queued && activeDownloadTasks[$0.id] == nil }
            .sorted { $0.createdAt < $1.createdAt }
        for job in queued where activeDownloadTasks.count < maximumConcurrentDownloads {
            startDownload(job.id)
        }
    }

    private func ownsDownload(_ id: UUID, taskID: UUID?) -> Bool {
        guard let taskID else { return true }
        return activeDownloadTasks[id]?.token == taskID
    }

    private func updateProgress(_ progress: DownloadProgress, for id: UUID, taskID: UUID?) async {
        guard ownsDownload(id, taskID: taskID),
              var job = try? await jobs.job(id: id),
              job.status == .running else { return }
        if job.transferPhase == .uploading,
           progress.phase == .materializing || progress.phase == .postProcessing { return }
        let now = Date()
        let phase = progress.phase
        let fraction = progress.fraction
        let meaningful = lastProgressUpdates[id].map { last in
            last.phase != phase ||
            progress.bytesWritten < last.bytesWritten ||
            last.totalBytes == nil && progress.totalBytes != nil ||
            last.totalIsEstimated && !progress.totalIsEstimated ||
            last.totalBytes != progress.totalBytes ||
            last.fraction != 1 && fraction == 1 ||
            job.transferPhase != phase
        } ?? true
        if !meaningful,
           let last = lastProgressUpdates[id],
           progress.bytesWritten >= last.bytesWritten,
           progress.bytesWritten - last.bytesWritten < 512 * 1_024,
           now.timeIntervalSince(last.timestamp) < 0.5,
           fraction != 1 {
            return
        }
        lastProgressUpdates[id] = LastProgressUpdate(phase: phase, bytesWritten: progress.bytesWritten, totalBytes: progress.totalBytes, totalIsEstimated: progress.totalIsEstimated, fraction: fraction, timestamp: now)
        job.progress = fraction
        job.downloadedBytes = progress.bytesWritten
        job.totalBytes = progress.totalBytes
        job.transferPhase = progress.phase ?? job.transferPhase
        job.phaseProgress = fraction
        job.phaseBytes = progress.bytesWritten
        job.phaseTotalBytes = progress.totalBytes
        job.phaseTotalIsEstimated = progress.totalIsEstimated
        job.phaseBytesPerSecond = progress.bytesPerSecond
        job.phaseETASeconds = progress.etaSeconds
        if phase == .materializing && job.transferPhase != .materializing {
            record(&job, level: .info, message: "Materializing media.")
        } else if phase == .postProcessing && job.transferPhase != .postProcessing {
            record(&job, level: .info, message: "Merging video and audio.")
        }
        job.updatedAt = now
        try? await jobs.update(job)
    }

    private func recoverDurableJobs() async {
        do {
            for var job in try await jobs.allJobs() where job.status == .running {
                job.status = .queued
                record(&job, level: .info, message: "Requeued after agent restart.")
                job.updatedAt = .now
                try await jobs.update(job)
            }
            if automaticallyStartsDownloads {
                await scheduleQueuedDownloads()
            }
        } catch {
            // Jobs remain durable; a later agent start can retry recovery.
        }
    }

    private func extractionForJob(_ job: DownloadJob) async throws -> ExtractionResult {
        guard let assisted = job.assistedResolution else {
            return try await extract(url: job.sourcePageURL)
        }
        guard URLSafetyPolicy.isAllowed(assisted.mediaURL),
              assisted.headers.count <= 16,
              assisted.headers.allSatisfy({ $0.key.count <= 80 && $0.value.count <= 2_048 }),
              assisted.resolutionMethod.count <= 120
        else {
            throw AgentServiceError.invalidURL
        }
        let provider = job.qualitySelector?.provider ?? .direct
        let quality = ResolvedQuality(
            label: job.preferredQualityLabel ?? "Assisted video",
            url: assisted.mediaURL,
            headers: assisted.headers,
            resolutionMethod: assisted.resolutionMethod,
            mediaKind: assisted.mediaKind,
            formatSelector: job.qualitySelector?.formatSelector
        )
        let resolution = ProviderResolution(
            sourcePageURL: job.sourcePageURL,
            provider: provider,
            title: assisted.title ?? job.title,
            qualities: [quality],
            trace: ["Accepted loopback browser-assisted resolution."]
        )
        return ExtractionResult(
            sourcePageURL: job.sourcePageURL,
            isDirectMedia: assisted.mediaKind == .direct,
            resolutionState: "resolved",
            trace: resolution.trace,
            resolution: resolution
        )
    }

    private func selectedQuality(in resolution: ProviderResolution, selector: StableQualitySelector?, preferredLabel: String?) -> ResolvedQuality? {
        if let selector, selector.provider == resolution.provider {
            let candidates = resolution.qualities.filter { quality in
                quality.mediaKind == selector.mediaKind &&
                (selector.formatSelector == nil || quality.formatSelector == selector.formatSelector)
            }
            if let exact = candidates.first(where: { $0.label == preferredLabel }) { return exact }
            if let first = candidates.first { return first }
        }
        guard let preferredLabel = preferredLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !preferredLabel.isEmpty else {
            return resolution.qualities.first
        }
        return resolution.qualities.first { $0.label == preferredLabel }
    }

    private func completionArtifact(output: URL, destination: String) -> JobCompletionArtifact {
        if destination == "local" || destination.hasPrefix("/") {
            return JobCompletionArtifact(kind: "local", path: output.path, destination: destination, filename: output.lastPathComponent)
        }
        return JobCompletionArtifact(kind: "remote", path: nil, destination: destination, filename: output.lastPathComponent)
    }

    private func normalizedDestination(_ value: String?) async throws -> String {
        guard let value, value != "local" else { return "local" }
        if let profileID = RemoteDestination.webDAVProfileID(from: value) {
            guard await destinationProfiles.profile(id: profileID) != nil else { throw RemoteDestinationError.notFound }
            return RemoteDestination.webDAV(profileID)
        }
        if let profileID = RemoteDestination.googleDriveProfileID(from: value) {
            guard await googleDriveProfiles.profile(id: profileID) != nil else { throw RemoteDestinationError.notFound }
            return RemoteDestination.googleDrive(profileID)
        }
        guard value.hasPrefix("/") else { throw AgentServiceError.unsupportedDestination }
        let directory = URL(fileURLWithPath: value).standardizedFileURL
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw AgentServiceError.invalidDestination
        }
        return directory.path
    }

    private func downloadDirectory(for destination: String) throws -> URL {
        if destination == "local" { return downloadsDirectory }
        return URL(fileURLWithPath: destination)
    }

    private func record(_ job: inout DownloadJob, level: JobLogEntry.Level, message: String) {
        job.message = message
        var logs = job.logs ?? []
        logs.append(JobLogEntry(level: level, message: message))
        job.logs = Array(logs.suffix(200))
    }

    private static func downloadToLocalDirectory(resolution: ProviderResolution, quality: ResolvedQuality, directory: URL, onProgress: @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL {
        guard URLSafetyPolicy.isAllowed(quality.url) else { throw DownloadError.invalidURL }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: quality.url)
        request.timeoutInterval = 60
        quality.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if requiresInitialRange(quality.url), request.value(forHTTPHeaderField: "Range") == nil {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }

        let redirectDelegate = AgentDownloadRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              URLSafetyPolicy.isAllowed(http.url ?? quality.url),
              (200...299).contains(http.statusCode) else {
            throw DownloadError.invalidResponse
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.hasPrefix("video/") || contentType.hasPrefix("audio/") || contentType.hasPrefix("application/octet-stream") else {
            throw DownloadError.unexpectedContentType
        }

        let destination = uniqueDestination(in: directory, title: resolution.title, mediaURL: quality.url)
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var totalWritten: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        let expectedTotal = expectedBytes(from: http)
        defer {
            try? handle.close()
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: partial)
            }
        }

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= 64 * 1_024 {
                try handle.write(contentsOf: buffer)
                totalWritten += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(DownloadProgress(bytesWritten: totalWritten, totalBytes: expectedTotal))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
            await onProgress(DownloadProgress(bytesWritten: totalWritten, totalBytes: expectedTotal))
        }
        guard totalWritten >= 1_024 else { throw DownloadError.responseTooSmall }
        try handle.close()
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    private static func uploadToWebDAV(
        resolution: ProviderResolution,
        quality: ResolvedQuality,
        profile: WebDAVDestinationProfile,
        password: String,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        guard URLSafetyPolicy.isAllowed(quality.url) else { throw DownloadError.invalidURL }
        var sourceRequest = URLRequest(url: quality.url)
        sourceRequest.timeoutInterval = 60
        quality.headers.forEach { sourceRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        if requiresInitialRange(quality.url), sourceRequest.value(forHTTPHeaderField: "Range") == nil {
            sourceRequest.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }

        let sourceSession = URLSession(configuration: .ephemeral, delegate: AgentDownloadRedirectDelegate(), delegateQueue: nil)
        defer { sourceSession.invalidateAndCancel() }
        let (bytes, response) = try await sourceSession.bytes(for: sourceRequest)
        guard let http = response as? HTTPURLResponse,
              URLSafetyPolicy.isAllowed(http.url ?? quality.url),
              (200...299).contains(http.statusCode) else {
            throw DownloadError.invalidResponse
        }
        try validateMediaResponse(http)
        guard let expectedTotal = expectedBytes(from: http) else {
            return try await uploadStagedSourceToWebDAV(
                resolution: resolution,
                quality: quality,
                profile: profile,
                password: password,
                onProgress: onProgress
            )
        }

        let filename = remoteFilename(title: resolution.title, mediaURL: quality.url)
        let destination = webDAVFileURL(profile: profile, filename: filename)
        try await ensureWebDAVDirectories(profile: profile, password: password)

        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7_200
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(expectedTotal), forHTTPHeaderField: "Content-Length")
        applyBasicAuthentication(username: profile.username, password: password, request: &request)

        await onProgress(DownloadProgress(bytesWritten: 0, totalBytes: expectedTotal, phase: .uploading))
        let progressReporter = WebDAVUploadProgressReporter(expectedTotal: expectedTotal, onProgress: onProgress)

        guard let streams = BoundStreams.boundPair(bufferSize: 1_024 * 1_024) else {
            throw RemoteTransferError.streamUnavailable
        }
        request.httpBodyStream = streams.input
        let delegate = WebDAVUploadDelegate(
            allowedHost: profile.baseURL.host,
            allowInvalidCertificate: profile.allowInvalidCertificate,
            progressReporter: progressReporter
        )
        let uploadSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { uploadSession.invalidateAndCancel() }
        streams.output.open()
        let task = uploadSession.uploadTask(withStreamedRequest: request)
        task.resume()

        do {
            var totalWritten: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                if Task.isCancelled { throw CancellationError() }
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 {
                    try streams.output.writeAll(buffer)
                    totalWritten += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try streams.output.writeAll(buffer)
                totalWritten += Int64(buffer.count)
            }
            guard totalWritten >= 1_024 else { throw DownloadError.responseTooSmall }
            streams.output.close()
            try await delegate.waitForCompletion()
            await progressReporter.finishSuccessfully(finalTotal: expectedTotal)
            return destination
        } catch {
            streams.output.close()
            task.cancel()
            await progressReporter.cancelAndWait()
            throw error
        }
    }

    private static func uploadStagedSourceToWebDAV(
        resolution: ProviderResolution,
        quality: ResolvedQuality,
        profile: WebDAVDestinationProfile,
        password: String,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        let stagingDirectory = FileManager.default.temporaryDirectory.appending(path: "lustre-webdav-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagedFile = try await downloadToLocalDirectory(
            resolution: resolution,
            quality: quality,
            directory: stagingDirectory,
            onProgress: onProgress
        )
        let destination = webDAVFileURL(profile: profile, filename: remoteFilename(title: resolution.title, mediaURL: quality.url))
        try await ensureWebDAVDirectories(profile: profile, password: password)
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7_200
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        applyBasicAuthentication(username: profile.username, password: password, request: &request)
        let size = (try stagedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        await onProgress(DownloadProgress(bytesWritten: 0, totalBytes: size, phase: .uploading))
        let progressReporter = WebDAVUploadProgressReporter(expectedTotal: size, onProgress: onProgress)
        let transport = WebDAVTLSDelegate(
            host: profile.baseURL.host,
            allowInvalidCertificate: profile.allowInvalidCertificate,
            progressReporter: progressReporter
        )
        do {
            let (_, response) = try await transport.upload(for: request, fromFile: stagedFile)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RemoteTransferError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            await progressReporter.finishSuccessfully(finalTotal: size)
            return destination
        } catch {
            await progressReporter.cancelAndWait()
            throw error
        }
    }

    private static func uploadMaterializedFileToWebDAV(
        resolution: ProviderResolution,
        quality: ResolvedQuality,
        file: URL,
        profile: WebDAVDestinationProfile,
        password: String,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void
    ) async throws -> URL {
        guard file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw DownloadError.invalidResponse
        }
        let size = (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        await onProgress(DownloadProgress(bytesWritten: 0, totalBytes: size, phase: .uploading))
        let destination = webDAVFileURL(profile: profile, filename: file.lastPathComponent)
        try await ensureWebDAVDirectories(profile: profile, password: password)
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7_200
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        applyBasicAuthentication(username: profile.username, password: password, request: &request)
        let progressReporter = WebDAVUploadProgressReporter(expectedTotal: size, onProgress: onProgress)
        let transport = WebDAVTLSDelegate(
            host: profile.baseURL.host,
            allowInvalidCertificate: profile.allowInvalidCertificate,
            progressReporter: progressReporter
        )
        do {
            let (_, response) = try await transport.upload(for: request, fromFile: file)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw RemoteTransferError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            await progressReporter.finishSuccessfully(finalTotal: size)
            return destination
        } catch {
            await progressReporter.cancelAndWait()
            throw error
        }
    }

    private static func testWebDAVDestination(
        profile: WebDAVDestinationProfile,
        password: String
    ) async throws -> RemoteDestinationTestResult {
        try await ensureWebDAVDirectories(profile: profile, password: password)
        let testFile = ".lustre-connection-test-\(UUID().uuidString).tmp"
        let destination = webDAVFileURL(profile: profile, filename: testFile)
        var putRequest = URLRequest(url: destination)
        putRequest.httpMethod = "PUT"
        putRequest.timeoutInterval = 30
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        applyBasicAuthentication(username: profile.username, password: password, request: &putRequest)
        let body = Data("Lustre WebDAV write test".utf8)
        let transport = WebDAVTLSDelegate(host: profile.baseURL.host, allowInvalidCertificate: profile.allowInvalidCertificate)
        let (_, putResponse) = try await transport.upload(for: putRequest, from: body)
        guard let putHTTP = putResponse as? HTTPURLResponse, (200...299).contains(putHTTP.statusCode) else {
            throw RemoteTransferError.uploadFailed((putResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }

        var deleteRequest = URLRequest(url: destination)
        deleteRequest.httpMethod = "DELETE"
        deleteRequest.timeoutInterval = 30
        applyBasicAuthentication(username: profile.username, password: password, request: &deleteRequest)
        let (_, deleteResponse) = try await transport.data(for: deleteRequest)
        guard let deleteHTTP = deleteResponse as? HTTPURLResponse, (200...299).contains(deleteHTTP.statusCode) else {
            throw RemoteTransferError.testCleanupFailed((deleteResponse as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return RemoteDestinationTestResult(message: "WebDAV connection and write test succeeded.")
    }

    private static func ensureWebDAVDirectories(profile: WebDAVDestinationProfile, password: String) async throws {
        var current = profile.baseURL
        for component in profile.remotePath.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component), isDirectory: true)
            var request = URLRequest(url: current)
            request.httpMethod = "MKCOL"
            request.timeoutInterval = 30
            applyBasicAuthentication(username: profile.username, password: password, request: &request)
            let transport = WebDAVTLSDelegate(host: profile.baseURL.host, allowInvalidCertificate: profile.allowInvalidCertificate)
            let (_, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  [200, 201, 204, 301, 405].contains(http.statusCode) else {
                throw RemoteTransferError.directoryCreationFailed
            }
        }
    }

    private static func webDAVFileURL(profile: WebDAVDestinationProfile, filename: String) -> URL {
        var result = profile.baseURL
        for component in profile.remotePath.split(separator: "/", omittingEmptySubsequences: true) {
            result.appendPathComponent(String(component), isDirectory: true)
        }
        result.appendPathComponent(filename, isDirectory: false)
        return result
    }

    private static func applyBasicAuthentication(username: String, password: String, request: inout URLRequest) {
        let value = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
    }
}

enum AgentServiceError: Error, LocalizedError {
    case invalidURL
    case unsupportedDestination
    case invalidDestination
    case folderSelectionCancelled
    case noProviderResolved
    case noSelectedQuality

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Only absolute HTTP(S) URLs can be processed."
        case .unsupportedDestination: "Download destinations must be absolute local folder paths."
        case .invalidDestination: "The selected download destination is not an accessible folder."
        case .folderSelectionCancelled: "Folder selection was cancelled."
        case .noProviderResolved: "No provider resolved usable media from the source page."
        case .noSelectedQuality: "The requested quality was not available after resolving the source page."
        }
    }
}

private enum DownloadError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case unexpectedContentType
    case responseTooSmall

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The media URL is not safe to fetch."
        case .invalidResponse: "The provider did not return a successful media response."
        case .unexpectedContentType: "The provider returned an HTML, JSON, or XML response instead of media."
        case .responseTooSmall: "The provider response was too small to be a media file."
        }
    }
}

private enum RemoteTransferError: Error, LocalizedError {
    case sourceLengthUnavailable
    case streamUnavailable
    case streamWriteFailed
    case directoryCreationFailed
    case uploadFailed(Int)
    case testCleanupFailed(Int)

    var errorDescription: String? {
        switch self {
        case .sourceLengthUnavailable: "The media server did not provide a file size, so Lustre cannot stream this source directly to WebDAV."
        case .streamUnavailable: "Lustre could not create the direct transfer stream."
        case .streamWriteFailed: "Writing the direct transfer stream failed."
        case .directoryCreationFailed: "Lustre could not create the remote WebDAV directory."
        case .uploadFailed(let status): "The WebDAV server rejected the upload (HTTP \(status))."
        case .testCleanupFailed(let status): "Lustre could not remove its temporary WebDAV test file (HTTP \(status))."
        }
    }
}

private struct BoundStreams {
    let input: InputStream
    let output: OutputStream

    static func boundPair(bufferSize: Int) -> BoundStreams? {
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: bufferSize, inputStream: &input, outputStream: &output)
        guard let input, let output else { return nil }
        return BoundStreams(input: input, output: output)
    }
}

private extension OutputStream {
    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = write(base.advanced(by: offset), maxLength: rawBuffer.count - offset)
                guard written > 0 else { throw RemoteTransferError.streamWriteFailed }
                offset += written
            }
        }
    }
}

private enum WebDAVTLSTrust {
    static func handle(_ challenge: URLAuthenticationChallenge, allowedHost: String?, allowInvalidCertificate: Bool, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard allowInvalidCertificate,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == allowedHost?.lowercased(),
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class WebDAVUploadProgressReporter: @unchecked Sendable {
    private let expectedTotal: Int64?
    private let onProgress: @Sendable (DownloadProgress) async -> Void
    private let lock = NSLock()
    private var latestPending: DownloadProgress?
    private var deliveryTask: Task<Void, Never>?
    private var stopped = false

    init(
        expectedTotal: Int64?,
        onProgress: @escaping @Sendable (DownloadProgress) async -> Void
    ) {
        self.expectedTotal = expectedTotal.map { max(0, $0) }
        self.onProgress = onProgress
    }

    func didSend(totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let reportedTotal = totalBytesExpectedToSend >= 0 ? totalBytesExpectedToSend : expectedTotal
        let total = reportedTotal.map { max(0, $0) }
        let sent = total.map { min(max(0, totalBytesSent), $0) } ?? max(0, totalBytesSent)
        let progress = DownloadProgress(bytesWritten: sent, totalBytes: total, phase: .uploading)

        lock.withLock {
            guard !stopped else { return }
            latestPending = progress
            if deliveryTask == nil {
                deliveryTask = Task { [weak self] in
                    await self?.deliverPending()
                }
            }
        }
    }

    func finishSuccessfully(finalTotal: Int64?) async {
        if let finalTotal {
            didSend(totalBytesSent: finalTotal, totalBytesExpectedToSend: finalTotal)
        }
        await waitForDelivery()
        lock.withLock {
            stopped = true
            latestPending = nil
        }
    }

    func cancelAndWait() async {
        let task = lock.withLock {
            stopped = true
            latestPending = nil
            return deliveryTask
        }
        task?.cancel()
        await task?.value
    }

    private func deliverPending() async {
        while !Task.isCancelled {
            let progress = lock.withLock { () -> DownloadProgress? in
                guard !stopped, let progress = latestPending else {
                    deliveryTask = nil
                    return nil
                }
                latestPending = nil
                return progress
            }
            guard let progress else { return }
            await onProgress(progress)
        }
        lock.withLock {
            deliveryTask = nil
        }
    }

    private func waitForDelivery() async {
        while true {
            let task = lock.withLock { deliveryTask }
            guard let task else { return }
            await task.value
        }
    }
}

private final class WebDAVTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHost: String?
    private let allowInvalidCertificate: Bool
    private let progressReporter: WebDAVUploadProgressReporter?

    init(host: String?, allowInvalidCertificate: Bool, progressReporter: WebDAVUploadProgressReporter? = nil) {
        self.allowedHost = host?.lowercased()
        self.allowInvalidCertificate = allowInvalidCertificate
        self.progressReporter = progressReporter
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressReporter?.didSend(totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            session.uploadTask(with: request, from: data) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let taskBox = WebDAVUploadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                taskBox.store(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

private final class WebDAVUploadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionUploadTask?
    private var cancelled = false

    func store(_ task: URLSessionUploadTask) {
        let shouldCancel = lock.withLock {
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

private final class WebDAVUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowedHost: String?
    private let allowInvalidCertificate: Bool
    private let progressReporter: WebDAVUploadProgressReporter
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var responseStatus: Int?

    init(allowedHost: String?, allowInvalidCertificate: Bool, progressReporter: WebDAVUploadProgressReporter) {
        self.allowedHost = allowedHost?.lowercased()
        self.allowInvalidCertificate = allowInvalidCertificate
        self.progressReporter = progressReporter
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressReporter.didSend(totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            responseStatus = (response as? HTTPURLResponse)?.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: Result<Void, Error>
        let status = lock.withLock { responseStatus }
        if let error {
            completion = .failure(error)
        } else if let status, !(200...299).contains(status) {
            completion = .failure(RemoteTransferError.uploadFailed(status))
        } else {
            completion = .success(())
        }
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: completion)
        } else {
            result = completion
            lock.unlock()
        }
    }

    func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class AgentDownloadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url ?? task.originalRequest?.url ?? response.url else {
            completionHandler(nil)
            return
        }
        completionHandler(URLSafetyPolicy.isAllowed(redirectURL) ? request : nil)
    }

}

private func expectedBytes(from response: HTTPURLResponse?) -> Int64? {
    guard let response else { return nil }
    if response.expectedContentLength > 0 { return response.expectedContentLength }
    if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
       let total = contentRange.split(separator: "/", maxSplits: 1).last.flatMap({ Int64($0) }),
       total > 0 {
        return total
    }
    return response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
}

private func validateMediaResponse(_ response: HTTPURLResponse) throws {
    let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    guard contentType.hasPrefix("video/") || contentType.hasPrefix("audio/") || contentType.hasPrefix("application/octet-stream") else {
        throw DownloadError.unexpectedContentType
    }
}

private func requiresInitialRange(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "cloudatacdn.com" || host.hasSuffix(".cloudatacdn.com") || host == "mxcontent.net" || host.hasSuffix(".mxcontent.net")
}

private func uniqueDestination(in directory: URL, title: String?, mediaURL: URL) -> URL {
    FilenamePolicy.uniqueLocalURL(directory: directory, title: title, mediaURL: mediaURL)
}

private func remoteFilename(title: String?, mediaURL: URL) -> String {
    FilenamePolicy.remoteFilename(title: title, mediaURL: mediaURL)
}
