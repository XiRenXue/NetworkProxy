-- NetworkProxy final-core schema, initial migration.
-- Requires SQLite >= 3.38 with JSON functions (bundled by the selected driver).
-- Execute on a new database. The migration runner records the real file checksum.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 20;

BEGIN IMMEDIATE;

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    checksum_sha256 TEXT NOT NULL CHECK (length(checksum_sha256) = 64),
    applied_at INTEGER NOT NULL CHECK (applied_at >= 0)
) STRICT;

CREATE TABLE secrets (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    purpose TEXT NOT NULL CHECK (purpose IN (
        'proxy-password', 'shadowsocks-key', 'upstream-auth', 'subscription-url',
        'subscription-auth', 'tls-private-key', 'api-token-export', 'other'
    )),
    algorithm TEXT NOT NULL DEFAULT 'aes-256-gcm' CHECK (algorithm = 'aes-256-gcm'),
    key_version INTEGER NOT NULL CHECK (key_version > 0),
    aad_version INTEGER NOT NULL DEFAULT 1 CHECK (aad_version = 1),
    nonce BLOB NOT NULL CHECK (length(nonce) = 12),
    ciphertext BLOB NOT NULL CHECK (length(ciphertext) > 0),
    auth_tag BLOB NOT NULL CHECK (length(auth_tag) = 16),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at),
    UNIQUE (key_version, nonce)
) STRICT;

CREATE TABLE admin_identity (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    password_algorithm TEXT NOT NULL DEFAULT 'scrypt' CHECK (password_algorithm = 'scrypt'),
    password_salt BLOB NOT NULL CHECK (length(password_salt) >= 16),
    password_hash BLOB NOT NULL CHECK (length(password_hash) BETWEEN 32 AND 128),
    password_params_json TEXT NOT NULL CHECK (json_valid(password_params_json)),
    session_epoch INTEGER NOT NULL DEFAULT 0 CHECK (session_epoch >= 0),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at)
) STRICT;

CREATE TABLE admin_sessions (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    admin_id INTEGER NOT NULL DEFAULT 1 REFERENCES admin_identity(id) ON DELETE CASCADE,
    token_hash BLOB NOT NULL UNIQUE CHECK (length(token_hash) = 32),
    session_epoch INTEGER NOT NULL CHECK (session_epoch >= 0),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    expires_at INTEGER NOT NULL CHECK (expires_at > created_at),
    last_seen_at INTEGER NOT NULL CHECK (last_seen_at >= created_at),
    user_agent TEXT CHECK (user_agent IS NULL OR length(user_agent) <= 512)
) STRICT;
CREATE INDEX admin_sessions_expiry_idx ON admin_sessions(expires_at);

CREATE TABLE api_tokens (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    admin_id INTEGER NOT NULL DEFAULT 1 REFERENCES admin_identity(id) ON DELETE CASCADE,
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    purpose TEXT NOT NULL CHECK (purpose IN ('clash', 'automation')),
    token_hash BLOB NOT NULL UNIQUE CHECK (length(token_hash) = 32),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    export_secret_id TEXT REFERENCES secrets(id) ON DELETE RESTRICT,
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    expires_at INTEGER CHECK (expires_at IS NULL OR expires_at > created_at),
    last_used_at INTEGER CHECK (last_used_at IS NULL OR last_used_at >= created_at)
) STRICT;

