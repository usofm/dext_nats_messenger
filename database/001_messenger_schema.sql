-- Dext NATS Messenger - PostgreSQL durable schema v1
-- PostgreSQL 17/18 target. Business access is intended through Dext Entity ORM.
--
-- CRITICAL INVARIANT:
-- message row + conversation sequence + outbox row are committed in ONE DB
-- transaction. NATS/JetStream publication happens asynchronously from outbox.

CREATE TABLE IF NOT EXISTS messenger_conversations (
    id              varchar(64) PRIMARY KEY,
    kind            smallint NOT NULL CHECK (kind IN (1,2)), -- 1=direct, 2=group
    title           varchar(200),
    created_by      varchar(128) NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_sequence   bigint NOT NULL DEFAULT 0 CHECK (last_sequence >= 0),
    last_message_at timestamptz
);

CREATE TABLE IF NOT EXISTS messenger_members (
    conversation_id varchar(64) NOT NULL REFERENCES messenger_conversations(id) ON DELETE CASCADE,
    user_id         varchar(128) NOT NULL,
    role            smallint NOT NULL DEFAULT 1,
    joined_at       timestamptz NOT NULL DEFAULT now(),
    left_at         timestamptz,
    PRIMARY KEY (conversation_id, user_id)
);

CREATE INDEX IF NOT EXISTS ix_messenger_members_user
    ON messenger_members(user_id, conversation_id)
    WHERE left_at IS NULL;

CREATE TABLE IF NOT EXISTS messenger_messages (
    message_id         varchar(64) PRIMARY KEY,
    client_message_id  varchar(128) NOT NULL,
    conversation_id    varchar(64) NOT NULL REFERENCES messenger_conversations(id) ON DELETE CASCADE,
    sender_user_id     varchar(128) NOT NULL,
    destination_kind   smallint NOT NULL CHECK (destination_kind IN (1,2)), -- 1=user, 2=group
    destination_id     varchar(128) NOT NULL,
    sequence_no        bigint NOT NULL CHECK (sequence_no > 0),
    partition_no       integer NOT NULL CHECK (partition_no >= 0),
    message_kind       smallint NOT NULL,
    payload_json       jsonb NOT NULL,
    created_at         timestamptz NOT NULL,
    persisted_at       timestamptz NOT NULL DEFAULT now(),
    deleted_at         timestamptz,
    edited_at          timestamptz,
    CONSTRAINT uq_messenger_sender_client UNIQUE (sender_user_id, client_message_id),
    CONSTRAINT uq_messenger_conversation_seq UNIQUE (conversation_id, sequence_no)
);

CREATE INDEX IF NOT EXISTS ix_messenger_messages_conv_seq
    ON messenger_messages(conversation_id, sequence_no DESC);

CREATE INDEX IF NOT EXISTS ix_messenger_messages_sender_created
    ON messenger_messages(sender_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS ix_messenger_messages_destination
    ON messenger_messages(destination_kind, destination_id, created_at DESC);

-- Transactional outbox. One row exists for each durable event that must reach
-- NATS/JetStream. Workers claim rows with SKIP LOCKED/lease semantics.
CREATE TABLE IF NOT EXISTS messenger_outbox (
    outbox_id           varchar(160) PRIMARY KEY,
    event_type          varchar(80) NOT NULL,
    message_id          varchar(64) NOT NULL REFERENCES messenger_messages(message_id) ON DELETE CASCADE,
    partition_no        integer NOT NULL CHECK (partition_no >= 0),
    sequence_no         bigint NOT NULL CHECK (sequence_no > 0),
    status              smallint NOT NULL DEFAULT 0 CHECK (status IN (0,1)), -- pending/published
    attempt_count       integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    available_at        timestamptz NOT NULL DEFAULT now(),
    lease_owner         varchar(128),
    lease_until         timestamptz,
    last_error          varchar(2000),
    created_at          timestamptz NOT NULL DEFAULT now(),
    published_at        timestamptz,
    CONSTRAINT uq_messenger_outbox_message_event UNIQUE (message_id, event_type)
);

CREATE INDEX IF NOT EXISTS ix_messenger_outbox_pending
    ON messenger_outbox(status, available_at, created_at)
    WHERE status = 0;

CREATE INDEX IF NOT EXISTS ix_messenger_outbox_lease
    ON messenger_outbox(lease_until)
    WHERE status = 0 AND lease_owner IS NOT NULL;

CREATE TABLE IF NOT EXISTS messenger_user_cursors (
    user_id             varchar(128) NOT NULL,
    conversation_id     varchar(64) NOT NULL REFERENCES messenger_conversations(id) ON DELETE CASCADE,
    delivered_sequence  bigint NOT NULL DEFAULT 0 CHECK (delivered_sequence >= 0),
    read_sequence       bigint NOT NULL DEFAULT 0 CHECK (read_sequence >= 0),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, conversation_id),
    CHECK (read_sequence <= delivered_sequence)
);

