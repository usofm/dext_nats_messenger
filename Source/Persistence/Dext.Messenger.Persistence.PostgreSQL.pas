unit Dext.Messenger.Persistence.PostgreSQL;

interface

uses
  System.SysUtils,
  Dext.Entity.Drivers.Interfaces,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Commands,
  Dext.Messenger.Outbox,
  Dext.Messenger.Persistence.DbContext;

type
  EMessengerPostgreSQLError = class(Exception);
  EMessengerIdempotencyConflict = class(EMessengerPostgreSQLError);

  { Specialized PostgreSQL boundary for the two operations that require DB
    concurrency primitives not expressible as ordinary tracked CRUD:
      1. atomic message + conversation sequence + outbox acceptance
      2. leased outbox claiming with FOR UPDATE SKIP LOCKED
    Normal product CRUD remains available through TMessengerDbContext DbSets. }
  TMessengerPostgreSQLStore = class(TInterfacedObject,
    IMessengerAcceptanceStore, IMessengerOutboxStore)
  private
    FContext: TMessengerDbContext;
    class function DestinationKindToDb(AKind: TMessengerDestinationKind): Integer; static;
    class function DestinationKindFromDb(AValue: Integer): TMessengerDestinationKind; static;
    class function MessageKindFromDb(AValue: Integer): TMessengerMessageKind; static;
    class function UnixMsToUtcDateTime(AValue: Int64): TDateTime; static;
    class function UtcDateTimeToUnixMs(const AValue: TDateTime): Int64; static;
    class function OutboxIdFor(const AMessageId: string): string; static;
    function TryReadExisting(const ACommand: TMessengerAcceptMessageCommand;
      out AAccepted: TMessengerAcceptedMessage; out ASameLogicalCommand: Boolean): Boolean;
    function AllocateConversationSequence(const AConversationId: string;
      ACreatedAt: TDateTime): Int64;
    procedure InsertMessageAndOutbox(const AAccepted: TMessengerAcceptedMessage);
    class function ReadAcceptedFromReader(const AReader: IDbReader;
      AStartIndex: Integer = 0): TMessengerAcceptedMessage; static;
  public
    constructor Create(AContext: TMessengerDbContext);

    function AcceptOrGet(const ACommand: TMessengerAcceptMessageCommand;
      const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;

    function ClaimBatch(const AWorkerId: string; ANowUnixMs, ALeaseMs: Int64;
      AMaxItems: Integer): TArray<TMessengerOutboxItem>;
    procedure MarkPublished(const AOutboxId, AWorkerId: string);
    procedure ReleaseForRetry(const AOutboxId, AWorkerId: string;
      AAvailableAtUnixMs: Int64; const AError: string);
  end;

implementation

uses
  System.Rtti,
  System.DateUtils,
  Dext.Messenger.Models;

const
  SQL_EXISTING =
    'select message_id, client_message_id, conversation_id, sender_user_id, ' +
    'destination_kind, destination_id, sequence_no, partition_no, message_kind, ' +
    'payload_json::text, created_at, ' +
    '(payload_json = cast(:payload_check as jsonb)) as payload_same ' +
    'from messenger_messages ' +
    'where sender_user_id = :sender and client_message_id = :client_id';

  SQL_ALLOCATE_SEQUENCE =
    'update messenger_conversations ' +
    'set last_sequence = last_sequence + 1, last_message_at = :created_at ' +
    'where id = :conversation_id returning last_sequence';

  SQL_INSERT_MESSAGE =
    'insert into messenger_messages (' +
    'message_id, client_message_id, conversation_id, sender_user_id, ' +
    'destination_kind, destination_id, sequence_no, partition_no, message_kind, ' +
    'payload_json, created_at) values (' +
    ':message_id, :client_message_id, :conversation_id, :sender_user_id, ' +
    ':destination_kind, :destination_id, :sequence_no, :partition_no, :message_kind, ' +
    'cast(:payload_json as jsonb), :created_at)';

  SQL_INSERT_OUTBOX =
    'insert into messenger_outbox (' +
    'outbox_id, event_type, message_id, partition_no, sequence_no) values (' +
    ':outbox_id, ''message.accepted.v1'', :message_id, :partition_no, :sequence_no)';

  SQL_CLAIM =
    'select o.outbox_id, o.attempt_count, o.available_at, ' +
    'm.message_id, m.client_message_id, m.conversation_id, m.sender_user_id, ' +
    'm.destination_kind, m.destination_id, m.sequence_no, m.partition_no, ' +
    'm.message_kind, m.payload_json::text, m.created_at ' +
    'from messenger_outbox o ' +
    'join messenger_messages m on m.message_id = o.message_id ' +
    'where o.status = 0 and o.available_at <= :now_at ' +
    'and (o.lease_owner is null or o.lease_until <= :now_at2) ' +
    'order by o.created_at ' +
    'for update of o skip locked limit :max_items';

  SQL_SET_LEASE =
    'update messenger_outbox set lease_owner = :worker_id, lease_until = :lease_until ' +
    'where outbox_id = :outbox_id and status = 0';

  SQL_MARK_PUBLISHED =
    'update messenger_outbox set status = 1, published_at = now(), ' +
    'lease_owner = null, lease_until = null, last_error = null ' +
    'where outbox_id = :outbox_id and status = 0 and lease_owner = :worker_id';

  SQL_RELEASE_RETRY =
    'update messenger_outbox set attempt_count = attempt_count + 1, ' +
    'available_at = :available_at, lease_owner = null, lease_until = null, ' +
    'last_error = :last_error ' +
    'where outbox_id = :outbox_id and status = 0 and lease_owner = :worker_id';

constructor TMessengerPostgreSQLStore.Create(AContext: TMessengerDbContext);
begin
  inherited Create;
  if not Assigned(AContext) then raise EArgumentNilException.Create('AContext');
  FContext := AContext;
end;

class function TMessengerPostgreSQLStore.DestinationKindToDb(
  AKind: TMessengerDestinationKind): Integer;
begin
  case AKind of
    mdkUser: Result := 1;
    mdkGroup: Result := 2;
  else
    raise EArgumentOutOfRangeException.Create('destination kind');
  end;
end;

class function TMessengerPostgreSQLStore.DestinationKindFromDb(
  AValue: Integer): TMessengerDestinationKind;
begin
  case AValue of
    1: Result := mdkUser;
    2: Result := mdkGroup;
  else
    raise EMessengerPostgreSQLError.CreateFmt('Invalid destination_kind %d', [AValue]);
  end;
end;

class function TMessengerPostgreSQLStore.MessageKindFromDb(
  AValue: Integer): TMessengerMessageKind;
begin
  if (AValue < Ord(Low(TMessengerMessageKind))) or
     (AValue > Ord(High(TMessengerMessageKind))) then
    raise EMessengerPostgreSQLError.CreateFmt('Invalid message_kind %d', [AValue]);
  Result := TMessengerMessageKind(AValue);
end;

class function TMessengerPostgreSQLStore.UnixMsToUtcDateTime(
  AValue: Int64): TDateTime;
begin
  Result := UnixToDateTime(AValue div 1000, True) +
    (AValue mod 1000) / MSecsPerDay;
end;

class function TMessengerPostgreSQLStore.UtcDateTimeToUnixMs(
  const AValue: TDateTime): Int64;
begin
  Result := DateTimeToUnix(AValue, True) * Int64(1000) + MilliSecondOf(AValue);
end;

class function TMessengerPostgreSQLStore.OutboxIdFor(
  const AMessageId: string): string;
begin
  Result := 'message.accepted:' + AMessageId;
end;

class function TMessengerPostgreSQLStore.ReadAcceptedFromReader(
  const AReader: IDbReader; AStartIndex: Integer): TMessengerAcceptedMessage;
var
  Message: TMessengerMessage;
  DestinationKind: TMessengerDestinationKind;
  CreatedAt: TDateTime;
begin
  CreatedAt := AReader.GetDateTime(AStartIndex + 10);
  Message := TMessengerMessage.CreateV1(
    AReader.GetString(AStartIndex + 0),
    AReader.GetString(AStartIndex + 1),
    AReader.GetString(AStartIndex + 2),
    AReader.GetString(AStartIndex + 3),
    MessageKindFromDb(AReader.GetInt32(AStartIndex + 8)),
    UtcDateTimeToUnixMs(CreatedAt),
    AReader.GetString(AStartIndex + 9));

  DestinationKind := DestinationKindFromDb(
    AReader.GetInt32(AStartIndex + 4));
  Result := TMessengerAcceptedMessage.Create(
    Message,
    DestinationKind,
    AReader.GetString(AStartIndex + 5),
    AReader.GetInt32(AStartIndex + 7),
    AReader.GetInt64(AStartIndex + 6));
end;

function TMessengerPostgreSQLStore.TryReadExisting(
  const ACommand: TMessengerAcceptMessageCommand;
  out AAccepted: TMessengerAcceptedMessage;
  out ASameLogicalCommand: Boolean): Boolean;
var
  Cmd: IDbCommand;
  Reader: IDbReader;
begin
  AAccepted := Default(TMessengerAcceptedMessage);
  ASameLogicalCommand := False;
  Cmd := FContext.Connection.CreateCommand(SQL_EXISTING);
  Cmd.AddParam('payload_check', TValue.From<string>(ACommand.PayloadJson));
  Cmd.AddParam('sender', TValue.From<string>(ACommand.SenderUserId));
  Cmd.AddParam('client_id', TValue.From<string>(ACommand.ClientMessageId));
  Reader := Cmd.ExecuteQuery;
  try
    Result := Reader.Next;
    if not Result then Exit;
    AAccepted := ReadAcceptedFromReader(Reader, 0);
    ASameLogicalCommand :=
      (AAccepted.Message.ConversationId = ACommand.ConversationId) and
      (AAccepted.Message.SenderUserId = ACommand.SenderUserId) and
      (AAccepted.DestinationKind = ACommand.DestinationKind) and
      (AAccepted.DestinationId = ACommand.DestinationId) and
      (AAccepted.Message.Kind = ACommand.Kind) and
      Reader.GetBoolean(11);
  finally
    Reader.Close;
  end;
end;

function TMessengerPostgreSQLStore.AllocateConversationSequence(
  const AConversationId: string; ACreatedAt: TDateTime): Int64;
var
  Cmd: IDbCommand;
  Reader: IDbReader;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_ALLOCATE_SEQUENCE);
  Cmd.AddParam('created_at', TValue.From<TDateTime>(ACreatedAt));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Reader := Cmd.ExecuteQuery;
  try
    if not Reader.Next then
      raise EMessengerPostgreSQLError.Create('Conversation not found while allocating sequence');
    Result := Reader.GetInt64(0);
  finally
    Reader.Close;
  end;