CREATE TABLE credentials (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    kind TEXT NOT NULL DEFAULT 'proxy' CHECK (kind IN ('proxy', 'internal-bridge')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    username TEXT UNIQUE CHECK (username IS NULL OR length(username) BETWEEN 1 AND 255),
    password_secret_id TEXT REFERENCES secrets(id) ON DELETE RESTRICT,
    shadowsocks_secret_id TEXT REFERENCES secrets(id) ON DELETE RESTRICT,
    expires_at INTEGER CHECK (expires_at IS NULL OR expires_at >= 0),
    max_tcp_sessions INTEGER CHECK (max_tcp_sessions IS NULL OR max_tcp_sessions > 0),
    max_udp_associations INTEGER CHECK (max_udp_associations IS NULL OR max_udp_associations > 0),
    max_udp_flows INTEGER CHECK (max_udp_flows IS NULL OR max_udp_flows > 0),
    max_new_sessions_per_second INTEGER CHECK (
        max_new_sessions_per_second IS NULL OR max_new_sessions_per_second > 0
    ),
    upload_bytes_per_second INTEGER CHECK (upload_bytes_per_second IS NULL OR upload_bytes_per_second > 0),
    download_bytes_per_second INTEGER CHECK (download_bytes_per_second IS NULL OR download_bytes_per_second > 0),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at),
    CHECK ((username IS NULL) = (password_secret_id IS NULL)),
    CHECK (kind = 'internal-bridge' OR name <> 'edge-owner'),
    CHECK (
        (kind = 'proxy' AND (password_secret_id IS NOT NULL OR shadowsocks_secret_id IS NOT NULL))
        OR
        (kind = 'internal-bridge' AND name = 'edge-owner' AND username IS NULL
            AND password_secret_id IS NULL AND shadowsocks_secret_id IS NULL)
    )
) STRICT;

CREATE TABLE tls_profiles (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    certificate_chain_pem TEXT NOT NULL CHECK (length(certificate_chain_pem) > 0),
    private_key_secret_id TEXT NOT NULL REFERENCES secrets(id) ON DELETE RESTRICT,
    options_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(options_json)),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at)
) STRICT;

CREATE TABLE listeners (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    protocol TEXT NOT NULL CHECK (protocol IN ('http', 'socks5', 'mixed', 'shadowsocks')),
    bind_host TEXT NOT NULL CHECK (length(bind_host) BETWEEN 1 AND 255),
    bind_port INTEGER NOT NULL CHECK (bind_port BETWEEN 1 AND 65535),
    network TEXT NOT NULL CHECK (network IN ('tcp', 'udp', 'tcp+udp')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    authentication_required INTEGER NOT NULL DEFAULT 1 CHECK (authentication_required IN (0, 1)),
    tls_profile_id TEXT REFERENCES tls_profiles(id) ON DELETE RESTRICT,
    default_outbound_id TEXT REFERENCES outbounds(id) ON DELETE RESTRICT,
    max_tcp_sessions INTEGER CHECK (max_tcp_sessions IS NULL OR max_tcp_sessions > 0),
    max_udp_flows INTEGER CHECK (max_udp_flows IS NULL OR max_udp_flows > 0),
    settings_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(settings_json)),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at),
    CHECK (protocol <> 'http' OR network = 'tcp'),
    CHECK (protocol <> 'mixed' OR network IN ('tcp', 'tcp+udp')),
    CHECK (protocol <> 'socks5' OR network IN ('tcp', 'tcp+udp')),
    CHECK (tls_profile_id IS NULL OR (protocol = 'http' AND network = 'tcp'))
) STRICT;
-- Conservative exact-address guard. Wildcards / dual-stack overlaps are checked before bind.
CREATE UNIQUE INDEX listeners_enabled_endpoint_idx
    ON listeners(bind_host, bind_port) WHERE enabled = 1;

CREATE TABLE listener_credentials (
    listener_id TEXT NOT NULL REFERENCES listeners(id) ON DELETE CASCADE,
    credential_id TEXT NOT NULL REFERENCES credentials(id) ON DELETE RESTRICT,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    PRIMARY KEY (listener_id, credential_id)
) STRICT;
CREATE INDEX listener_credentials_credential_idx ON listener_credentials(credential_id);

