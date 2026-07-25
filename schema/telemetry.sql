-- EyesOnYou telemetry schema draft v1
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 2500;

CREATE TABLE IF NOT EXISTS schema_meta (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', '1');

CREATE TABLE IF NOT EXISTS apps (
    app_id INTEGER PRIMARY KEY,
    team_id TEXT NOT NULL DEFAULT '',
    signing_id TEXT NOT NULL,
    display_name TEXT,
    bundle_path TEXT,
    parent_signing_id TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    is_apple_signed INTEGER,
    is_unsigned INTEGER NOT NULL DEFAULT 0,
    UNIQUE(team_id, signing_id)
);

CREATE INDEX IF NOT EXISTS idx_apps_signing_id ON apps(signing_id);
CREATE INDEX IF NOT EXISTS idx_apps_last_seen ON apps(last_seen_ms DESC);

CREATE TABLE IF NOT EXISTS app_builds (
    build_id INTEGER PRIMARY KEY,
    app_id INTEGER NOT NULL REFERENCES apps(app_id) ON DELETE CASCADE,
    cdhash BLOB NOT NULL DEFAULT X'',
    bundle_version TEXT,
    executable_path TEXT,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    UNIQUE(app_id, cdhash)
);

CREATE TABLE IF NOT EXISTS destinations (
    destination_id INTEGER PRIMARY KEY,
    canonical_key TEXT NOT NULL UNIQUE,
    hostname TEXT,
    registrable_domain TEXT,
    ip_family INTEGER,
    ip_bytes BLOB,
    port INTEGER,
    first_seen_ms INTEGER NOT NULL,
    last_seen_ms INTEGER NOT NULL,
    CHECK(port IS NULL OR (port BETWEEN 0 AND 65535))
);

-- Reserved unknown destination row.
INSERT OR IGNORE INTO destinations(
    destination_id, canonical_key, hostname, registrable_domain, ip_family, ip_bytes, port,
    first_seen_ms, last_seen_ms
) VALUES (0, 'unknown', NULL, NULL, NULL, NULL, NULL, 0, 0);

CREATE TABLE IF NOT EXISTS traffic_buckets (
    granularity_sec INTEGER NOT NULL,
    bucket_start_ms INTEGER NOT NULL,
    app_id INTEGER NOT NULL REFERENCES apps(app_id) ON DELETE CASCADE,
    destination_id INTEGER NOT NULL DEFAULT 0 REFERENCES destinations(destination_id),
    transport INTEGER NOT NULL,
    route_kind INTEGER NOT NULL,
    verdict INTEGER NOT NULL,
    bytes_up INTEGER NOT NULL DEFAULT 0 CHECK(bytes_up >= 0),
    bytes_down INTEGER NOT NULL DEFAULT 0 CHECK(bytes_down >= 0),
    flows_opened INTEGER NOT NULL DEFAULT 0 CHECK(flows_opened >= 0),
    flows_closed INTEGER NOT NULL DEFAULT 0 CHECK(flows_closed >= 0),
    flows_blocked INTEGER NOT NULL DEFAULT 0 CHECK(flows_blocked >= 0),
    active_peak INTEGER NOT NULL DEFAULT 0 CHECK(active_peak >= 0),
    PRIMARY KEY(
        granularity_sec, bucket_start_ms, app_id, destination_id,
        transport, route_kind, verdict
    )
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_buckets_app_time
ON traffic_buckets(app_id, granularity_sec, bucket_start_ms DESC);

CREATE INDEX IF NOT EXISTS idx_buckets_time
ON traffic_buckets(granularity_sec, bucket_start_ms DESC);

CREATE TABLE IF NOT EXISTS flows (
    flow_id BLOB PRIMARY KEY NOT NULL,
    app_id INTEGER NOT NULL REFERENCES apps(app_id) ON DELETE CASCADE,
    build_id INTEGER REFERENCES app_builds(build_id) ON DELETE SET NULL,
    destination_id INTEGER NOT NULL DEFAULT 0 REFERENCES destinations(destination_id),
    opened_ms INTEGER NOT NULL,
    closed_ms INTEGER,
    direction INTEGER NOT NULL,
    transport INTEGER NOT NULL,
    firewall_action INTEGER NOT NULL,
    route_kind INTEGER NOT NULL,
    proxy_profile_id TEXT,
    bytes_up INTEGER NOT NULL DEFAULT 0,
    bytes_down INTEGER NOT NULL DEFAULT 0,
    close_reason INTEGER,
    proxy_confidence INTEGER NOT NULL DEFAULT 0,
    proxy_evidence INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_flows_opened ON flows(opened_ms DESC);
CREATE INDEX IF NOT EXISTS idx_flows_app_opened ON flows(app_id, opened_ms DESC);

CREATE TABLE IF NOT EXISTS route_events (
    event_id INTEGER PRIMARY KEY,
    flow_id BLOB,
    timestamp_ms INTEGER NOT NULL,
    route_kind INTEGER NOT NULL,
    profile_id TEXT,
    outcome INTEGER NOT NULL,
    latency_ms INTEGER,
    error_domain TEXT,
    error_code INTEGER
);

CREATE INDEX IF NOT EXISTS idx_route_events_time ON route_events(timestamp_ms DESC);
