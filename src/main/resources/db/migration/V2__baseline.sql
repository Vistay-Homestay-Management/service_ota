SET search_path TO app, extensions, public;

CREATE TABLE ota_connections (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider_code varchar(40) NOT NULL,
    connection_name varchar(160) NOT NULL,
    external_account_id varchar(180),
    status varchar(24) NOT NULL DEFAULT 'DISCONNECTED',
    sync_enabled boolean NOT NULL DEFAULT false,
    booking_sync_enabled boolean NOT NULL DEFAULT true,
    availability_sync_enabled boolean NOT NULL DEFAULT false,
    price_sync_enabled boolean NOT NULL DEFAULT false,
    listing_sync_enabled boolean NOT NULL DEFAULT false,
    last_connected_at timestamptz,
    last_health_check_at timestamptz,
    version bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_ota_provider_code CHECK (provider_code ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_ota_connection_status CHECK (status IN ('CONNECTED', 'DISCONNECTED', 'ERROR', 'DISABLED')),
    UNIQUE (provider_code, connection_name)
);
CREATE UNIQUE INDEX ux_ota_external_account
    ON ota_connections(provider_code, external_account_id)
    WHERE external_account_id IS NOT NULL;

-- Only secret manager references and expiry metadata are stored here.
CREATE TABLE ota_credential_references (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id uuid NOT NULL REFERENCES ota_connections(id) ON DELETE CASCADE,
    credential_type varchar(32) NOT NULL,
    secret_reference varchar(500) NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'ACTIVE',
    expires_at timestamptz,
    rotated_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_ota_credential_type CHECK (credential_type IN ('API_KEY', 'OAUTH_TOKEN_SET', 'BASIC_AUTH', 'SIGNING_SECRET', 'OTHER')),
    CONSTRAINT ck_ota_credential_status CHECK (status IN ('ACTIVE', 'EXPIRING', 'EXPIRED', 'REVOKED')),
    UNIQUE (connection_id, credential_type)
);

CREATE TABLE ota_listings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id uuid NOT NULL REFERENCES ota_connections(id) ON DELETE CASCADE,
    property_id uuid NOT NULL,
    product_type varchar(24) NOT NULL DEFAULT 'PROPERTY',
    external_listing_id varchar(180) NOT NULL,
    external_rate_plan_id varchar(180),
    listing_url varchar(1000),
    listing_status varchar(24) NOT NULL DEFAULT 'UNKNOWN',
    sync_enabled boolean NOT NULL DEFAULT true,
    last_synced_at timestamptz,
    last_sync_status varchar(24),
    last_sync_error varchar(1000),
    version bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_ota_listing_product CHECK (product_type IN ('PROPERTY', 'ROOM_TYPE')),
    CONSTRAINT ck_ota_listing_status CHECK (listing_status IN ('UNKNOWN', 'DRAFT', 'ACTIVE', 'PAUSED', 'CLOSED', 'ERROR')),
    CONSTRAINT ck_ota_listing_sync_status CHECK (last_sync_status IS NULL OR last_sync_status IN ('SUCCEEDED', 'PARTIAL', 'FAILED')),
    UNIQUE (connection_id, external_listing_id)
);
CREATE INDEX ix_ota_listing_property ON ota_listings(property_id, sync_enabled);

CREATE TABLE ota_booking_mappings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id uuid NOT NULL REFERENCES ota_connections(id),
    listing_id uuid REFERENCES ota_listings(id) ON DELETE SET NULL,
    external_booking_id varchar(180) NOT NULL,
    booking_id uuid,
    external_status varchar(80),
    synchronization_status varchar(24) NOT NULL DEFAULT 'PENDING',
    external_updated_at timestamptz,
    last_received_at timestamptz NOT NULL DEFAULT now(),
    last_synced_at timestamptz,
    version bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_ota_booking_sync_status CHECK (synchronization_status IN ('PENDING', 'MAPPED', 'SYNCED', 'CONFLICT', 'FAILED', 'CANCELLED')),
    UNIQUE (connection_id, external_booking_id)
);
CREATE INDEX ix_ota_booking_internal ON ota_booking_mappings(booking_id) WHERE booking_id IS NOT NULL;
CREATE INDEX ix_ota_booking_conflict ON ota_booking_mappings(synchronization_status, last_received_at) WHERE synchronization_status IN ('PENDING', 'CONFLICT', 'FAILED');

CREATE TABLE ota_webhook_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id uuid NOT NULL REFERENCES ota_connections(id),
    external_event_id varchar(180) NOT NULL,
    event_type varchar(120) NOT NULL,
    payload_sha256 char(64) NOT NULL,
    sanitized_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    signature_valid boolean NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'RECEIVED',
    received_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz,
    processing_error text,
    CONSTRAINT ck_ota_webhook_payload CHECK (jsonb_typeof(sanitized_payload) = 'object'),
    CONSTRAINT ck_ota_webhook_status CHECK (status IN ('RECEIVED', 'PROCESSING', 'PROCESSED', 'IGNORED', 'FAILED', 'QUARANTINED')),
    UNIQUE (connection_id, external_event_id)
);
CREATE INDEX ix_ota_webhook_queue ON ota_webhook_events(status, received_at) WHERE status IN ('RECEIVED', 'FAILED');