CREATE TABLE subscriptions (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    url_secret_id TEXT NOT NULL REFERENCES secrets(id) ON DELETE RESTRICT,
    display_url TEXT NOT NULL CHECK (length(display_url) <= 2048),
    format TEXT NOT NULL CHECK (format IN ('auto', 'clash-yaml', 'uri-list', 'base64-uri-list')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    fetch_outbound_id TEXT REFERENCES outbounds(id) ON DELETE RESTRICT,
    refresh_interval_seconds INTEGER NOT NULL DEFAULT 21600 CHECK (refresh_interval_seconds >= 60),
    request_timeout_ms INTEGER NOT NULL DEFAULT 15000 CHECK (request_timeout_ms BETWEEN 1000 AND 120000),
    max_response_bytes INTEGER NOT NULL DEFAULT 8388608 CHECK (max_response_bytes BETWEEN 1024 AND 16777216),
    etag TEXT CHECK (etag IS NULL OR length(etag) <= 1024),
    last_modified TEXT CHECK (last_modified IS NULL OR length(last_modified) <= 1024),
    last_attempt_at INTEGER CHECK (last_attempt_at IS NULL OR last_attempt_at >= 0),
    last_success_at INTEGER CHECK (last_success_at IS NULL OR last_success_at >= 0),
    last_error_code TEXT CHECK (last_error_code IS NULL OR length(last_error_code) <= 128),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at)
) STRICT;

CREATE TABLE outbounds (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 128),
    kind TEXT NOT NULL CHECK (kind IN ('node', 'group', 'builtin')),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    -- Registry names are deliberately open; saving a row never advertises protocol support.
    protocol TEXT NOT NULL CHECK (length(protocol) BETWEEN 1 AND 64),
    server_host TEXT CHECK (server_host IS NULL OR length(server_host) BETWEEN 1 AND 255),
    server_port INTEGER CHECK (server_port IS NULL OR server_port BETWEEN 1 AND 65535),
    auth_secret_id TEXT REFERENCES secrets(id) ON DELETE RESTRICT,
    transport TEXT CHECK (transport IS NULL OR length(transport) BETWEEN 1 AND 64),
    settings_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(settings_json)),
    group_strategy TEXT CHECK (group_strategy IN ('select', 'url-test', 'fallback', 'load-balance')),
    selected_outbound_id TEXT,
    subscription_id TEXT REFERENCES subscriptions(id) ON DELETE RESTRICT,
    subscription_source_key TEXT,
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at),
    CHECK ((kind = 'node') = (server_host IS NOT NULL AND server_port IS NOT NULL)),
    CHECK (kind = 'node' OR (server_host IS NULL AND server_port IS NULL)),
    CHECK ((kind = 'group') = (group_strategy IS NOT NULL)),
    CHECK (kind = 'group' OR selected_outbound_id IS NULL),
    CHECK (kind <> 'builtin' OR protocol IN ('direct', 'reject')),
    CHECK ((subscription_id IS NULL) = (subscription_source_key IS NULL)),
    CHECK (subscription_id IS NULL OR kind = 'node'),
    FOREIGN KEY (id, selected_outbound_id)
        REFERENCES proxy_group_members(group_id, member_id)
        DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE UNIQUE INDEX outbounds_subscription_identity_idx
    ON outbounds(subscription_id, subscription_source_key)
    WHERE subscription_id IS NOT NULL;
CREATE INDEX outbounds_kind_enabled_idx ON outbounds(kind, enabled);

CREATE TABLE proxy_group_members (
    group_id TEXT NOT NULL REFERENCES outbounds(id) ON DELETE CASCADE,
    member_id TEXT NOT NULL REFERENCES outbounds(id) ON DELETE RESTRICT,
    position INTEGER NOT NULL CHECK (position >= 0),
    weight INTEGER NOT NULL DEFAULT 1 CHECK (weight BETWEEN 1 AND 10000),
    PRIMARY KEY (group_id, member_id),
    UNIQUE (group_id, position),
    CHECK (group_id <> member_id)
) STRICT;
CREATE INDEX proxy_group_members_member_idx ON proxy_group_members(member_id);

