-- EyesOnYou rule/config schema draft v1
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 2500;

CREATE TABLE IF NOT EXISTS schema_meta (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;

INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('schema_version', '1');
INSERT OR IGNORE INTO schema_meta(key, value) VALUES ('rule_generation', '0');

CREATE TABLE IF NOT EXISTS proxy_profiles (
    profile_id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    kind INTEGER NOT NULL,
    host TEXT,
    port INTEGER,
    credential_ref BLOB,
    dns_mode INTEGER NOT NULL DEFAULT 0,
    udp_fallback INTEGER NOT NULL DEFAULT 0,
    failure_policy INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_ms INTEGER NOT NULL,
    modified_ms INTEGER NOT NULL,
    CHECK(port IS NULL OR (port BETWEEN 1 AND 65535))
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS rules (
    rule_id TEXT PRIMARY KEY NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    priority INTEGER NOT NULL DEFAULT 0,

    app_match_kind INTEGER NOT NULL,
    app_team_id TEXT,
    app_signing_id TEXT,
    app_aux_value TEXT,

    destination_kind INTEGER NOT NULL,
    hostname_value TEXT,
    ip_family INTEGER,
    ip_bytes BLOB,
    prefix_length INTEGER,

    port_kind INTEGER NOT NULL,
    port_start INTEGER,
    port_end INTEGER,
    port_set_json TEXT,

    transport INTEGER NOT NULL,
    direction INTEGER NOT NULL,
    schedule_json TEXT,

    firewall_action INTEGER NOT NULL,
    route_action INTEGER NOT NULL,
    proxy_profile_id TEXT REFERENCES proxy_profiles(profile_id) ON DELETE RESTRICT,

    note TEXT,
    created_ms INTEGER NOT NULL,
    modified_ms INTEGER NOT NULL,

    CHECK(port_start IS NULL OR (port_start BETWEEN 0 AND 65535)),
    CHECK(port_end IS NULL OR (port_end BETWEEN 0 AND 65535)),
    CHECK(port_start IS NULL OR port_end IS NULL OR port_start <= port_end)
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_rules_enabled_priority
ON rules(enabled, priority DESC);

CREATE INDEX IF NOT EXISTS idx_rules_app
ON rules(app_team_id, app_signing_id);

CREATE TABLE IF NOT EXISTS rule_revisions (
    revision_id INTEGER PRIMARY KEY,
    generation INTEGER NOT NULL,
    created_ms INTEGER NOT NULL,
    snapshot_checksum BLOB NOT NULL,
    rule_count INTEGER NOT NULL,
    author_note TEXT
);
