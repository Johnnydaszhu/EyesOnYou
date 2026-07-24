import Foundation
import SQLite3
import FlowLensCore

public enum TelemetryStoreError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    public var description: String {
        switch self {
        case .openFailed(let m): return "open failed: \(m)"
        case .prepareFailed(let m): return "prepare failed: \(m)"
        case .stepFailed(let m): return "step failed: \(m)"
        case .bindFailed(let m): return "bind failed: \(m)"
        }
    }
}

/// Single-writer SQLite telemetry store (WAL). Foundation + SQLite3 only.
public final class TelemetryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private var appIDCache: [AppIdentityKey: Int64] = [:]

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw TelemetryStoreError.openFailed(message)
        }
        db = handle
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA busy_timeout = 2500;")
        try createSchema()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_meta (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        """)
        try exec("INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', '1');")

        try exec("""
        CREATE TABLE IF NOT EXISTS apps (
            app_id INTEGER PRIMARY KEY,
            team_id TEXT NOT NULL DEFAULT '',
            signing_id TEXT NOT NULL,
            display_name TEXT,
            first_seen_ms INTEGER NOT NULL,
            last_seen_ms INTEGER NOT NULL,
            UNIQUE(team_id, signing_id)
        );
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS traffic_buckets (
            granularity_sec INTEGER NOT NULL,
            bucket_start_ms INTEGER NOT NULL,
            app_id INTEGER NOT NULL,
            destination_key TEXT NOT NULL DEFAULT 'unknown',
            transport INTEGER NOT NULL,
            route_kind INTEGER NOT NULL,
            bytes_up INTEGER NOT NULL DEFAULT 0,
            bytes_down INTEGER NOT NULL DEFAULT 0,
            flows_opened INTEGER NOT NULL DEFAULT 0,
            flows_closed INTEGER NOT NULL DEFAULT 0,
            flows_blocked INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(
                granularity_sec, bucket_start_ms, app_id, destination_key, transport, route_kind
            )
        ) WITHOUT ROWID;
        """)

        try exec("""
        CREATE INDEX IF NOT EXISTS idx_buckets_app_time
        ON traffic_buckets(app_id, granularity_sec, bucket_start_ms DESC);
        """)
    }

    // MARK: - Writes

    public func upsertApp(_ app: AppIdentityKey, displayName: String?, at: Date = Date()) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let cached = appIDCache[app] { return cached }

        let ms = Int64(at.timeIntervalSince1970 * 1000)
        let team = app.teamIdentifier ?? ""
        try exec("""
        INSERT INTO apps(team_id, signing_id, display_name, first_seen_ms, last_seen_ms)
        VALUES (\(sqlString(team)), \(sqlString(app.signingIdentifier)), \(sqlOptionalString(displayName)), \(ms), \(ms))
        ON CONFLICT(team_id, signing_id) DO UPDATE SET
            last_seen_ms = excluded.last_seen_ms,
            display_name = COALESCE(excluded.display_name, apps.display_name);
        """)

        let id = try queryInt64(
            "SELECT app_id FROM apps WHERE team_id = \(sqlString(team)) AND signing_id = \(sqlString(app.signingIdentifier));"
        )
        appIDCache[app] = id
        return id
    }

    public func mergeBucket(_ bucket: TrafficBucket) throws {
        let appID = try upsertApp(bucket.key.app, displayName: nil)
        lock.lock(); defer { lock.unlock() }

        let g = bucket.key.granularity.seconds
        let start = bucket.key.bucketStartMs
        let dest = bucket.key.destinationKey
        let transport = Int(bucket.key.transport.rawValue)
        let route = Int(bucket.key.routeKind.rawValue)
        let t = bucket.totals

        try exec("""
        INSERT INTO traffic_buckets(
            granularity_sec, bucket_start_ms, app_id, destination_key, transport, route_kind,
            bytes_up, bytes_down, flows_opened, flows_closed, flows_blocked
        ) VALUES (
            \(g), \(start), \(appID), \(sqlString(dest)), \(transport), \(route),
            \(t.bytesUp), \(t.bytesDown), \(t.flowsOpened), \(t.flowsClosed), \(t.flowsBlocked)
        )
        ON CONFLICT(granularity_sec, bucket_start_ms, app_id, destination_key, transport, route_kind) DO UPDATE SET
            bytes_up = bytes_up + excluded.bytes_up,
            bytes_down = bytes_down + excluded.bytes_down,
            flows_opened = flows_opened + excluded.flows_opened,
            flows_closed = flows_closed + excluded.flows_closed,
            flows_blocked = flows_blocked + excluded.flows_blocked;
        """)
    }

    public func flushAggregator(_ aggregator: TelemetryAggregator, granularity: BucketGranularity) throws {
        let buckets = aggregator.exportBuckets(granularity: granularity)
        for bucket in buckets {
            try mergeBucket(bucket)
        }
    }

    // MARK: - Reads

    public func queryTotals(
        app: AppIdentityKey?,
        granularity: BucketGranularity,
        from: Date,
        to: Date
    ) throws -> TrafficTotals {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)

        var sql = """
        SELECT COALESCE(SUM(bytes_up),0), COALESCE(SUM(bytes_down),0),
               COALESCE(SUM(flows_opened),0), COALESCE(SUM(flows_closed),0),
               COALESCE(SUM(flows_blocked),0)
        FROM traffic_buckets
        WHERE granularity_sec = \(granularity.seconds)
          AND bucket_start_ms >= \(fromMs)
          AND bucket_start_ms < \(toMs)
        """

        if let app {
            let appID = try upsertApp(app, displayName: nil)
            sql += " AND app_id = \(appID)"
        }

        lock.lock(); defer { lock.unlock() }
        return try queryTotalsSQL(sql)
    }

    public func queryTopApps(
        granularity: BucketGranularity,
        from: Date,
        to: Date,
        limit: Int = 10
    ) throws -> [(AppIdentityKey, String, TrafficTotals)] {
        let fromMs = Int64(from.timeIntervalSince1970 * 1000)
        let toMs = Int64(to.timeIntervalSince1970 * 1000)

        let sql = """
        SELECT a.team_id, a.signing_id, COALESCE(a.display_name, a.signing_id),
               COALESCE(SUM(b.bytes_up),0), COALESCE(SUM(b.bytes_down),0),
               COALESCE(SUM(b.flows_opened),0), COALESCE(SUM(b.flows_closed),0),
               COALESCE(SUM(b.flows_blocked),0)
        FROM traffic_buckets b
        JOIN apps a ON a.app_id = b.app_id
        WHERE b.granularity_sec = \(granularity.seconds)
          AND b.bucket_start_ms >= \(fromMs)
          AND b.bucket_start_ms < \(toMs)
        GROUP BY a.app_id
        ORDER BY (COALESCE(SUM(b.bytes_up),0) + COALESCE(SUM(b.bytes_down),0)) DESC
        LIMIT \(limit);
        """

        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TelemetryStoreError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }

        var results: [(AppIdentityKey, String, TrafficTotals)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let team = String(cString: sqlite3_column_text(stmt, 0))
            let signing = String(cString: sqlite3_column_text(stmt, 1))
            let name = String(cString: sqlite3_column_text(stmt, 2))
            let totals = TrafficTotals(
                bytesUp: UInt64(sqlite3_column_int64(stmt, 3)),
                bytesDown: UInt64(sqlite3_column_int64(stmt, 4)),
                flowsOpened: UInt64(sqlite3_column_int64(stmt, 5)),
                flowsClosed: UInt64(sqlite3_column_int64(stmt, 6)),
                flowsBlocked: UInt64(sqlite3_column_int64(stmt, 7))
            )
            let key = AppIdentityKey(
                teamIdentifier: team.isEmpty ? nil : team,
                signingIdentifier: signing
            )
            results.append((key, name, totals))
        }
        return results
    }

    // MARK: - SQL helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? lastError()
            sqlite3_free(err)
            throw TelemetryStoreError.stepFailed(message)
        }
    }

    private func queryInt64(_ sql: String) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TelemetryStoreError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw TelemetryStoreError.stepFailed(lastError())
        }
        return sqlite3_column_int64(stmt, 0)
    }

    private func queryTotalsSQL(_ sql: String) throws -> TrafficTotals {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TelemetryStoreError.prepareFailed(lastError())
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return TrafficTotals()
        }
        return TrafficTotals(
            bytesUp: UInt64(sqlite3_column_int64(stmt, 0)),
            bytesDown: UInt64(sqlite3_column_int64(stmt, 1)),
            flowsOpened: UInt64(sqlite3_column_int64(stmt, 2)),
            flowsClosed: UInt64(sqlite3_column_int64(stmt, 3)),
            flowsBlocked: UInt64(sqlite3_column_int64(stmt, 4))
        )
    }

    private func lastError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func sqlString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func sqlOptionalString(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return sqlString(value)
    }
}
