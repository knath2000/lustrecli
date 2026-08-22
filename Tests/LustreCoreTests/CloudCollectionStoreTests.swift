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
