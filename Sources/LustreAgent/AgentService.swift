import Foundation
import LustreCore
import Security

public actor AgentService {
    public typealias Downloader = @Sendable (ProviderResolution, ResolvedQuality, URL) async throws -> URL
    public typealias ProgressDownloader = @Sendable (ProviderResolution, ResolvedQuality, URL, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias RemoteProgressDownloader = @Sendable (ProviderResolution, ResolvedQuality, WebDAVDestinationProfile, String, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias HLSMaterializer = @Sendable (ProviderResolution, ResolvedQuality, URL, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias PornHubResolver = @Sendable (URL) async throws -> ProviderResolution
    public typealias YtDlpMaterializer = @Sendable (ProviderResolution, ResolvedQuality, URL, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias StagedRemoteUploader = @Sendable (ProviderResolution, ResolvedQuality, URL, WebDAVDestinationProfile, String, @escaping @Sendable (DownloadProgress) async -> Void) async throws -> URL
    public typealias RemoteDestinationTester = @Sendable (WebDAVDestinationProfile, String) async throws -> RemoteDestinationTestResult
    public typealias FolderPicker = @Sendable () throws -> String

    private struct ActiveDownload {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let jobs: JobStore
    private let resolver: StaticProviderResolver
    private let downloadsDirectory: URL
    private let automaticallyStartsDownloads: Bool
    private let progressDownloader: ProgressDownloader
    private let remoteDownloader: RemoteProgressDownloader
    private let hlsMaterializer: HLSMaterializer
    private let pornHubResolver: PornHubResolver
    private let ytDlpMaterializer: YtDlpMaterializer
    private let stagedRemoteUploader: StagedRemoteUploader
    private let remoteDestinationTester: RemoteDestinationTester
    private let destinationProfiles: RemoteDestinationProfileStore
    private let destinationSecrets: RemoteDestinationSecretStore
    private let folderPicker: FolderPicker
    private let feed: FeedService
    private let pornHubAuth: PornHubAuthService
    private let maximumConcurrentDownloads: Int
    private var activeDownloadTasks: [UUID: ActiveDownload] = [:]
    private var lastProgressUpdates: [UUID: (bytesWritten: Int64, timestamp: Date)] = [:]

    public init(
        databaseURL: URL = AgentPaths.database,
        resolver: StaticProviderResolver = StaticProviderResolver(),
        downloadsDirectory: URL = AgentPaths.downloads,
        automaticallyStartsDownloads: Bool = true,
        downloader: Downloader? = nil,
        progressDownloader: ProgressDownloader? = nil,
        folderPicker: FolderPicker? = nil,
        destinationProfiles: RemoteDestinationProfileStore? = nil,
        destinationSecrets: RemoteDestinationSecretStore = KeychainRemoteDestinationSecretStore(),
        remoteDownloader: RemoteProgressDownloader? = nil,
        hlsMaterializer: HLSMaterializer? = nil,
        pornHubResolver: PornHubResolver? = nil,
        ytDlpMaterializer: YtDlpMaterializer? = nil,
        stagedRemoteUploader: StagedRemoteUploader? = nil,
        remoteDestinationTester: RemoteDestinationTester? = nil,
        feed: FeedService? = nil,
        pornHubAuth: PornHubAuthService = PornHubAuthService(),
        maximumConcurrentDownloads: Int = 1
    ) throws {
        self.jobs = try JobStore(databaseURL: databaseURL)
        self.resolver = resolver
        self.downloadsDirectory = downloadsDirectory
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
        self.destinationSecrets = destinationSecrets
        self.remoteDownloader = remoteDownloader ?? AgentService.uploadToWebDAV
        self.hlsMaterializer = hlsMaterializer ?? FFmpegHLSMaterializer.materialize
        self.pornHubAuth = pornHubAuth
        self.pornHubResolver = pornHubResolver ?? { source in
            let cookies = (try? await pornHubAuth.cookiesForYtDlp()) ?? []
            do { return try await PornHubYtDlp.resolve(source: source, cookies: cookies) }
            catch let error as PornHubYtDlpError {
                if !cookies.isEmpty { await pornHubAuth.recordYtDlpFailure(error) }
                throw error
            }
        }
        self.ytDlpMaterializer = ytDlpMaterializer ?? { resolution, quality, directory, _ in
            guard let selector = quality.formatSelector else { throw PornHubYtDlpError.invalidFormat }
            let cookies = (try? await pornHubAuth.cookiesForYtDlp()) ?? []
            do { return try await PornHubYtDlp.materialize(source: resolution.sourcePageURL, formatSelector: selector, directory: directory, cookies: cookies) }
            catch let error as PornHubYtDlpError {
                if !cookies.isEmpty { await pornHubAuth.recordYtDlpFailure(error) }
                throw error
            }
        }
        self.stagedRemoteUploader = stagedRemoteUploader ?? AgentService.uploadMaterializedFileToWebDAV
        self.remoteDestinationTester = remoteDestinationTester ?? AgentService.testWebDAVDestination
        self.folderPicker = folderPicker ?? AgentService.chooseDownloadFolder
        self.feed = feed ?? FeedService(fetch: PornHubFeedRequest.fetch, pornHubCookieHeader: { url in try await pornHubAuth.cookieHeader(for: url) })
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        Task { [weak self] in
            await self?.recoverDurableJobs()
        }
    }

    public func health() -> [String: String] {
        ["status": "ok"]
    }

    public func allJobs() async throws -> [DownloadJob] {
        try await jobs.allJobs()
    }

    public func feedSites() async -> [FeedSite] {
        let sites = feed.sites()
        return await pornHubAuth.status().state == .signedIn ? sites + FeedSite.authenticatedPornHub : sites
    }

    public func feedPage(site: FeedSiteID, page: Int) async throws -> FeedPage {
        try await feed.page(site: site, page: page)
    }

    public func pornHubAuthStatus() async -> PornHubAuthStatus { await pornHubAuth.status() }
    public func signInWithPornHub() async throws -> PornHubAuthStatus { try await pornHubAuth.login() }
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

    public func extract(url: URL) async throws -> ExtractionResult {
        guard URLSafetyPolicy.isAllowed(url) else {
            throw AgentServiceError.invalidURL
        }
        if AllPornStreamResolver.isAllPornStreamPostURL(url) {
            return await extractAllPornStream(url: url)
        }
        if let canonical = PornHubURL.canonical(url) {
            let resolution = try await pornHubResolver(canonical)
            return ExtractionResult(
                sourcePageURL: canonical,
                isDirectMedia: false,
                resolutionState: "resolved",
                trace: resolution.trace,
                resolution: resolution
            )
        }
        do {
            let resolution = try await resolver.resolve(url: url)
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: resolution.provider == .direct,
                resolutionState: "resolved",
                trace: resolution.trace,
                resolution: resolution
            )
        } catch ProviderResolverError.cloudflareChallenge {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "verificationRequired",
                trace: ["Provider requires interactive browser verification; no WebKit fallback is installed in the agent."]
            )
        } catch ProviderResolverError.unsupportedProvider {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "pendingProviderResolver",
                trace: ["Stored original source page URL.", "No static resolver is installed for this provider."]
            )
        }
    }

    private func extractAllPornStream(url: URL) async -> ExtractionResult {
        let resolver = AllPornStreamResolver(fetch: resolver.pageFetch, providerResolver: resolver)
        do {
            let aggregate = try await resolver.resolve(postURL: url)
            let state: String
            if !aggregate.resolution.qualities.isEmpty {
                state = "resolved"
            } else if aggregate.attempts.contains(where: { $0.outcome == .verificationRequired }) {
                state = "verificationRequired"
            } else {
                state = "staticResolutionFailed"
            }
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: state,
                trace: aggregate.resolution.trace,
                resolution: aggregate.resolution,
                providerAttempts: aggregate.attempts
            )
        } catch {
            return ExtractionResult(
                sourcePageURL: url,
                isDirectMedia: false,
                resolutionState: "staticResolutionFailed",
                trace: ["AllPornStream post resolution failed: \(error.localizedDescription)"],
                providerAttempts: []
            )
        }
    }

    public func createJob(_ request: CreateJobRequest) async throws -> DownloadJob {
        guard URLSafetyPolicy.isAllowed(request.sourcePageURL) else {
            throw AgentServiceError.invalidURL
        }
        let destination = try await normalizedDestination(request.destination)
        let preferredQualityLabel = request.preferredQualityLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var job = DownloadJob(
            sourcePageURL: request.sourcePageURL,
            preferredQualityLabel: preferredQualityLabel?.isEmpty == false ? preferredQualityLabel : nil,
            destination: destination
        )
        record(&job, level: .info, message: RemoteDestination.webDAVProfileID(from: destination) == nil ? "Queued for local download." : "Queued for remote WebDAV download.")
        try await jobs.create(job)
        if automaticallyStartsDownloads { await enqueueDownload(job.id) }
        return job
    }

    public func selectDownloadFolder() async throws -> String {
        let picker = folderPicker
        let selectedPath = try await Task.detached(operation: picker).value
        return try await normalizedDestination(selectedPath)
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

            let extraction = try await extract(url: job.sourcePageURL)
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
            guard let resolution = extraction.resolution,
                  let quality = selectedQuality(in: resolution, preferredLabel: active.preferredQualityLabel) else {
                throw AgentServiceError.noSelectedQuality
            }

            guard ownsDownload(id, taskID: taskID) else { return }
            record(&active, level: .info, message: "Downloading \(quality.label).")
            active.progress = nil
            active.downloadedBytes = 0
            active.totalBytes = nil
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
            if quality.mediaKind != .direct, let profileID = RemoteDestination.webDAVProfileID(from: current.destination) {
                guard let profile = await destinationProfiles.profile(id: profileID) else { throw RemoteDestinationError.notFound }
                guard let password = try destinationSecrets.password(for: profileID), !password.isEmpty else {
                    throw RemoteDestinationError.missingCredentials
                }
                record(&active, level: .info, message: "Materializing \(quality.label) before upload to \(profile.name).")
                try await jobs.update(active)
                let staging = FileManager.default.temporaryDirectory.appending(path: "lustre-materialized-\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: staging) }
                let media = quality.mediaKind == .hls
                    ? try await hlsMaterializer(resolution, quality, staging, reportProgress)
                    : try await ytDlpMaterializer(resolution, quality, staging, reportProgress)
                output = try await stagedRemoteUploader(resolution, quality, media, profile, password, reportProgress)
            } else if quality.mediaKind == .hls {
                output = try await hlsMaterializer(resolution, quality, try downloadDirectory(for: current.destination), reportProgress)
            } else if quality.mediaKind == .ytDlp {
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
        let now = Date()
        if let last = lastProgressUpdates[id],
           progress.bytesWritten - last.bytesWritten < 512 * 1_024,
           now.timeIntervalSince(last.timestamp) < 0.5,
           progress.fraction != 1 {
            return
        }
        lastProgressUpdates[id] = (progress.bytesWritten, now)
        job.progress = progress.fraction
        job.downloadedBytes = progress.bytesWritten
        job.totalBytes = progress.totalBytes
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

    private func selectedQuality(in resolution: ProviderResolution, preferredLabel: String?) -> ResolvedQuality? {
        guard let preferredLabel = preferredLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !preferredLabel.isEmpty else {
            return resolution.qualities.first
        }
        return resolution.qualities.first { $0.label == preferredLabel }
    }

    private func normalizedDestination(_ value: String?) async throws -> String {
        guard let value, value != "local" else { return "local" }
        if let profileID = RemoteDestination.webDAVProfileID(from: value) {
            guard await destinationProfiles.profile(id: profileID) != nil else { throw RemoteDestinationError.notFound }
            return RemoteDestination.webDAV(profileID)
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

        guard let streams = BoundStreams.boundPair(bufferSize: 1_024 * 1_024) else {
            throw RemoteTransferError.streamUnavailable
        }
        request.httpBodyStream = streams.input
        let delegate = WebDAVUploadDelegate(allowedHost: profile.baseURL.host, allowInvalidCertificate: profile.allowInvalidCertificate)
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
                    await onProgress(DownloadProgress(bytesWritten: totalWritten, totalBytes: expectedTotal))
                }
            }
            if !buffer.isEmpty {
                try streams.output.writeAll(buffer)
                totalWritten += Int64(buffer.count)
                await onProgress(DownloadProgress(bytesWritten: totalWritten, totalBytes: expectedTotal))
            }
            guard totalWritten >= 1_024 else { throw DownloadError.responseTooSmall }
            streams.output.close()
            try await delegate.waitForCompletion()
            return destination
        } catch {
            streams.output.close()
            task.cancel()
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
        let transport = WebDAVTLSDelegate(host: profile.baseURL.host, allowInvalidCertificate: profile.allowInvalidCertificate)
        let (_, response) = try await transport.upload(for: request, fromFile: stagedFile)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RemoteTransferError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return destination
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
        let destination = webDAVFileURL(profile: profile, filename: file.lastPathComponent)
        try await ensureWebDAVDirectories(profile: profile, password: password)
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.timeoutInterval = 7_200
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        applyBasicAuthentication(username: profile.username, password: password, request: &request)
        let transport = WebDAVTLSDelegate(host: profile.baseURL.host, allowInvalidCertificate: profile.allowInvalidCertificate)
        let (_, response) = try await transport.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw RemoteTransferError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if let size { await onProgress(DownloadProgress(bytesWritten: size, totalBytes: size)) }
        return destination
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
    case noSelectedQuality

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Only absolute HTTP(S) URLs can be processed."
        case .unsupportedDestination: "Download destinations must be absolute local folder paths."
        case .invalidDestination: "The selected download destination is not an accessible folder."
        case .folderSelectionCancelled: "Folder selection was cancelled."
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

private final class WebDAVTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHost: String?
    private let allowInvalidCertificate: Bool

    init(host: String?, allowInvalidCertificate: Bool) {
        self.allowedHost = host?.lowercased()
        self.allowInvalidCertificate = allowInvalidCertificate
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
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
        return try await withCheckedThrowingContinuation { continuation in
            session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
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
}

private final class WebDAVUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowedHost: String?
    private let allowInvalidCertificate: Bool
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var responseStatus: Int?

    init(allowedHost: String?, allowInvalidCertificate: Bool) {
        self.allowedHost = allowedHost?.lowercased()
        self.allowInvalidCertificate = allowInvalidCertificate
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebDAVTLSTrust.handle(challenge, allowedHost: allowedHost, allowInvalidCertificate: allowInvalidCertificate, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        responseStatus = (response as? HTTPURLResponse)?.statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: Result<Void, Error>
        if let error {
            completion = .failure(error)
        } else if let status = responseStatus, !(200...299).contains(status) {
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
    let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : "Lustre-video"
    let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
    let base = rawTitle.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        .reduce(into: "") { $0.append($1) }
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "-")
    let filenameBase = base.isEmpty ? "Lustre-video" : base
    let fileExtension = mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension.lowercased()
    var index = 0
    while true {
        let suffix = index == 0 ? "" : "-\(index)"
        let candidate = directory.appendingPathComponent("\(filenameBase)\(suffix).\(fileExtension)")
        if !FileManager.default.fileExists(atPath: candidate.path) && !FileManager.default.fileExists(atPath: candidate.appendingPathExtension("part").path) {
            return candidate
        }
        index += 1
    }
}

private func remoteFilename(title: String?, mediaURL: URL) -> String {
    let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? title! : "Lustre-video"
    let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
    let base = rawTitle.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        .reduce(into: "") { $0.append($1) }
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: " ", with: "-")
    let filenameBase = base.isEmpty ? "Lustre-video" : base
    let fileExtension = mediaURL.pathExtension.isEmpty ? "mp4" : mediaURL.pathExtension.lowercased()
    return "\(filenameBase)-\(UUID().uuidString.prefix(8).lowercased()).\(fileExtension)"
}