CREATE TRIGGER proxy_group_members_validate_insert
BEFORE INSERT ON proxy_group_members
BEGIN
    SELECT RAISE(ABORT, 'membership parent must be a group')
    WHERE NOT EXISTS (SELECT 1 FROM outbounds WHERE id = NEW.group_id AND kind = 'group');
    SELECT RAISE(ABORT, 'proxy group cycle')
    WHERE EXISTS (
        WITH RECURSIVE reachable(id) AS (
            SELECT NEW.member_id
            UNION
            SELECT m.member_id FROM proxy_group_members m JOIN reachable r ON m.group_id = r.id
        )
        SELECT 1 FROM reachable WHERE id = NEW.group_id
    );
END;

CREATE TRIGGER proxy_group_members_immutable_endpoints
BEFORE UPDATE OF group_id, member_id ON proxy_group_members
WHEN NEW.group_id <> OLD.group_id OR NEW.member_id <> OLD.member_id
BEGIN
    SELECT RAISE(ABORT, 'replace membership instead of updating endpoints');
END;

CREATE TRIGGER outbounds_preserve_group_kind
BEFORE UPDATE OF kind ON outbounds
WHEN NEW.kind <> 'group' AND EXISTS (SELECT 1 FROM proxy_group_members WHERE group_id = OLD.id)
BEGIN
    SELECT RAISE(ABORT, 'remove group members before changing kind');
END;

CREATE TABLE route_rules (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    match_type TEXT NOT NULL CHECK (match_type IN (
        'domain', 'domain-suffix', 'domain-keyword', 'ip-cidr', 'source-ip-cidr',
        'destination-port', 'source-port', 'network', 'listener', 'credential',
        'and', 'or', 'not', 'match'
    )),
    condition_json TEXT NOT NULL CHECK (json_valid(condition_json)),
    outbound_id TEXT NOT NULL REFERENCES outbounds(id) ON DELETE RESTRICT,
    dns_policy TEXT NOT NULL DEFAULT 'inherit' CHECK (dns_policy IN ('inherit', 'remote', 'local')),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at)
) STRICT;
CREATE INDEX route_rules_outbound_idx ON route_rules(outbound_id);

CREATE TABLE app_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    document_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(document_json)),
    updated_at INTEGER NOT NULL CHECK (updated_at >= 0)
) STRICT;

CREATE TABLE config_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    base_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    state TEXT NOT NULL CHECK (state IN ('pending', 'applied', 'failed', 'superseded')),
    schema_version INTEGER NOT NULL CHECK (schema_version > 0),
    snapshot_json TEXT NOT NULL CHECK (json_valid(snapshot_json)),
    snapshot_sha256 TEXT NOT NULL CHECK (length(snapshot_sha256) = 64),
    actor TEXT NOT NULL CHECK (actor IN ('web', 'clash', 'cli', 'startup', 'subscription', 'recovery')),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    applied_at INTEGER CHECK (applied_at IS NULL OR applied_at >= created_at),
    failed_at INTEGER CHECK (failed_at IS NULL OR failed_at >= created_at),
    error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
    error_message TEXT CHECK (error_message IS NULL OR length(error_message) <= 2048),
    CHECK (state <> 'applied' OR applied_at IS NOT NULL),
    CHECK (state <> 'failed' OR failed_at IS NOT NULL)
) STRICT;
CREATE INDEX config_revisions_created_idx ON config_revisions(created_at DESC);

CREATE TABLE runtime_runs (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    app_version TEXT NOT NULL CHECK (length(app_version) BETWEEN 1 AND 128),
    node_version TEXT NOT NULL CHECK (length(node_version) BETWEEN 1 AND 128),
    initial_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    process_id INTEGER NOT NULL CHECK (process_id > 0),
    started_at INTEGER NOT NULL CHECK (started_at >= 0),
    ended_at INTEGER CHECK (ended_at IS NULL OR ended_at >= started_at),
    exit_kind TEXT CHECK (exit_kind IN ('clean', 'crash', 'forced', 'unknown')),
    CHECK ((ended_at IS NULL) = (exit_kind IS NULL))
) STRICT;

