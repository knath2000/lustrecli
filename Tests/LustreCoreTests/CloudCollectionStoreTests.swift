import Foundation
import Testing
@testable import LustreCore

@Test func cloudCollectionStorePersistsOptimisticWatchlistAndOutbox() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CloudCollectionStore(databaseURL: directory.appending(path: "collections.sqlite3"))
    let item = CloudWatchlistItem(
        id: UUID(), sourcePageURL: URL(string: "https://example.com/video/1")!,
        title: "Example", provider: "example", thumbnailURL: nil,
        watched: false, watchedAt: nil, createdAt: .now, updatedAt: .now
    )

    try await store.saveWatchlist(item)

    let snapshot = try await store.snapshot()
    #expect(snapshot.watchlist == [item])
    #expect(snapshot.pendingChanges == 1)
    #expect(try await store.pendingMutations().first?.kind == "watchlist_upsert")
}

@Test func cloudCollectionAcknowledgementClearsOutboxAndAdvancesCursor() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CloudCollectionStore(databaseURL: directory.appending(path: "collections.sqlite3"))
    let item = CloudWatchlistItem(
        id: UUID(), sourcePageURL: URL(string: "https://example.com/video/2")!,
        title: "Example", provider: "example", thumbnailURL: nil,
        watched: false, watchedAt: nil, createdAt: .now, updatedAt: .now
    )
    try await store.saveWatchlist(item)
    let mutation = try #require(try await store.pendingMutations().first)

    try await store.apply(changes: [], acknowledgedMutationIDs: [mutation.id], cursor: 42)

    let snapshot = try await store.snapshot()
    #expect(snapshot.cursor == 42)
    #expect(snapshot.pendingChanges == 0)
}

@Test func cloudCollectionStoreAcceptsFractionalSecondISOTimestamps() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try CloudCollectionStore(databaseURL: directory.appending(path: "collections.sqlite3"))

    // Server emits fractional-second ISO-8601 timestamps (Vercel Date.toISOString()).
    let watchlistPayload = """
    {
      "id": "\(UUID().uuidString)",
      "sourcePageURL": "https://example.com/video/3",
      "title": "Fractional",
      "provider": "example",
      "thumbnailURL": null,
      "watched": false,
      "watchedAt": null,
      "createdAt": "2026-08-22T05:00:00.000Z",
      "updatedAt": "2026-08-22T05:00:00.000Z"
    }
    """.data(using: .utf8)!

    let libraryPayload = """
    {
      "id": "\(UUID().uuidString)",
      "sourcePageURL": "https://example.com/video/4",
      "title": "Fractional Library",
      "provider": "example",
      "thumbnailURL": null,
      "mediaKind": "video",
      "completedAt": "2026-08-22T05:00:00.000Z",
      "tags": [],
      "collection": null,
      "favorite": false,
      "createdAt": "2026-08-22T05:00:00.000Z",
      "updatedAt": "2026-08-22T05:00:00.000Z"
    }
    """.data(using: .utf8)!

    let watchlistID = UUID()
    let libraryID = UUID()
    let changes = [
        CloudCollectionChange(
            sequence: 1,
            entityType: "watchlist",
            entityID: watchlistID,
            operation: "upsert",
            payload: watchlistPayload
        ),
        CloudCollectionChange(
            sequence: 2,
            entityType: "library",
            entityID: libraryID,
            operation: "upsert",
            payload: libraryPayload
        ),
    ]

    try await store.apply(changes: changes, acknowledgedMutationIDs: [], cursor: 99)

    let snapshot = try await store.snapshot()
    #expect(snapshot.cursor == 99)
    #expect(snapshot.watchlist.contains(where: { $0.id == watchlistID }))
    #expect(snapshot.library.contains(where: { $0.id == libraryID }))
}
