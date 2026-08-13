-- Messenger migration 002: explicit group identity and role constraints

ALTER TABLE messenger_conversations
  ADD COLUMN IF NOT EXISTS group_id varchar(128);

CREATE UNIQUE INDEX IF NOT EXISTS uq_messenger_conversation_group
  ON messenger_conversations(group_id)
  WHERE group_id IS NOT NULL;

-- kind=1 direct => no group_id; kind=2 group => group_id required.
ALTER TABLE messenger_conversations
  DROP CONSTRAINT IF EXISTS ck_messenger_conversation_group_identity;
ALTER TABLE messenger_conversations
  ADD CONSTRAINT ck_messenger_conversation_group_identity CHECK (
    (kind = 1 AND group_id IS NULL) OR
    (kind = 2 AND group_id IS NOT NULL)
  );

ALTER TABLE messenger_members
  DROP CONSTRAINT IF EXISTS ck_messenger_member_role;
ALTER TABLE messenger_members
  ADD CONSTRAINT ck_messenger_member_role CHECK (role BETWEEN 1 AND 4);

CREATE INDEX IF NOT EXISTS ix_messenger_members_conversation_active
  ON messenger_members(conversation_id, role, user_id)
  WHERE left_at IS NULL;