CREATE TABLE runtime_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    desired_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    applied_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    last_good_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    active_run_id TEXT REFERENCES runtime_runs(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'uninitialized' CHECK (status IN (
        'uninitialized', 'starting', 'ready', 'applying', 'degraded', 'draining', 'stopped', 'error'
    )),
    updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
    last_error_code TEXT CHECK (last_error_code IS NULL OR length(last_error_code) <= 128)
) STRICT;

CREATE TABLE caddy_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_config_revision_id INTEGER NOT NULL REFERENCES config_revisions(id) ON DELETE RESTRICT,
    state TEXT NOT NULL CHECK (state IN ('pending', 'applied', 'failed', 'superseded')),
    -- Internal secretRef template, NOT a render-ready Caddy configuration.
    -- Plaintext basic_auth passwords are resolved only in process memory.
    template_version INTEGER NOT NULL DEFAULT 1 CHECK (template_version = 1),
    template_json TEXT NOT NULL CHECK (json_valid(template_json)),
    template_sha256 TEXT NOT NULL CHECK (length(template_sha256) = 64),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    applied_at INTEGER CHECK (applied_at IS NULL OR applied_at >= created_at),
    failed_at INTEGER CHECK (failed_at IS NULL OR failed_at >= created_at),
    error_code TEXT CHECK (error_code IS NULL OR length(error_code) <= 128),
    CHECK (state <> 'applied' OR applied_at IS NOT NULL),
    CHECK (state <> 'failed' OR failed_at IS NOT NULL)
) STRICT;
CREATE INDEX caddy_revisions_source_idx ON caddy_revisions(source_config_revision_id);

CREATE TABLE caddy_revision_secrets (
    caddy_revision_id INTEGER NOT NULL REFERENCES caddy_revisions(id) ON DELETE CASCADE,
    secret_id TEXT NOT NULL REFERENCES secrets(id) ON DELETE RESTRICT,
    PRIMARY KEY (caddy_revision_id, secret_id)
) STRICT;
CREATE INDEX caddy_revision_secrets_secret_idx ON caddy_revision_secrets(secret_id);

CREATE TABLE caddy_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
    desired_revision_id INTEGER REFERENCES caddy_revisions(id) ON DELETE RESTRICT,
    applied_revision_id INTEGER REFERENCES caddy_revisions(id) ON DELETE RESTRICT,
    last_good_revision_id INTEGER REFERENCES caddy_revisions(id) ON DELETE RESTRICT,
    status TEXT NOT NULL DEFAULT 'disabled' CHECK (status IN (
        'disabled', 'starting', 'ready', 'applying', 'degraded', 'stopped', 'error'
    )),
    updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
    last_error_code TEXT CHECK (last_error_code IS NULL OR length(last_error_code) <= 128)
) STRICT;

