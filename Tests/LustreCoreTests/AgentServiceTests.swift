import Foundation
import LustreAgent
import LustreCore
import XCTest

final class AgentServiceTests: XCTestCase {
    func testCreateJobUsesCallerSuppliedIDAndCannotCreateASecondJobForIt() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-command-id-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, automaticallyStartsDownloads: false)
        let id = UUID()
        let source = URL(string: "https://hqporner.com/hdporn/example.html")!

        let created = try await service.createJob(CreateJobRequest(id: id, sourcePageURL: source))
        let stored = try await service.job(id: id)

        XCTAssertEqual(created.id, id)
        XCTAssertEqual(stored, created)
        do {
            _ = try await service.createJob(CreateJobRequest(id: id, sourcePageURL: source))
            XCTFail("Expected the immutable job ID to reject a duplicate insert.")
        } catch {
            let jobIDs = try await service.allJobs().map(\.id)
            XCTAssertEqual(jobIDs, [id])
        }
    }

    func testExtractSurfacesStaticProviderResolution() async throws {
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-service-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver)

        let result = try await service.extract(url: URL(string: "https://mixdrop.co/e/xyz")!)

        XCTAssertEqual(result.resolutionState, "resolved")
        XCTAssertEqual(result.resolution?.provider, .mixDrop)
        XCTAssertEqual(result.resolution?.qualities.first?.url.absoluteString, "https://cdn.mxcontent.net/video.mp4")
    }

    func testExtractFallsBackToGenericYtDlpOnlyForUnsupportedStaticProvider() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-generic-ytdlp-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let source = URL(string: "https://www.eporner.com/video-example")!
        let expected = ProviderResolution(
            sourcePageURL: source,
            provider: .ytDlp,
            title: "Generic video",
            qualities: [
                ResolvedQuality(
                    label: "1080p MP4",
                    url: source,
                    resolutionMethod: "Agent generic yt-dlp metadata",
                    mediaKind: .ytDlp,
                    formatSelector: "v1080+a1"
                )
            ],
            trace: ["Generic fallback used."]
        )
        let service = try AgentService(
            databaseURL: database,
            automaticallyStartsDownloads: false,
            genericYtDlpResolver: { url in
                XCTAssertEqual(url, source)
                return expected
            }
        )

        let result = try await service.extract(url: source)

        XCTAssertEqual(result.resolutionState, "resolved")
        XCTAssertEqual(result.resolution, expected)
    }

    func testExtractReturnsAggregateAllPornStreamResolution() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/example")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(
                        body: #"""
                        <script id="__NEXT_DATA__" type="application/json">{
                          "title":"Aggregate title",
                          "thumbnail_url":"https://images.example.com/cover.jpg",
                          "video_urls":[
                            {"hosting_provider":"MIXDROP","file_code":"mix-1","link":"https://mixdrop.co/f/mix-1"},
                            {"hosting_provider":"MIXDROP","file_code":"mix-1","iframe":"https://mixdrop.co/e/mix-1"}
                          ]
                        }</script>
                        """#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                return HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-allpornstream-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver)

        let result = try await service.extract(url: postURL)

        XCTAssertEqual(result.resolutionState, "resolved")
        XCTAssertEqual(result.sourcePageURL, postURL)
        XCTAssertEqual(result.resolution?.sourcePageURL, postURL)
        XCTAssertEqual(result.resolution?.title, "Aggregate title")
        XCTAssertEqual(result.resolution?.thumbnailURL?.absoluteString, "https://images.example.com/cover.jpg")
        XCTAssertEqual(result.resolution?.qualities.first?.label, "MIXDROP · Video")
        XCTAssertEqual(result.resolution?.qualities.first?.url.absoluteString, "https://cdn.mxcontent.net/video.mp4")
    }

    func testExtractKeepsFailedAllPornStreamProviderAttemptsWithPartialSuccess() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/partial")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(
                        body: #"{"video_urls":[{"hosting_provider":"MIXDROP","file_code":"mix","iframe":"https://mixdrop.co/e/mix"},{"hosting_provider":"VIDARA","file_code":"vidara","iframe":"https://vidara.example/e/vidara"}]}"#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                return HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-partial-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver)

        let result = try await service.extract(url: postURL)

        XCTAssertEqual(result.resolutionState, "resolved")
        XCTAssertEqual(result.providerAttempts.map(\.outcome), [.resolved, .failed])
        XCTAssertEqual(result.providerAttempts.last?.reason, "No static resolver is installed for this hosting_provider.")
        XCTAssertTrue(result.trace.contains { $0.contains("VIDARA failed") })
    }

    func testExtractEscalatesAllPornStreamCloudflareOnlyAfterAllProvidersFail() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/verification")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(
                        body: #"{"video_urls":[{"hosting_provider":"DOODSTREAM","file_code":"dood","iframe":"https://alias.example/e/dood"},{"hosting_provider":"VIDARA","file_code":"vidara","iframe":"https://vidara.example/e/vidara"}]}"#,
                        finalURL: url,
                        statusCode: 200
                    )
                }
                return HTTPPage(body: "<html>cf-mitigated: challenge</html>", finalURL: url, statusCode: 403)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-verification-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver)

        let result = try await service.extract(url: postURL)

        XCTAssertEqual(result.resolutionState, "verificationRequired")
        XCTAssertEqual(result.providerAttempts.map(\.outcome), [.verificationRequired, .failed])
        XCTAssertTrue(result.trace.contains { $0.contains("requires verification") })
    }

    func testExtractRetriesChallengedAllPornStreamPostWithVerifiedRenderedHTML() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/rendered")!
        let providerURL = URL(string: "https://mixdrop.co/e/rendered")!
        let renderer = AllPornStreamRenderTracker(html: #"{"video_urls":[{"hosting_provider":"MIXDROP","iframe":"https://mixdrop.co/e/rendered"}]}"#)
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == postURL {
                    return HTTPPage(body: "<html>cf-mitigated: challenge</html>", finalURL: url, statusCode: 403)
                }
                XCTAssertEqual(url, providerURL)
                return HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/rendered.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-rendered-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            allPornStreamHTML: { url in await renderer.render(url: url) }
        )

        let result = try await service.extract(url: postURL)
        let requestedURLs = await renderer.requestedURLs()

        XCTAssertEqual(result.resolutionState, "resolved")
        XCTAssertEqual(result.resolution?.qualities.first?.url.absoluteString, "https://cdn.mxcontent.net/rendered.mp4")
        XCTAssertEqual(requestedURLs, [postURL])
    }

    func testExtractReturnsStaticFailureDiagnosticsWhenNoAllPornStreamProviderWorks() async throws {
        let postURL = URL(string: "https://allpornstream.com/post/unsupported")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"{"title":"Unsupported post","video_urls":[{"hosting_provider":"VIDARA","file_code":"vidara","iframe":"https://vidara.example/e/vidara"}]}"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-static-failure-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver)

        let result = try await service.extract(url: postURL)

        XCTAssertEqual(result.resolutionState, "noProviderResolved")
        XCTAssertEqual(result.resolution?.title, "Unsupported post")
        XCTAssertEqual(result.providerAttempts.first?.outcome, .failed)
        XCTAssertTrue(result.trace.contains { $0.contains("No static resolver") })
    }

    func testQueuedJobReportsNoProviderResolvedSeparatelyFromUnavailableQuality() async throws {
        let noProviderURL = URL(string: "https://allpornstream.com/post/no-provider")!
        let qualityURL = URL(string: "https://mixdrop.co/e/quality")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                if url == noProviderURL {
                    return HTTPPage(body: #"{"video_urls":[{"hosting_provider":"VIDARA","iframe":"https://vidara.example/e/no-provider"}]}"#, finalURL: url, statusCode: 200)
                }
                return HTTPPage(body: #"<script>MDCore.wurl = "https://edge.mxcontent.net/v2/quality.mp4"</script>"#, finalURL: url, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-resolution-errors-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let service = try AgentService(databaseURL: database, resolver: resolver, automaticallyStartsDownloads: false)

        let noProviderJob = try await service.createJob(CreateJobRequest(sourcePageURL: noProviderURL))
        let unavailableQualityJob = try await service.createJob(CreateJobRequest(sourcePageURL: qualityURL, preferredQualityLabel: "1080p"))
        await service.processQueuedJob(id: noProviderJob.id)
        await service.processQueuedJob(id: unavailableQualityJob.id)
        let jobs = try await service.allJobs()

        XCTAssertEqual(jobs.first(where: { $0.id == noProviderJob.id })?.message, "Download failed: No provider resolved usable media from the source page.")
        XCTAssertEqual(jobs.first(where: { $0.id == unavailableQualityJob.id })?.message, "Download failed: The requested quality was not available after resolving the source page.")
    }

    func testProcessesQueuedJobByReresolvingAndPassingQualityHeadersToDownloader() async throws {
        let sourceURL = URL(string: "https://mixdrop.co/e/xyz")!
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-download-\(UUID().uuidString).sqlite3")
        let downloadsDirectory = FileManager.default.temporaryDirectory.appending(path: "lustre-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<title>Queue video</title><script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: downloadsDirectory,
            automaticallyStartsDownloads: false,
            downloader: { resolution, quality, directory in
                XCTAssertEqual(resolution.title, "Queue video")
                XCTAssertEqual(quality.url.absoluteString, "https://cdn.mxcontent.net/video.mp4")
                XCTAssertEqual(quality.headers["Referer"], sourceURL.absoluteString)
                XCTAssertEqual(directory, downloadsDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appending(path: "queue-video.mp4")
                try Data("video bytes".utf8).write(to: file)
                return file
            }
        )

        let job = try await service.createJob(CreateJobRequest(sourcePageURL: sourceURL, preferredQualityLabel: "   ", destination: downloadsDirectory.path))
        await service.processQueuedJob(id: job.id)
        let jobs = try await service.allJobs()
        let completed = try XCTUnwrap(jobs.first)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.message, "Completed: queue-video.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadsDirectory.appending(path: "queue-video.mp4").path))
    }

    func testProcessesQueuedJobDirectlyToSavedWebDAVDestination() async throws {
        let sourceURL = URL(string: "https://mixdrop.co/e/remote")!
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-remote-\(UUID().uuidString).sqlite3")
        let profilesURL = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-remote-profiles-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: profilesURL)
        }
        let profileStore = try RemoteDestinationProfileStore(fileURL: profilesURL)
        let secretStore = TestRemoteDestinationSecretStore()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<title>Remote video</title><script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            automaticallyStartsDownloads: false,
            destinationProfiles: profileStore,
            destinationSecrets: secretStore,
            remoteDownloader: { resolution, quality, profile, password, progress in
                XCTAssertEqual(resolution.title, "Remote video")
                XCTAssertEqual(quality.url.absoluteString, "https://cdn.mxcontent.net/video.mp4")
                XCTAssertEqual(profile.name, "Seedbox")
                XCTAssertEqual(profile.remotePath, "/Videos/Lustre")
                XCTAssertEqual(password, "correct horse battery staple")
                await progress(DownloadProgress(bytesWritten: 1_024, totalBytes: 1_024))
                return URL(string: "https://seedbox.example.test/webdav/Videos/Lustre/remote-video.mp4")!
            }
        )

        let profile = try await service.saveWebDAVDestination(WebDAVDestinationRequest(
            name: "Seedbox",
            baseURL: URL(string: "https://seedbox.example.test/webdav")!,
            username: "lustre",
            password: "correct horse battery staple",
            remotePath: "/Videos/Lustre"
        ))
        let job = try await service.createJob(CreateJobRequest(sourcePageURL: sourceURL, destination: RemoteDestination.webDAV(profile.id)))
        await service.processQueuedJob(id: job.id)
        let allJobs = try await service.allJobs()
        let completed = try XCTUnwrap(allJobs.first)
        let destinations = await service.allRemoteDestinations()

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.destination, RemoteDestination.webDAV(profile.id))
        XCTAssertEqual(completed.message, "Completed: remote-video.mp4")
        XCTAssertEqual(destinations, [profile])
    }

    func testSeedboxJobsWaitInQueueWhileAnotherTransferIsRunning() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-remote-queue-\(UUID().uuidString).sqlite3")
        let profilesURL = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-remote-queue-profiles-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: profilesURL)
        }
        let profileStore = try RemoteDestinationProfileStore(fileURL: profilesURL)
        let secretStore = TestRemoteDestinationSecretStore()
        let gate = RemoteDownloadGate()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#, finalURL: url, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            destinationProfiles: profileStore,
            destinationSecrets: secretStore,
            remoteDownloader: { resolution, _, profile, _, _ in
                await gate.downloadStarted()
                return profile.baseURL.appending(path: "\(resolution.sourcePageURL.lastPathComponent).mp4")
            }
        )
        let profile = try await service.saveWebDAVDestination(WebDAVDestinationRequest(
            name: "Seedbox",
            baseURL: URL(string: "https://seedbox.example.test/webdav")!,
            username: "lustre",
            password: "test-password",
            remotePath: "/Lustre"
        ))
        let destination = RemoteDestination.webDAV(profile.id)

        let first = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/first")!, destination: destination))
        for _ in 0..<100 where await gate.invocationCount() == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let second = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/second")!, destination: destination))
        try? await Task.sleep(for: .milliseconds(100))

        let activeJobs = try await service.allJobs()
        XCTAssertEqual(activeJobs.first(where: { $0.id == first.id })?.status, .running)
        XCTAssertEqual(activeJobs.first(where: { $0.id == second.id })?.status, .queued)
        let activeInvocationCount = await gate.invocationCount()
        XCTAssertEqual(activeInvocationCount, 1)

        await gate.resumeFirstDownload()
        var completed = false
        for _ in 0..<200 {
            let jobs = try await service.allJobs()
            if jobs.filter({ $0.id == first.id || $0.id == second.id }).allSatisfy({ $0.status == .completed }) {
                completed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed)
        let completedInvocationCount = await gate.invocationCount()
        XCTAssertEqual(completedInvocationCount, 2)
    }

    func testForceStartBypassesConcurrencyForOnlyRequestedJobsWithoutDuplicateWorkers() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-force-start-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let gate = ConcurrentDownloadGate()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#, finalURL: url, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: FileManager.default.temporaryDirectory,
            progressDownloader: { resolution, _, directory, _ in
                await gate.wait(for: resolution.sourcePageURL)
                return directory.appending(path: "\(resolution.sourcePageURL.lastPathComponent).mp4")
            }
        )

        let first = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/first")!))
        await gate.waitForInvocationCount(1)
        let second = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/second")!))
        let third = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/third")!))

        let forceStartedSecond = try await service.apply(.forceStart, to: second.id)
        async let firstDuplicate = try? service.apply(.forceStart, to: third.id)
        async let secondDuplicate = try? service.apply(.forceStart, to: third.id)
        _ = await (firstDuplicate, secondDuplicate)
        await gate.waitForInvocationCount(3)

        XCTAssertEqual(forceStartedSecond.status, .queued)
        XCTAssertTrue(forceStartedSecond.logs?.contains(where: { $0.message == "Force start requested; bypassing normal concurrency limit." }) == true)
        let fourth = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/fourth")!))
        try await Task.sleep(for: .milliseconds(100))

        let running = try await service.allJobs()
        XCTAssertEqual(running.first(where: { $0.id == first.id })?.status, .running)
        XCTAssertEqual(running.first(where: { $0.id == second.id })?.status, .running)
        XCTAssertEqual(running.first(where: { $0.id == third.id })?.status, .running)
        XCTAssertEqual(running.first(where: { $0.id == fourth.id })?.status, .queued)
        let firstInvocationCount = await gate.invocationCount(for: first.sourcePageURL)
        let secondInvocationCount = await gate.invocationCount(for: second.sourcePageURL)
        let thirdInvocationCount = await gate.invocationCount(for: third.sourcePageURL)
        let fourthInvocationCount = await gate.invocationCount(for: fourth.sourcePageURL)
        XCTAssertEqual(firstInvocationCount, 1)
        XCTAssertEqual(secondInvocationCount, 1)
        XCTAssertEqual(thirdInvocationCount, 1)
        XCTAssertEqual(fourthInvocationCount, 0)

        await gate.resume(url: second.sourcePageURL)
        try await Task.sleep(for: .milliseconds(100))
        let jobsAfterSecond = try await service.allJobs()
        XCTAssertEqual(jobsAfterSecond.first(where: { $0.id == fourth.id })?.status, .queued)

        await gate.resume(url: first.sourcePageURL)
        try await Task.sleep(for: .milliseconds(100))
        let jobsAfterFirst = try await service.allJobs()
        XCTAssertEqual(jobsAfterFirst.first(where: { $0.id == fourth.id })?.status, .queued)

        await gate.resume(url: third.sourcePageURL)
        await gate.waitForInvocationCount(4)
        let scheduledFourthInvocationCount = await gate.invocationCount(for: fourth.sourcePageURL)
        XCTAssertEqual(scheduledFourthInvocationCount, 1)
        await gate.resume(url: fourth.sourcePageURL)
    }

    func testForcedJobCanBePausedWithoutStartingASecondDownloader() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-force-pause-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let gate = ConcurrentDownloadGate()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#, finalURL: url, statusCode: 200)
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: FileManager.default.temporaryDirectory,
            progressDownloader: { resolution, _, directory, _ in
                await gate.wait(for: resolution.sourcePageURL)
                try Task.checkCancellation()
                return directory.appending(path: "forced.mp4")
            }
        )

        let first = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/blocker")!))
        await gate.waitForInvocationCount(1)
        let forced = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/forced")!))
        _ = try await service.apply(.forceStart, to: forced.id)
        await gate.waitForInvocationCount(2)

        _ = try await service.apply(.pause, to: forced.id)
        await gate.resume(url: forced.sourcePageURL)
        try await Task.sleep(for: .milliseconds(100))

        let pausedJobs = try await service.allJobs()
        let forcedInvocationCount = await gate.invocationCount(for: forced.sourcePageURL)
        XCTAssertEqual(pausedJobs.first(where: { $0.id == forced.id })?.status, .paused)
        XCTAssertEqual(forcedInvocationCount, 1)
        await gate.resume(url: first.sourcePageURL)
    }

    func testTestsSavedWebDAVDestinationWithItsKeychainCredential() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-remote-test-\(UUID().uuidString).sqlite3")
        let profilesURL = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-remote-test-profiles-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: profilesURL)
        }
        let profileStore = try RemoteDestinationProfileStore(fileURL: profilesURL)
        let secretStore = TestRemoteDestinationSecretStore()
        let service = try AgentService(
            databaseURL: database,
            automaticallyStartsDownloads: false,
            destinationProfiles: profileStore,
            destinationSecrets: secretStore,
            remoteDestinationTester: { profile, password in
                XCTAssertEqual(profile.name, "Test server")
                XCTAssertEqual(profile.remotePath, "/Lustre/Test")
                XCTAssertTrue(profile.allowInvalidCertificate)
                XCTAssertEqual(password, "test-password")
                return RemoteDestinationTestResult(message: "WebDAV connection and write test succeeded.")
            }
        )
        let profile = try await service.saveWebDAVDestination(WebDAVDestinationRequest(
            name: "Test server",
            baseURL: URL(string: "https://seedbox.example.test/webdav")!,
            username: "lustre",
            password: "test-password",
            remotePath: "/Lustre/Test",
            allowInvalidCertificate: true
        ))

        let result = try await service.testRemoteDestination(id: profile.id)

        XCTAssertEqual(result.message, "WebDAV connection and write test succeeded.")
    }

    func testLegacyWebDAVProfileDefaultsToStrictCertificateValidation() throws {
        let data = Data("""
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Existing server","baseURL":"https://seedbox.example.test/webdav","username":"lustre","remotePath":"/Lustre"}]
        """.utf8)

        let profiles = try JSONDecoder().decode([WebDAVDestinationProfile].self, from: data)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertFalse(profiles[0].allowInvalidCertificate)
    }

    func testCreateJobQueuesWithoutResolvingTheSourcePage() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-queue-now-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let resolver = StaticProviderResolver(
            fetch: { _, _ in throw QueueCreationError.fetchWasCalled },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(databaseURL: database, resolver: resolver, automaticallyStartsDownloads: false)

        let job = try await service.createJob(CreateJobRequest(sourcePageURL: URL(string: "https://mixdrop.co/e/queue-now")!))

        XCTAssertEqual(job.status, .queued)
        XCTAssertNil(job.preferredQualityLabel)
        XCTAssertEqual(job.message, "Queued for local download.")
    }

    func testCancellingDuringReresolutionDoesNotStartDownloader() async throws {
        let sourceURL = URL(string: "https://mixdrop.co/e/cancelled")!
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-cancel-\(UUID().uuidString).sqlite3")
        let downloadsDirectory = FileManager.default.temporaryDirectory.appending(path: "lustre-cancel-downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: downloadsDirectory)
        }
        let gate = ResolutionGate()
        let downloader = DownloadInvocationTracker()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in await gate.page(for: url) },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: downloadsDirectory,
            automaticallyStartsDownloads: false,
            downloader: { _, _, _ in
                await downloader.recordInvocation()
                return downloadsDirectory.appending(path: "should-not-exist.mp4")
            }
        )

        let job = try await service.createJob(CreateJobRequest(sourcePageURL: sourceURL))
        await gate.holdNextFetch()
        let worker = Task { await service.processQueuedJob(id: job.id) }
        for _ in 0..<100 where !(await gate.isFetchWaiting()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let fetchIsWaiting = await gate.isFetchWaiting()
        guard fetchIsWaiting else {
            XCTFail("The re-resolution fetch did not begin.")
            return
        }

        _ = try await service.apply(.cancel, to: job.id)
        await gate.resumeFetch()
        await worker.value

        let jobs = try await service.allJobs()
        let cancelled = try XCTUnwrap(jobs.first)
        XCTAssertEqual(cancelled.status, .cancelled)
        let invocationCount = await downloader.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testRetryStartsANewWorkerWhenCancelledWorkerStillOwnsItsOldTask() async throws {
        let sourceURL = URL(string: "https://mixdrop.co/e/retry-race")!
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-retry-race-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let gate = ResolutionGate()
        let downloads = FileManager.default.temporaryDirectory
        let downloader = DownloadInvocationTracker()
        let resolver = StaticProviderResolver(
            fetch: { url, _ in await gate.page(for: url) },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: downloads,
            downloader: { _, _, _ in
                await downloader.recordInvocation()
                return downloads.appending(path: "retry-race.mp4")
            }
        )

        await gate.holdNextFetch()
        let job = try await service.createJob(CreateJobRequest(sourcePageURL: sourceURL))
        for _ in 0..<100 where !(await gate.isFetchWaiting()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let fetchIsWaiting = await gate.isFetchWaiting()
        XCTAssertTrue(fetchIsWaiting)

        _ = try await service.apply(.cancel, to: job.id)
        _ = try await service.apply(.retry, to: job.id)
        await gate.resumeFetch()

        var completed = false
        for _ in 0..<100 {
            if try await service.allJobs().first?.status == .completed {
                completed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed, "Retry must not remain queued behind a cancelled worker.")
        let invocationCount = await downloader.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testStartupRequeuesInterruptedRunningJob() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-recovery-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let store = try JobStore(databaseURL: database)
        var interrupted = DownloadJob(sourcePageURL: URL(string: "https://mixdrop.co/e/interrupted")!, status: .running, message: "Downloading Video.")
        interrupted.updatedAt = .now
        try await store.create(interrupted)

        let service = try AgentService(databaseURL: database, automaticallyStartsDownloads: false)
        var recovered: DownloadJob?
        for _ in 0..<100 {
            if let job = try await service.allJobs().first, job.status == .queued {
                recovered = job
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(recovered?.id, interrupted.id)
        XCTAssertEqual(recovered?.status, .queued)
        XCTAssertTrue(recovered?.message.contains("restart") == true)
    }

    func testStartupBeginsDurablyQueuedJob() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-startup-queue-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let store = try JobStore(databaseURL: database)
        let queued = DownloadJob(sourcePageURL: URL(string: "https://mixdrop.co/e/startup")!)
        try await store.create(queued)
        let resolver = StaticProviderResolver(
            fetch: { url, _ in HTTPPage(body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#, finalURL: url, statusCode: 200) },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: FileManager.default.temporaryDirectory,
            downloader: { _, _, directory in directory.appending(path: "startup.mp4") }
        )

        var completed = false
        for _ in 0..<100 {
            if try await service.allJobs().first?.status == .completed {
                completed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed, "A queued durable job must start after agent initialization.")
    }

    func testPublishesLiveDownloadProgressWhileTransferIsRunning() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-progress-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let gate = ProgressGate()
        let sourceURL = URL(string: "https://mixdrop.co/e/progress")!
        let resolver = StaticProviderResolver(
            fetch: { url, _ in
                HTTPPage(
                    body: #"<script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
                    finalURL: url,
                    statusCode: 200
                )
            },
            randomSuffix: { "unused" },
            nowMilliseconds: { "0" }
        )
        let service = try AgentService(
            databaseURL: database,
            resolver: resolver,
            downloadsDirectory: FileManager.default.temporaryDirectory,
            progressDownloader: { _, _, directory, reportProgress in
                await reportProgress(DownloadProgress(bytesWritten: 42, totalBytes: 100))
                await gate.wait()
                return directory.appending(path: "progress.mp4")
            }
        )

        _ = try await service.createJob(CreateJobRequest(sourcePageURL: sourceURL))
        var runningJob: DownloadJob?
        for _ in 0..<100 {
            if let job = try await service.allJobs().first,
               job.status == .running,
               job.progress == 0.42,
               job.downloadedBytes == 42,
               job.totalBytes == 100 {
                runningJob = job
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runningJob?.progress, 0.42)
        XCTAssertEqual(runningJob?.downloadedBytes, 42)
        XCTAssertEqual(runningJob?.totalBytes, 100)

        await gate.resume()
        var completedJob: DownloadJob?
        for _ in 0..<100 {
            if let job = try await service.allJobs().first, job.status == .completed {
                completedJob = job
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(completedJob?.progress, 1)
    }

    func testFolderSelectionDoesNotBlockTheAgentActor() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-folder-picker-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let defaultDirectory = FileManager.default.temporaryDirectory.appending(path: "LustreDefault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: defaultDirectory) }
        let picker = BlockingFolderPicker(path: FileManager.default.temporaryDirectory.path)
        let service = try AgentService(databaseURL: database, downloadsDirectory: defaultDirectory, automaticallyStartsDownloads: false, folderPicker: picker.pick)
        let selection = Task { try await service.selectDownloadFolder() }
        XCTAssertEqual(picker.started.wait(timeout: .now() + 1), .success)

        let healthCompleted = CompletionTracker()
        let health = Task {
            _ = await service.health()
            await healthCompleted.markCompleted()
        }
        try await Task.sleep(for: .milliseconds(100))
        let didCompleteHealth = await healthCompleted.isCompleted()
        XCTAssertTrue(didCompleteHealth, "Folder selection must not occupy the agent actor.")

        picker.releaseSelection()
        let selectedPath = try await selection.value
        XCTAssertEqual(selectedPath, FileManager.default.temporaryDirectory.path)
        let customStatus = await service.localDownloadFolderStatus()
        XCTAssertEqual(customStatus, LocalDownloadFolderStatus(mode: "custom", folderName: FileManager.default.temporaryDirectory.lastPathComponent))
        try await service.resetDownloadFolder()
        let defaultStatus = await service.localDownloadFolderStatus()
        XCTAssertEqual(defaultStatus.mode, "default")
        _ = await health.value
    }

    func testFeedEndpointsExposeSitesAndRequestedPage() async throws {
        let database = FileManager.default.temporaryDirectory.appending(path: "lustre-agent-feed-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let feed = FeedService(fetch: { url, _ in
            HTTPPage(
                body: #"<script type="application/ld+json">{"@type":"ItemList","itemType":"VideoObject","itemListElement":[]}</script>"#,
                finalURL: url,
                statusCode: 200
            )
        })
        let service = try AgentService(
            databaseURL: database,
            automaticallyStartsDownloads: false,
            feed: feed
        )

        let sites = await service.feedSites()
        let page = try await service.feedPage(site: .allPornStream, page: 2)

        XCTAssertEqual(Array(sites.prefix(4)), [.allPornStream, .hqPorner, .onlyFan420, .pornHub])
        XCTAssertEqual(sites.filter { $0.id == .pornHub }.count, 1)
        XCTAssertTrue(sites.count == FeedSite.all.count || sites == FeedSite.all + FeedSite.authenticatedPornHub)
        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.items, [])
        XCTAssertFalse(page.hasMore)
    }
}

private enum QueueCreationError: Error {
    case fetchWasCalled
}

private final class TestRemoteDestinationSecretStore: RemoteDestinationSecretStore, @unchecked Sendable {
    private var passwords: [UUID: String] = [:]

    func password(for profileID: UUID) throws -> String? {
        passwords[profileID]
    }

    func save(password: String, for profileID: UUID) throws {
        passwords[profileID] = password
    }

    func remove(profileID: UUID) throws {
        passwords[profileID] = nil
    }
}

private actor ResolutionGate {
    private var shouldWaitForNextFetch = false
    private var continuation: CheckedContinuation<Void, Never>?

    func page(for url: URL) async -> HTTPPage {
        if shouldWaitForNextFetch {
            shouldWaitForNextFetch = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return HTTPPage(
            body: #"<title>Test</title><script>MDCore.wurl = "https://cdn.mxcontent.net/video.mp4"</script>"#,
            finalURL: url,
            statusCode: 200
        )
    }

    func holdNextFetch() {
        shouldWaitForNextFetch = true
    }

    func isFetchWaiting() -> Bool {
        continuation != nil
    }

    func resumeFetch() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DownloadInvocationTracker {
    private var count = 0

    func recordInvocation() {
        count += 1
    }

    func invocationCount() -> Int {
        count
    }
}

private actor AllPornStreamRenderTracker {
    private let html: String
    private var urls: [URL] = []

    init(html: String) {
        self.html = html
    }

    func render(url: URL) -> String {
        urls.append(url)
        return html
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor ProgressGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RemoteDownloadGate {
    private var invocations = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func downloadStarted() async {
        invocations += 1
        if invocations == 1 {
            await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
    }

    func invocationCount() -> Int { invocations }

    func resumeFirstDownload() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

private actor ConcurrentDownloadGate {
    private var invocations: [URL: Int] = [:]
    private var continuations: [URL: CheckedContinuation<Void, Never>] = [:]

    func wait(for url: URL) async {
        invocations[url, default: 0] += 1
        await withCheckedContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func invocationCount(for url: URL) -> Int {
        invocations[url, default: 0]
    }

    func waitForInvocationCount(_ count: Int) async {
        while invocations.values.reduce(0, +) < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func resume(url: URL) {
        continuations.removeValue(forKey: url)?.resume()
    }
}

private final class BlockingFolderPicker: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let path: String

    init(path: String) {
        self.path = path
    }

    func pick() throws -> String {
        started.signal()
        release.wait()
        return path
    }

    func releaseSelection() {
        release.signal()
    }
}

private actor CompletionTracker {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}
