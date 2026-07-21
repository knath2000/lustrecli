import CSQLite
import Foundation

public enum JobStoreError: Error, LocalizedError {
    case sqlite(String)
    case jobNotFound(UUID)
    case invalidAction(JobAction, JobStatus)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): message
        case .jobNotFound(let id): "No job exists with id \(id.uuidString)."
        case .invalidAction(let action, let status): "Cannot \(action.rawValue) a job while it is \(status.rawValue)."
        }
    }
}

public actor JobStore {
    private let handle: SQLiteHandle
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw JobStoreError.sqlite("Unable to open the jobs database.")
        }
        self.handle = SQLiteHandle(database)
        var error: UnsafeMutablePointer<CChar>?
        let schema = "CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, updated_at REAL NOT NULL);"
        guard sqlite3_exec(database, schema, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw JobStoreError.sqlite(error.map { String(cString: $0) } ?? "Unable to create the jobs table.")
        }
    }

    public func create(_ job: DownloadJob) throws {
        let payload = try encoder.encode(job)
        let statement = try prepare("INSERT INTO jobs (id, payload, updated_at) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(job.id.uuidString, to: statement, index: 1)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(payload.count), sqliteTransient)
        }
        sqlite3_bind_double(statement, 3, job.updatedAt.timeIntervalSince1970)
        try step(statement)
    }

    public func allJobs() throws -> [DownloadJob] {
        let statement = try prepare("SELECT payload FROM jobs ORDER BY updated_at DESC")
        defer { sqlite3_finalize(statement) }
        var jobs: [DownloadJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            jobs.append(try decoder.decode(DownloadJob.self, from: Data(bytes: bytes, count: count)))
        }
        return jobs
    }

    public func job(id: UUID) throws -> DownloadJob? {
        let statement = try prepare("SELECT payload FROM jobs WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try decoder.decode(DownloadJob.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    public func apply(_ action: JobAction, to id: UUID) throws -> DownloadJob {
        guard var job = try job(id: id) else { throw JobStoreError.jobNotFound(id) }
        guard job.status.allows(action) else { throw JobStoreError.invalidAction(action, job.status) }
        switch action {
        case .pause:
            job.status = .paused
            job.message = "Paused."
        case .resume:
            job.status = .queued
            job.message = "Waiting for the resolver worker."
        case .cancel:
            job.status = .cancelled
            job.message = "Cancelled."
        case .retry:
            job.status = .queued
            job.attempts += 1
            job.message = "Queued for retry."
        }
        job.updatedAt = .now
        try replace(job)
        return job
    }

    public func update(_ job: DownloadJob) throws {
        try replace(job)
    }

    private func replace(_ job: DownloadJob) throws {
        let payload = try encoder.encode(job)
        let statement = try prepare("UPDATE jobs SET payload = ?, updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(payload.count), sqliteTransient)
        }
        sqlite3_bind_double(statement, 2, job.updatedAt.timeIntervalSince1970)
        bind(job.id.uuidString, to: statement, index: 3)
        try step(statement)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle.database, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw JobStoreError.sqlite(error.map { String(cString: $0) } ?? "SQLite operation failed.")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle.database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw JobStoreError.sqlite(handle.database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite prepare failed.")
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw JobStoreError.sqlite(handle.database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite write failed.")
        }
    }
}

private extension JobStatus {
    func allows(_ action: JobAction) -> Bool {
        switch (self, action) {
        case (.queued, .pause), (.queued, .cancel),
             (.running, .pause), (.running, .cancel),
             (.paused, .resume), (.paused, .cancel),
             (.failed, .retry),
             (.cancelled, .retry),
             (.verificationRequired, .retry), (.verificationRequired, .cancel):
            true
        default:
            false
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteHandle: @unchecked Sendable {
    let database: OpaquePointer?

    init(_ database: OpaquePointer?) {
        self.database = database
    }

    deinit {
        sqlite3_close(database)
    }
}