CREATE TABLE management_operations (
    id TEXT PRIMARY KEY CHECK (length(id) BETWEEN 1 AND 128),
    type TEXT NOT NULL CHECK (type IN (
        'config-apply', 'config-rollback', 'subscription-refresh', 'node-test',
        'backup-create', 'backup-restore', 'deployment-reconcile'
    )),
    config_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    caddy_revision_id INTEGER REFERENCES caddy_revisions(id) ON DELETE RESTRICT,
    phase TEXT NOT NULL DEFAULT 'queued' CHECK (phase IN (
        'queued', 'validating', 'preparing', 'running', 'applyingNode',
        'applyingCaddy', 'verifying', 'succeeded', 'failed', 'rolledBack',
        'requiresRestart', 'interrupted'
    )),
    requested_by TEXT NOT NULL CHECK (requested_by IN ('admin', 'clash-token', 'automation', 'system')),
    created_at INTEGER NOT NULL CHECK (created_at >= 0),
    started_at INTEGER CHECK (started_at IS NULL OR started_at >= created_at),
    updated_at INTEGER NOT NULL CHECK (updated_at >= created_at),
    finished_at INTEGER CHECK (finished_at IS NULL OR finished_at >= created_at),
    result_json TEXT CHECK (result_json IS NULL OR json_valid(result_json)),
    error_json TEXT CHECK (error_json IS NULL OR json_valid(error_json)),
    CHECK ((phase IN ('succeeded', 'failed', 'rolledBack', 'requiresRestart', 'interrupted'))
        = (finished_at IS NOT NULL)),
    CHECK (phase NOT IN ('failed', 'interrupted') OR error_json IS NOT NULL)
) STRICT;
CREATE INDEX management_operations_phase_idx ON management_operations(phase, created_at);
CREATE INDEX management_operations_revision_idx ON management_operations(config_revision_id);
CREATE INDEX management_operations_created_idx ON management_operations(created_at DESC);

CREATE TABLE usage_totals (
    dimension TEXT NOT NULL CHECK (dimension IN ('global', 'credential', 'listener', 'outbound')),
    subject_id TEXT NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 128),
    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= 0),
    PRIMARY KEY (dimension, subject_id),
    CHECK (dimension <> 'global' OR subject_id = 'global')
) STRICT;

CREATE TABLE usage_buckets (
    dimension TEXT NOT NULL CHECK (dimension IN ('global', 'credential', 'listener', 'outbound')),
    subject_id TEXT NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 128),
    bucket_start INTEGER NOT NULL CHECK (bucket_start >= 0 AND bucket_start % 3600000 = 0),
    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
    updated_at INTEGER NOT NULL CHECK (updated_at >= bucket_start),
    PRIMARY KEY (dimension, subject_id, bucket_start),
    CHECK (dimension <> 'global' OR subject_id = 'global')
) STRICT;
CREATE INDEX usage_buckets_retention_idx ON usage_buckets(bucket_start);

CREATE TABLE usage_checkpoints (
    run_id TEXT NOT NULL REFERENCES runtime_runs(id) ON DELETE RESTRICT,
    dimension TEXT NOT NULL CHECK (dimension IN ('global', 'credential', 'listener', 'outbound')),
    subject_id TEXT NOT NULL CHECK (length(subject_id) BETWEEN 1 AND 128),
    sequence INTEGER NOT NULL CHECK (sequence >= 0),
    upload_bytes INTEGER NOT NULL CHECK (upload_bytes >= 0),
    download_bytes INTEGER NOT NULL CHECK (download_bytes >= 0),
    sampled_at INTEGER NOT NULL CHECK (sampled_at >= 0),
    PRIMARY KEY (run_id, dimension, subject_id),
    CHECK (dimension <> 'global' OR subject_id = 'global')
) STRICT;
CREATE INDEX usage_checkpoints_subject_idx ON usage_checkpoints(dimension, subject_id);

CREATE TRIGGER usage_checkpoints_monotonic
BEFORE UPDATE ON usage_checkpoints
BEGIN
    SELECT RAISE(ABORT, 'checkpoint identity is immutable')
    WHERE NEW.run_id <> OLD.run_id OR NEW.dimension <> OLD.dimension OR NEW.subject_id <> OLD.subject_id;
    SELECT RAISE(ABORT, 'checkpoint must be monotonic')
    WHERE NEW.sequence < OLD.sequence OR NEW.upload_bytes < OLD.upload_bytes
       OR NEW.download_bytes < OLD.download_bytes OR NEW.sampled_at < OLD.sampled_at;
    SELECT RAISE(ABORT, 'replayed checkpoint differs')
    WHERE NEW.sequence = OLD.sequence AND (
        NEW.upload_bytes <> OLD.upload_bytes OR NEW.download_bytes <> OLD.download_bytes
        OR NEW.sampled_at <> OLD.sampled_at
    );