end;

procedure TMessengerPostgreSQLStore.InsertMessageAndOutbox(
  const AAccepted: TMessengerAcceptedMessage);
var
  Cmd: IDbCommand;
  CreatedAt: TDateTime;
begin
  CreatedAt := UnixMsToUtcDateTime(AAccepted.Message.CreatedAtUnixMs);

  Cmd := FContext.Connection.CreateCommand(SQL_INSERT_MESSAGE);
  Cmd.AddParam('message_id', TValue.From<string>(AAccepted.Message.MessageId));
  Cmd.AddParam('client_message_id', TValue.From<string>(AAccepted.Message.ClientMessageId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AAccepted.Message.ConversationId));
  Cmd.AddParam('sender_user_id', TValue.From<string>(AAccepted.Message.SenderUserId));
  Cmd.AddParam('destination_kind', TValue.From<Integer>(DestinationKindToDb(AAccepted.DestinationKind)));
  Cmd.AddParam('destination_id', TValue.From<string>(AAccepted.DestinationId));
  Cmd.AddParam('sequence_no', TValue.From<Int64>(AAccepted.Sequence));
  Cmd.AddParam('partition_no', TValue.From<Integer>(AAccepted.Partition));
  Cmd.AddParam('message_kind', TValue.From<Integer>(Ord(AAccepted.Message.Kind)));
  Cmd.AddParam('payload_json', TValue.From<string>(AAccepted.Message.PayloadJson));
  Cmd.AddParam('created_at', TValue.From<TDateTime>(CreatedAt));
  if Cmd.ExecuteNonQuery <> 1 then
    raise EMessengerPostgreSQLError.Create('Message insert did not affect exactly one row');

  Cmd := FContext.Connection.CreateCommand(SQL_INSERT_OUTBOX);
  Cmd.AddParam('outbox_id', TValue.From<string>(OutboxIdFor(AAccepted.Message.MessageId)));
  Cmd.AddParam('message_id', TValue.From<string>(AAccepted.Message.MessageId));
  Cmd.AddParam('partition_no', TValue.From<Integer>(AAccepted.Partition));
  Cmd.AddParam('sequence_no', TValue.From<Int64>(AAccepted.Sequence));
  if Cmd.ExecuteNonQuery <> 1 then
    raise EMessengerPostgreSQLError.Create('Outbox insert did not affect exactly one row');