CREATE TABLE IF NOT EXISTS messenger_devices (
    user_id          varchar(128) NOT NULL,
    device_id        varchar(128) NOT NULL,
    platform         varchar(32),
    push_token       text,
    push_provider    varchar(32),
    last_seen_at     timestamptz,
    disabled_at      timestamptz,
    PRIMARY KEY (user_id, device_id)
);

CREATE TABLE IF NOT EXISTS messenger_message_receipts (
    message_id       varchar(64) NOT NULL REFERENCES messenger_messages(message_id) ON DELETE CASCADE,
    user_id          varchar(128) NOT NULL,
    device_id        varchar(128) NOT NULL,
    receipt_state    smallint NOT NULL CHECK (receipt_state IN (1,2)), -- delivered/read
    at_time          timestamptz NOT NULL,
    PRIMARY KEY (message_id, user_id, device_id, receipt_state)
);

CREATE INDEX IF NOT EXISTS ix_messenger_receipts_user_time
    ON messenger_message_receipts(user_id, at_time DESC);

-- REFERENCE ACCEPTANCE TRANSACTION
-- --------------------------------
-- BEGIN;
--
-- 1) Resolve duplicate first:
-- SELECT message_id, conversation_id, sequence_no, ...
-- FROM messenger_messages
-- WHERE sender_user_id = :sender_user_id
--   AND client_message_id = :client_message_id;
--
-- If found, compare immutable command fields. If they differ, return an
-- idempotency conflict. If equal, return the existing canonical row.
--
-- 2) Allocate conversation sequence under row lock:
-- UPDATE messenger_conversations
-- SET last_sequence = last_sequence + 1,
--     last_message_at = :created_at
-- WHERE id = :conversation_id
-- RETURNING last_sequence;
--
-- 3) INSERT messenger_messages using returned last_sequence.
--
-- 4) INSERT messenger_outbox(
--      outbox_id, event_type, message_id, partition_no, sequence_no)
--    VALUES (
--      'message.accepted:' || :message_id,
--      'message.accepted.v1', :message_id, :partition_no, :sequence_no);
--
-- COMMIT;
--
-- The unique (sender_user_id, client_message_id) constraint is the final race
-- guard. On unique_violation, rollback and re-read the canonical existing row.

-- REFERENCE OUTBOX CLAIM
-- ----------------------
-- Use a short DB transaction with SELECT ... FOR UPDATE SKIP LOCKED to claim
-- pending rows, set lease_owner/lease_until, commit, then publish outside the
-- transaction. On success mark published; on failure clear lease and schedule
-- available_at with exponential backoff. JetStream Nats-Msg-Id makes publish
-- retries broker-idempotent inside its deduplication window.

-- Monotonic cursor update pattern:
-- INSERT INTO messenger_user_cursors(user_id, conversation_id, delivered_sequence, read_sequence)
-- VALUES (:user_id, :conversation_id, :delivered, :read)
-- ON CONFLICT (user_id, conversation_id) DO UPDATE SET
--   delivered_sequence = GREATEST(messenger_user_cursors.delivered_sequence, EXCLUDED.delivered_sequence),
--   read_sequence      = GREATEST(messenger_user_cursors.read_sequence, EXCLUDED.read_sequence),
--   updated_at         = now();