END;

CREATE TRIGGER usage_checkpoints_accumulate_insert
AFTER INSERT ON usage_checkpoints
BEGIN
    INSERT INTO usage_totals(dimension, subject_id, upload_bytes, download_bytes, updated_at)
    VALUES (NEW.dimension, NEW.subject_id, NEW.upload_bytes, NEW.download_bytes, NEW.sampled_at)
    ON CONFLICT (dimension, subject_id) DO UPDATE SET
        upload_bytes = usage_totals.upload_bytes + excluded.upload_bytes,
        download_bytes = usage_totals.download_bytes + excluded.download_bytes,
        updated_at = max(usage_totals.updated_at, excluded.updated_at);

    INSERT INTO usage_buckets(dimension, subject_id, bucket_start, upload_bytes, download_bytes, updated_at)
    VALUES (NEW.dimension, NEW.subject_id, (NEW.sampled_at / 3600000) * 3600000,
        NEW.upload_bytes, NEW.download_bytes, NEW.sampled_at)
    ON CONFLICT (dimension, subject_id, bucket_start) DO UPDATE SET
        upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
        download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
        updated_at = max(usage_buckets.updated_at, excluded.updated_at);
END;

CREATE TRIGGER usage_checkpoints_accumulate_update
AFTER UPDATE ON usage_checkpoints
WHEN NEW.sequence > OLD.sequence
BEGIN
    INSERT INTO usage_totals(dimension, subject_id, upload_bytes, download_bytes, updated_at)
    VALUES (NEW.dimension, NEW.subject_id,
        NEW.upload_bytes - OLD.upload_bytes, NEW.download_bytes - OLD.download_bytes, NEW.sampled_at)
    ON CONFLICT (dimension, subject_id) DO UPDATE SET
        upload_bytes = usage_totals.upload_bytes + excluded.upload_bytes,
        download_bytes = usage_totals.download_bytes + excluded.download_bytes,
        updated_at = max(usage_totals.updated_at, excluded.updated_at);

    INSERT INTO usage_buckets(dimension, subject_id, bucket_start, upload_bytes, download_bytes, updated_at)
    VALUES (NEW.dimension, NEW.subject_id, (NEW.sampled_at / 3600000) * 3600000,
        NEW.upload_bytes - OLD.upload_bytes, NEW.download_bytes - OLD.download_bytes, NEW.sampled_at)
    ON CONFLICT (dimension, subject_id, bucket_start) DO UPDATE SET
        upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
        download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
        updated_at = max(usage_buckets.updated_at, excluded.updated_at);
END;

CREATE TABLE audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL CHECK (at >= 0),
    actor TEXT NOT NULL CHECK (actor IN ('admin', 'clash-token', 'automation', 'system')),
    action TEXT NOT NULL CHECK (length(action) BETWEEN 1 AND 128),
    object_type TEXT NOT NULL CHECK (length(object_type) BETWEEN 1 AND 64),
    object_id TEXT CHECK (object_id IS NULL OR length(object_id) <= 128),
    config_revision_id INTEGER REFERENCES config_revisions(id) ON DELETE RESTRICT,
    result TEXT NOT NULL CHECK (result IN ('success', 'failure')),
    detail_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(detail_json))
) STRICT;
CREATE INDEX audit_events_at_idx ON audit_events(at DESC);
CREATE INDEX audit_events_object_idx ON audit_events(object_type, object_id, at DESC);

INSERT INTO app_settings(id, document_json, updated_at) VALUES (1, '{}', 0);
INSERT INTO runtime_state(id, status, updated_at) VALUES (1, 'uninitialized', 0);
INSERT INTO caddy_state(id, enabled, status, updated_at) VALUES (1, 0, 'disabled', 0);

COMMIT;
