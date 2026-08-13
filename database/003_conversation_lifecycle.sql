-- Messenger migration 003: canonical direct conversation pairs and lifecycle metadata

CREATE TABLE IF NOT EXISTS messenger_direct_pairs (
    user_low_id      varchar(128) NOT NULL,
    user_high_id     varchar(128) NOT NULL,
    conversation_id  varchar(64) NOT NULL UNIQUE
        REFERENCES messenger_conversations(id) ON DELETE CASCADE,
    created_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_low_id, user_high_id),
    CHECK (user_low_id < user_high_id)
);

CREATE INDEX IF NOT EXISTS ix_messenger_direct_pairs_conversation
    ON messenger_direct_pairs(conversation_id);

-- A group id is already unique through migration 002. Direct pairs use
-- lexicographically ordered user ids so retries/concurrent creates converge on
-- one logical pair. Conversation creation code must insert conversation,
-- direct-pair (for direct chats), and initial memberships in one transaction.
