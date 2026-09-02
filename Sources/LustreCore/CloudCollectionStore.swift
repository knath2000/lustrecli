import CSQLite
import Foundation

public struct CloudWatchlistItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePageURL: URL
    public var title: String
    public var provider: String
    public var thumbnailURL: URL?
    public var watched: Bool
    public var watchedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct CloudLibraryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourcePageURL: URL
    public var title: String
    public var provider: String
    public var thumbnailURL: URL?
    public var mediaKind: String
    public var completedAt: Date
    public var tags: [String]
    public var collection: String?
    public var favorite: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, sourcePageURL: URL, title: String, provider: String, thumbnailURL: URL?, mediaKind: String, completedAt: Date, tags: [String], collection: String?, favorite: Bool, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.sourcePageURL = sourcePageURL
        self.title = title
        self.provider = provider
        self.thumbnailURL = thumbnailURL
        self.mediaKind = mediaKind
        self.completedAt = completedAt
        self.tags = tags
        self.collection = collection
        self.favorite = favorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CloudCollectionMutation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: String
    public let sourcePageURL: URL
    public let payload: [String: JSONValue]
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Int64), boolean(Bool), array([String]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int64.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .array(try container.decode([String].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct CloudCollectionSnapshot: Codable, Equatable, Sendable {
    public let watchlist: [CloudWatchlistItem]
    public let library: [CloudLibraryItem]
    public let cursor: Int64
    public let pendingChanges: Int
}

public struct CloudCollectionChange: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let entityType: String
    public let entityID: UUID
    public let operation: String
    public let payload: Data

    public init(sequence: Int64, entityType: String, entityID: UUID, operation: String, payload: Data) {
        self.sequence = sequence
        self.entityType = entityType
        self.entityID = entityID
        self.operation = operation
        self.payload = payload
    }
}

public actor CloudCollectionStore {
    private let handle: CloudCollectionSQLiteHandle
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO-8601 timestamp.") }
            return date
        }
        return decoder
    }()

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw JobStoreError.sqlite("Unable to open the collections database.")
        }
        self.handle = CloudCollectionSQLiteHandle(database)
        var schemaError: UnsafeMutablePointer<CChar>?
        let schema = """
        CREATE TABLE IF NOT EXISTS cloud_collection_state (id INTEGER PRIMARY KEY CHECK (id = 1), cursor INTEGER NOT NULL DEFAULT 0);
        INSERT OR IGNORE INTO cloud_collection_state (id, cursor) VALUES (1, 0);
        CREATE TABLE IF NOT EXISTS cloud_watchlist_items (source_url TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_library_items (source_url TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS cloud_collection_outbox (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, source_url TEXT NOT NULL, payload BLOB NOT NULL, created_at REAL NOT NULL);
        """
        guard sqlite3_exec(database, schema, nil, nil, &schemaError) == SQLITE_OK else {
            defer { sqlite3_free(schemaError) }
            throw JobStoreError.sqlite(schemaError.map { String(cString: $0) } ?? "Unable to create the collections tables.")
        }
    }

    public func snapshot() throws -> CloudCollectionSnapshot {
        CloudCollectionSnapshot(
            watchlist: try rows(table: "cloud_watchlist_items", as: CloudWatchlistItem.self).sorted { $0.updatedAt > $1.updatedAt },
            library: try rows(table: "cloud_library_items", as: CloudLibraryItem.self).sorted { $0.completedAt > $1.completedAt },
            cursor: try cursor(),
            pendingChanges: try pendingCount()
        )
    }

    public func pendingMutations(limit: Int = 100) throws -> [CloudCollectionMutation] {
        let statement = try prepare("SELECT payload FROM cloud_collection_outbox ORDER BY created_at ASC LIMIT ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(min(max(limit, 1), 100)))
        var values: [CloudCollectionMutation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            values.append(try decoder.decode(CloudCollectionMutation.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return values
    }

    public func saveWatchlist(_ item: CloudWatchlistItem, queue: Bool = true) throws {
        try upsert(item, sourceURL: item.sourcePageURL, table: "cloud_watchlist_items", updatedAt: item.updatedAt)
        if queue {
            try enqueue(kind: "watchlist_upsert", sourceURL: item.sourcePageURL, payload: [
                "title": .string(item.title), "provider": .string(item.provider),
                "thumbnailURL": item.thumbnailURL.map { .string($0.absoluteString) } ?? .null,
                "watched": .boolean(item.watched),
            ])
        }
    }

    public func removeWatchlist(sourceURL: URL, queue: Bool = true) throws {
        try remove(sourceURL: sourceURL, table: "cloud_watchlist_items")
        if queue { try enqueue(kind: "watchlist_delete", sourceURL: sourceURL, payload: [:]) }
    }

    public func saveLibrary(_ item: CloudLibraryItem, jobID: UUID, displayFilename: String?, byteCount: Int64?, queue: Bool = true) throws {
        try upsert(item, sourceURL: item.sourcePageURL, table: "cloud_library_items", updatedAt: item.updatedAt)
        if queue {
            try enqueue(kind: "library_upsert", sourceURL: item.sourcePageURL, payload: [
                "jobID": .string(jobID.uuidString.lowercased()), "title": .string(item.title),
                "provider": .string(item.provider), "thumbnailURL": item.thumbnailURL.map { .string($0.absoluteString) } ?? .null,
                "mediaKind": .string(item.mediaKind), "completedAt": .string(ISO8601DateFormatter().string(from: item.completedAt)),
                "displayFilename": displayFilename.map(JSONValue.string) ?? .null,
                "byteCount": byteCount.map(JSONValue.number) ?? .null,
            ])
        }
    }

    public func organizeLibrary(sourceURL: URL, tags: [String], collection: String?, favorite: Bool) throws {
        guard var item: CloudLibraryItem = try row(sourceURL: sourceURL, table: "cloud_library_items") else { return }
        item.tags = tags
        item.collection = collection
        item.favorite = favorite
        item.updatedAt = .now
        try upsert(item, sourceURL: sourceURL, table: "cloud_library_items", updatedAt: item.updatedAt)
        try enqueue(kind: "library_organize", sourceURL: sourceURL, payload: [
            "tags": .array(tags), "collection": collection.map(JSONValue.string) ?? .null, "favorite": .boolean(favorite),
        ])
    }

    public func removeLibrary(sourceURL: URL, queue: Bool = true) throws {
        try remove(sourceURL: sourceURL, table: "cloud_library_items")
        if queue { try enqueue(kind: "library_delete", sourceURL: sourceURL, payload: [:]) }
    }

    public func apply(changes: [CloudCollectionChange], acknowledgedMutationIDs: [UUID], cursor: Int64) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for change in changes {
                let sourceURL = try decoder.decode(ChangeSource.self, from: change.payload).sourcePageURL
                if change.entityType == "watchlist" {
                    if change.operation == "delete" { try remove(sourceURL: sourceURL, table: "cloud_watchlist_items") }
                    else { try upsert(try decoder.decode(CloudWatchlistItem.self, from: change.payload), sourceURL: sourceURL, table: "cloud_watchlist_items", updatedAt: .now) }
                } else if change.operation == "delete" {
                    try remove(sourceURL: sourceURL, table: "cloud_library_items")
                } else {
                    try upsert(try decoder.decode(CloudLibraryItem.self, from: change.payload), sourceURL: sourceURL, table: "cloud_library_items", updatedAt: .now)
                }
            }
            for id in acknowledgedMutationIDs { try deleteMutation(id) }
            let statement = try prepare("UPDATE cloud_collection_state SET cursor = ? WHERE id = 1")
            sqlite3_bind_int64(statement, 1, cursor)
            do {
                try step(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
            sqlite3_finalize(statement)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private struct ChangeSource: Decodable { let sourcePageURL: URL }

    private func enqueue(kind: String, sourceURL: URL, payload: [String: JSONValue]) throws {
        let mutation = CloudCollectionMutation(id: UUID(), kind: kind, sourcePageURL: sourceURL, payload: payload)
        let data = try encoder.encode(mutation)
        let statement = try prepare("INSERT INTO cloud_collection_outbox (id, kind, source_url, payload, created_at) VALUES (?, ?, ?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(mutation.id.uuidString.lowercased(), statement, 1)
        bind(kind, statement, 2)
        bind(sourceURL.absoluteString, statement, 3)
        bind(data, statement, 4)
        sqlite3_bind_double(statement, 5, Date.now.timeIntervalSince1970)
        try step(statement)
    }

    private func upsert<T: Encodable>(_ value: T, sourceURL: URL, table: String, updatedAt: Date) throws {
        let statement = try prepare("INSERT INTO \(table) (source_url, payload, updated_at) VALUES (?, ?, ?) ON CONFLICT(source_url) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at")
        defer { sqlite3_finalize(statement) }
        bind(sourceURL.absoluteString, statement, 1)
        bind(try encoder.encode(value), statement, 2)
        sqlite3_bind_double(statement, 3, updatedAt.timeIntervalSince1970)
        try step(statement)
    }

    private func row<T: Decodable>(sourceURL: URL, table: String) throws -> T? {
        let statement = try prepare("SELECT payload FROM \(table) WHERE source_url = ?")
        defer { sqlite3_finalize(statement) }
        bind(sourceURL.absoluteString, statement, 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try decoder.decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    private func rows<T: Decodable>(table: String, as: T.Type) throws -> [T] {
        let statement = try prepare("SELECT payload FROM \(table)")
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            values.append(try decoder.decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
        return values
    }

    private func remove(sourceURL: URL, table: String) throws {
        let statement = try prepare("DELETE FROM \(table) WHERE source_url = ?")
        defer { sqlite3_finalize(statement) }
        bind(sourceURL.absoluteString, statement, 1)
        try step(statement)
    }

    private func deleteMutation(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM cloud_collection_outbox WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString.lowercased(), statement, 1)
        try step(statement)
    }

    private func cursor() throws -> Int64 {
        let statement = try prepare("SELECT cursor FROM cloud_collection_state WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }

    private func pendingCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM cloud_collection_outbox")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle.database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw JobStoreError.sqlite(error.map { String(cString: $0) } ?? "SQLite collection operation failed.")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw JobStoreError.sqlite(handle.database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite collection prepare failed.")
        }
        return statement
    }

    private func bind(_ value: String, _ statement: OpaquePointer?, _ index: Int32) { sqlite3_bind_text(statement, index, value, -1, sqliteCollectionTransient) }
    private func bind(_ value: Data, _ statement: OpaquePointer?, _ index: Int32) { _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), sqliteCollectionTransient) } }
    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw JobStoreError.sqlite(handle.database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite collection write failed.") }
    }
}

private let sqliteCollectionTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class CloudCollectionSQLiteHandle: @unchecked Sendable {
    let database: OpaquePointer?
    init(_ database: OpaquePointer?) { self.database = database }
    deinit { sqlite3_close(database) }
}