end;

function TMessengerPostgreSQLStore.AcceptOrGet(
  const ACommand: TMessengerAcceptMessageCommand;
  const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;
var
  Existing: TMessengerAcceptedMessage;
  SameLogical: Boolean;
  Canonical: TMessengerAcceptedMessage;
  Sequence: Int64;
  CreatedAt: TDateTime;
begin
  if TryReadExisting(ACommand, Existing, SameLogical) then
  begin
    if not SameLogical then
      raise EMessengerIdempotencyConflict.Create(
        'client_message_id is already bound to a different command');
    Result.Accepted := Existing;
    Result.WasDuplicate := True;
    Exit;
  end;

  try
    FContext.BeginTransaction;
    try
      { Re-check inside the transaction before taking the conversation row lock. }
      if TryReadExisting(ACommand, Existing, SameLogical) then
      begin
        if not SameLogical then
          raise EMessengerIdempotencyConflict.Create(
            'client_message_id is already bound to a different command');
        FContext.Commit;
        Result.Accepted := Existing;
        Result.WasDuplicate := True;
        Exit;
      end;

      CreatedAt := UnixMsToUtcDateTime(AProposal.Message.CreatedAtUnixMs);
      Sequence := AllocateConversationSequence(ACommand.ConversationId, CreatedAt);
      Canonical := AProposal;
      Canonical.Sequence := Sequence;
      InsertMessageAndOutbox(Canonical);
      FContext.Commit;

      Result.Accepted := Canonical;
      Result.WasDuplicate := False;
      Exit;
    except
      FContext.Rollback;
      raise;
    end;
  except
    { The unique(sender_user_id, client_message_id) constraint is the final
      race arbiter. Any insert failure is followed by a canonical re-read; if
      another request won the race, return it. Otherwise preserve the error. }
    on E: Exception do
    begin
      if TryReadExisting(ACommand, Existing, SameLogical) then
      begin
        if not SameLogical then
          raise EMessengerIdempotencyConflict.Create(
            'client_message_id is already bound to a different command');
        Result.Accepted := Existing;
        Result.WasDuplicate := True;
        Exit;
      end;
      raise;
    end;
  end;
end;

function TMessengerPostgreSQLStore.ClaimBatch(const AWorkerId: string;
  ANowUnixMs, ALeaseMs: Int64; AMaxItems: Integer): TArray<TMessengerOutboxItem>;
var
  SelectCmd, LeaseCmd: IDbCommand;
  Reader: IDbReader;
  NowAt, LeaseUntil: TDateTime;
  Item: TMessengerOutboxItem;
  Accepted: TMessengerAcceptedMessage;
  Items: TArray<TMessengerOutboxItem>;
  Count: Integer;
begin
  if AWorkerId = '' then raise EArgumentException.Create('worker_id must not be empty');
  if ANowUnixMs <= 0 then raise EArgumentOutOfRangeException.Create('ANowUnixMs');
  if ALeaseMs <= 0 then raise EArgumentOutOfRangeException.Create('ALeaseMs');
  if AMaxItems <= 0 then raise EArgumentOutOfRangeException.Create('AMaxItems');

  NowAt := UnixMsToUtcDateTime(ANowUnixMs);
  LeaseUntil := UnixMsToUtcDateTime(ANowUnixMs + ALeaseMs);
  SetLength(Items, AMaxItems);
  Count := 0;

  FContext.BeginTransaction;
  try
    SelectCmd := FContext.Connection.CreateCommand(SQL_CLAIM);
    SelectCmd.AddParam('now_at', TValue.From<TDateTime>(NowAt));
    SelectCmd.AddParam('now_at2', TValue.From<TDateTime>(NowAt));
    SelectCmd.AddParam('max_items', TValue.From<Integer>(AMaxItems));
    Reader := SelectCmd.ExecuteQuery;
    try
      while Reader.Next do
      begin
        Item := Default(TMessengerOutboxItem);
        Item.OutboxId := Reader.GetString(0);
        Item.AttemptCount := Reader.GetInt32(1);
        Item.AvailableAtUnixMs := UtcDateTimeToUnixMs(Reader.GetDateTime(2));
        Accepted := ReadAcceptedFromReader(Reader, 3);
        Item.Accepted := Accepted;
        Item.LeaseOwner := AWorkerId;
        Item.LeaseUntilUnixMs := ANowUnixMs + ALeaseMs;

        LeaseCmd := FContext.Connection.CreateCommand(SQL_SET_LEASE);
        LeaseCmd.AddParam('worker_id', TValue.From<string>(AWorkerId));
        LeaseCmd.AddParam('lease_until', TValue.From<TDateTime>(LeaseUntil));
        LeaseCmd.AddParam('outbox_id', TValue.From<string>(Item.OutboxId));
        if LeaseCmd.ExecuteNonQuery <> 1 then
          raise EMessengerPostgreSQLError.Create('Failed to claim outbox row');

        Items[Count] := Item;
        Inc(Count);
      end;
    finally
      Reader.Close;
    end;
    FContext.Commit;
  except
    FContext.Rollback;
    raise;
  end;

  SetLength(Items, Count);
  Result := Items;
end;

procedure TMessengerPostgreSQLStore.MarkPublished(const AOutboxId,
  AWorkerId: string);
var
  Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_MARK_PUBLISHED);
  Cmd.AddParam('outbox_id', TValue.From<string>(AOutboxId));
  Cmd.AddParam('worker_id', TValue.From<string>(AWorkerId));
  if Cmd.ExecuteNonQuery <> 1 then
    raise EMessengerPostgreSQLError.Create(
      'Outbox publish acknowledgement lost its lease or row');
end;

procedure TMessengerPostgreSQLStore.ReleaseForRetry(const AOutboxId,
  AWorkerId: string; AAvailableAtUnixMs: Int64; const AError: string);
var
  Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_RELEASE_RETRY);
  Cmd.AddParam('available_at', TValue.From<TDateTime>(
    UnixMsToUtcDateTime(AAvailableAtUnixMs)));
  Cmd.AddParam('last_error', TValue.From<string>(Copy(AError, 1, 2000)));
  Cmd.AddParam('outbox_id', TValue.From<string>(AOutboxId));
  Cmd.AddParam('worker_id', TValue.From<string>(AWorkerId));
  if Cmd.ExecuteNonQuery <> 1 then
    raise EMessengerPostgreSQLError.Create(
      'Outbox retry release lost its lease or row');
end;

end.