CREATE TABLE ota_sync_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id uuid NOT NULL REFERENCES ota_connections(id),
    listing_id uuid REFERENCES ota_listings(id) ON DELETE CASCADE,
    booking_mapping_id uuid REFERENCES ota_booking_mappings(id) ON DELETE SET NULL,
    sync_type varchar(32) NOT NULL,
    direction varchar(16) NOT NULL,
    idempotency_key varchar(180) NOT NULL UNIQUE,
    status varchar(24) NOT NULL DEFAULT 'PENDING',
    priority smallint NOT NULL DEFAULT 5,
    attempt_count integer NOT NULL DEFAULT 0,
    maximum_attempts integer NOT NULL DEFAULT 8,
    next_retry_at timestamptz,
    started_at timestamptz,
    completed_at timestamptz,
    last_error_code varchar(100),
    last_error_message varchar(2000),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_ota_sync_type CHECK (sync_type IN ('LISTING', 'PRICE', 'AVAILABILITY', 'BOOKING_CREATE', 'BOOKING_UPDATE', 'BOOKING_CANCEL', 'RECONCILIATION')),
    CONSTRAINT ck_ota_sync_direction CHECK (direction IN ('INBOUND', 'OUTBOUND')),
    CONSTRAINT ck_ota_sync_status CHECK (status IN ('PENDING', 'RUNNING', 'RETRY_WAIT', 'SUCCEEDED', 'PARTIAL', 'FAILED', 'CANCELLED')),
    CONSTRAINT ck_ota_sync_attempts CHECK (attempt_count >= 0 AND maximum_attempts > 0 AND attempt_count <= maximum_attempts),
    CONSTRAINT ck_ota_sync_priority CHECK (priority BETWEEN 1 AND 9),
    CONSTRAINT ck_ota_sync_payload CHECK (jsonb_typeof(payload) = 'object')
);
CREATE INDEX ix_ota_sync_queue ON ota_sync_jobs(status, priority, next_retry_at, created_at) WHERE status IN ('PENDING', 'RETRY_WAIT');

CREATE TABLE ota_sync_attempts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sync_job_id uuid NOT NULL REFERENCES ota_sync_jobs(id) ON DELETE CASCADE,
    attempt_number integer NOT NULL,
    result varchar(24) NOT NULL,
    http_status integer,
    provider_request_id varchar(180),
    error_code varchar(100),
    error_message varchar(2000),
    attempted_at timestamptz NOT NULL DEFAULT now(),
    duration_ms integer,
    CONSTRAINT ck_ota_attempt_number CHECK (attempt_number > 0),
    CONSTRAINT ck_ota_attempt_result CHECK (result IN ('SUCCEEDED', 'PARTIAL', 'FAILED', 'TIMEOUT', 'RATE_LIMITED')),
    CONSTRAINT ck_ota_attempt_duration CHECK (duration_ms IS NULL OR duration_ms >= 0),
    UNIQUE (sync_job_id, attempt_number)
);

CREATE TABLE ota_reconciliation_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id uuid NOT NULL REFERENCES ota_connections(id),
    scope varchar(24) NOT NULL,
    period_start timestamptz NOT NULL,
    period_end timestamptz NOT NULL,
    status varchar(24) NOT NULL DEFAULT 'RUNNING',
    checked_count integer NOT NULL DEFAULT 0,
    mismatch_count integer NOT NULL DEFAULT 0,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    started_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    CONSTRAINT ck_ota_reconciliation_scope CHECK (scope IN ('BOOKINGS', 'AVAILABILITY', 'PRICES', 'LISTINGS', 'ALL')),
    CONSTRAINT ck_ota_reconciliation_period CHECK (period_end > period_start),
    CONSTRAINT ck_ota_reconciliation_status CHECK (status IN ('RUNNING', 'SUCCEEDED', 'PARTIAL', 'FAILED', 'CANCELLED')),
    CONSTRAINT ck_ota_reconciliation_counts CHECK (checked_count >= 0 AND mismatch_count >= 0 AND mismatch_count <= checked_count),
    CONSTRAINT ck_ota_reconciliation_details CHECK (jsonb_typeof(details) = 'object')
);

CREATE TABLE processed_events (
    event_id uuid NOT NULL,
    consumer_name varchar(120) NOT NULL,
    processed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, consumer_name)
);

CREATE TABLE outbox_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type varchar(100) NOT NULL,
    aggregate_id uuid NOT NULL,
    aggregate_version bigint NOT NULL CHECK (aggregate_version >= 0),
    event_type varchar(160) NOT NULL,
    event_version integer NOT NULL DEFAULT 1 CHECK (event_version > 0),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    publish_attempts integer NOT NULL DEFAULT 0 CHECK (publish_attempts >= 0),
    last_error text,
    correlation_id varchar(100),
    causation_id varchar(100)
);
CREATE INDEX ix_ota_outbox_pending ON outbox_events(available_at, occurred_at) WHERE published_at IS NULL;

CREATE TABLE audit_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_admin_user_id uuid,
    action varchar(100) NOT NULL,
    aggregate_type varchar(100) NOT NULL,
    aggregate_id uuid NOT NULL,
    changes jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(changes) = 'object'),
    correlation_id varchar(100),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_ota_audit_aggregate ON audit_events(aggregate_type, aggregate_id, created_at DESC);
