unit Dext.Messenger.Persistence.PostgreSQL.Reads;

interface

uses
  System.SysUtils,
  System.Classes,
  Dext.Entity.Drivers.Interfaces,
  Dext.Messenger.Sync,
  Dext.Messenger.Conversations,
  Dext.Messenger.Notifications,
  Dext.Messenger.Persistence.DbContext;

type
  TMessengerPostgreSQLReadStore = class(TInterfacedObject,
    IMessengerHistoryStore, IMessengerCursorStore,
    IMessengerConversationStore, IMessengerPushTargetStore)
  private
    FContext: TMessengerDbContext;
    class function ReadStoredMessage(const R: IDbReader): TMessengerStoredMessage; static;
  public
    constructor Create(AContext: TMessengerDbContext);

    function ReadAfter(const AUserId, AConversationId: string;
      AAfterSequence: Int64; ALimit: Integer): TArray<TMessengerStoredMessage>;
    function HasMessagesAfter(const AUserId, AConversationId: string;
      AAfterSequence: Int64): Boolean;

    function GetReadCursor(const AUserId, AConversationId: string): Int64;
    procedure AdvanceReadCursor(const AUserId, AConversationId: string;
      ASequence: Int64);
    function GetDeliveredCursor(const AUserId, AConversationId: string): Int64;
    procedure AdvanceDeliveredCursor(const AUserId, AConversationId: string;
      ASequence: Int64);

    function TryGetConversation(const AConversationId: string;
      out AInfo: TMessengerConversationInfo): Boolean;
    function IsActiveMember(const AConversationId, AUserId: string): Boolean;
    function MemberRole(const AConversationId, AUserId: string): TMessengerMemberRole;
    procedure AddMember(const AConversationId, AActorUserId, AUserId: string;
      ARole: TMessengerMemberRole);
    procedure RemoveMember(const AConversationId, AActorUserId,
      AUserId: string);

    function ActiveTargetsForUser(const AUserId: string): TArray<TMessengerPushTarget>;
  end;

implementation

uses
  System.Rtti,
  System.DateUtils,
  System.Generics.Collections,
  Dext.Messenger.Models;

const
  SQL_HISTORY =
    'select m.sequence_no, m.message_id, m.client_message_id, m.conversation_id, ' +
    'm.sender_user_id, m.message_kind, m.payload_json::text, m.created_at ' +
    'from messenger_messages m ' +
    'join messenger_members mb on mb.conversation_id=m.conversation_id ' +
    ' and mb.user_id=:user_id and mb.left_at is null ' +
    'where m.conversation_id=:conversation_id and m.sequence_no>:after_seq ' +
    ' and m.deleted_at is null order by m.sequence_no asc limit :limit_n';

  SQL_HAS_AFTER =
    'select exists(select 1 from messenger_messages m ' +
    'join messenger_members mb on mb.conversation_id=m.conversation_id ' +
    ' and mb.user_id=:user_id and mb.left_at is null ' +
    'where m.conversation_id=:conversation_id and m.sequence_no>:after_seq ' +
    'and m.deleted_at is null)';

  SQL_GET_CURSOR =
    'select delivered_sequence, read_sequence from messenger_user_cursors ' +
    'where user_id=:user_id and conversation_id=:conversation_id';

  SQL_ADVANCE_DELIVERED =
    'insert into messenger_user_cursors(user_id,conversation_id,delivered_sequence,read_sequence) ' +
    'values(:user_id,:conversation_id,:seq,0) ' +
    'on conflict(user_id,conversation_id) do update set ' +
    'delivered_sequence=greatest(messenger_user_cursors.delivered_sequence,excluded.delivered_sequence), ' +
    'updated_at=now()';

  SQL_ADVANCE_READ =
    'insert into messenger_user_cursors(user_id,conversation_id,delivered_sequence,read_sequence) ' +
    'values(:user_id,:conversation_id,:seq,:seq2) ' +
    'on conflict(user_id,conversation_id) do update set ' +
    'delivered_sequence=greatest(messenger_user_cursors.delivered_sequence,excluded.delivered_sequence), ' +
    'read_sequence=greatest(messenger_user_cursors.read_sequence,excluded.read_sequence), ' +
    'updated_at=now()';

  SQL_CONVERSATION =
    'select id,kind,coalesce(group_id,'''') from messenger_conversations where id=:id';
  SQL_MEMBER_ACTIVE =
    'select exists(select 1 from messenger_members where conversation_id=:conversation_id ' +
    'and user_id=:user_id and left_at is null)';
  SQL_MEMBER_ROLE =
    'select role from messenger_members where conversation_id=:conversation_id ' +
    'and user_id=:user_id and left_at is null';
  SQL_MEMBER_UPSERT =
    'insert into messenger_members(conversation_id,user_id,role,joined_at,left_at) ' +
    'values(:conversation_id,:user_id,:role,now(),null) ' +
    'on conflict(conversation_id,user_id) do update set role=excluded.role, ' +
    'joined_at=case when messenger_members.left_at is null then messenger_members.joined_at else now() end, ' +
    'left_at=null';
  SQL_MEMBER_REMOVE =
    'update messenger_members set left_at=now() where conversation_id=:conversation_id ' +
    'and user_id=:user_id and left_at is null';

  SQL_PUSH_TARGETS =
    'select user_id,device_id,coalesce(push_provider,''''),coalesce(push_token,'''') ' +
    'from messenger_devices where user_id=:user_id and disabled_at is null ' +
    'and push_provider is not null and push_token is not null';

constructor TMessengerPostgreSQLReadStore.Create(AContext: TMessengerDbContext);
begin
  inherited Create;
  if not Assigned(AContext) then raise EArgumentNilException.Create('AContext');
  FContext := AContext;
end;

class function TMessengerPostgreSQLReadStore.ReadStoredMessage(
  const R: IDbReader): TMessengerStoredMessage;
var
  KindValue: Integer;
  Kind: TMessengerMessageKind;
  CreatedAtMs: Int64;
  CreatedAt: TDateTime;
  M: TMessengerMessage;
begin
  KindValue := R.GetInt32(5);
  if (KindValue < Ord(Low(TMessengerMessageKind))) or
     (KindValue > Ord(High(TMessengerMessageKind))) then
    raise EInvalidOperation.Create('Invalid stored message kind');
  Kind := TMessengerMessageKind(KindValue);
  CreatedAt := R.GetDateTime(7);
  CreatedAtMs := DateTimeToUnix(CreatedAt, True) * Int64(1000) + MilliSecondOf(CreatedAt);
  M := TMessengerMessage.CreateV1(
    R.GetString(1), R.GetString(2), R.GetString(3), R.GetString(4),
    Kind, CreatedAtMs, R.GetString(6));
  Result := TMessengerStoredMessage.Create(R.GetInt64(0), M);
end;

function TMessengerPostgreSQLReadStore.ReadAfter(const AUserId,
  AConversationId: string; AAfterSequence: Int64;
  ALimit: Integer): TArray<TMessengerStoredMessage>;
var
  Cmd: IDbCommand;
  R: IDbReader;
  L: TList<TMessengerStoredMessage>;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_HISTORY);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('after_seq', TValue.From<Int64>(AAfterSequence));
  Cmd.AddParam('limit_n', TValue.From<Integer>(ALimit));
  R := Cmd.ExecuteQuery;
  L := TList<TMessengerStoredMessage>.Create;
  try
    while R.Next do L.Add(ReadStoredMessage(R));
    Result := L.ToArray;
  finally
    R.Close;
    L.Free;
  end;
end;

function TMessengerPostgreSQLReadStore.HasMessagesAfter(const AUserId,
  AConversationId: string; AAfterSequence: Int64): Boolean;
var Cmd: IDbCommand; R: IDbReader;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_HAS_AFTER);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('after_seq', TValue.From<Int64>(AAfterSequence));
  R := Cmd.ExecuteQuery;
  try
    Result := R.Next and R.GetBoolean(0);
  finally R.Close; end;
end;

function TMessengerPostgreSQLReadStore.GetReadCursor(const AUserId,
  AConversationId: string): Int64;
var Cmd: IDbCommand; R: IDbReader;
begin
  Result := 0;
  Cmd := FContext.Connection.CreateCommand(SQL_GET_CURSOR);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  R := Cmd.ExecuteQuery;
  try if R.Next then Result := R.GetInt64(1); finally R.Close; end;
end;

function TMessengerPostgreSQLReadStore.GetDeliveredCursor(const AUserId,
  AConversationId: string): Int64;
var Cmd: IDbCommand; R: IDbReader;
begin
  Result := 0;
  Cmd := FContext.Connection.CreateCommand(SQL_GET_CURSOR);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  R := Cmd.ExecuteQuery;
  try if R.Next then Result := R.GetInt64(0); finally R.Close; end;
end;

procedure TMessengerPostgreSQLReadStore.AdvanceDeliveredCursor(const AUserId,
  AConversationId: string; ASequence: Int64);
var Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_ADVANCE_DELIVERED);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('seq', TValue.From<Int64>(ASequence));
  Cmd.ExecuteNonQuery;
end;

procedure TMessengerPostgreSQLReadStore.AdvanceReadCursor(const AUserId,
  AConversationId: string; ASequence: Int64);
var Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_ADVANCE_READ);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('seq', TValue.From<Int64>(ASequence));
  Cmd.AddParam('seq2', TValue.From<Int64>(ASequence));
  Cmd.ExecuteNonQuery;
end;

function TMessengerPostgreSQLReadStore.TryGetConversation(
  const AConversationId: string; out AInfo: TMessengerConversationInfo): Boolean;
var Cmd: IDbCommand; R: IDbReader; K: Integer;
begin
  AInfo := Default(TMessengerConversationInfo);
  Cmd := FContext.Connection.CreateCommand(SQL_CONVERSATION);
  Cmd.AddParam('id', TValue.From<string>(AConversationId));
  R := Cmd.ExecuteQuery;
  try
    Result := R.Next;
    if not Result then Exit;
    AInfo.ConversationId := R.GetString(0);
    K := R.GetInt32(1);
    case K of
      1: AInfo.Kind := mckDirect;
      2: AInfo.Kind := mckGroup;
    else raise EInvalidOperation.Create('Invalid conversation kind'); end;
    AInfo.GroupId := R.GetString(2);
  finally R.Close; end;
end;

function TMessengerPostgreSQLReadStore.IsActiveMember(const AConversationId,
  AUserId: string): Boolean;
var Cmd: IDbCommand; R: IDbReader;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_MEMBER_ACTIVE);
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  R := Cmd.ExecuteQuery;
  try Result := R.Next and R.GetBoolean(0); finally R.Close; end;
end;

function TMessengerPostgreSQLReadStore.MemberRole(const AConversationId,
  AUserId: string): TMessengerMemberRole;
var Cmd: IDbCommand; R: IDbReader; V: Integer;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_MEMBER_ROLE);
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  R := Cmd.ExecuteQuery;
  try
    if not R.Next then raise EInvalidOperation.Create('Active membership not found');
    V := R.GetInt32(0);
    if (V < 1) or (V > 4) then raise EInvalidOperation.Create('Invalid member role');
    Result := TMessengerMemberRole(V - 1);
  finally R.Close; end;
end;

procedure TMessengerPostgreSQLReadStore.AddMember(const AConversationId,
  AActorUserId, AUserId: string; ARole: TMessengerMemberRole);
var Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_MEMBER_UPSERT);
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('role', TValue.From<Integer>(Ord(ARole) + 1));
  Cmd.ExecuteNonQuery;
end;

procedure TMessengerPostgreSQLReadStore.RemoveMember(const AConversationId,
  AActorUserId, AUserId: string);
var Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_MEMBER_REMOVE);
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.ExecuteNonQuery;
end;

function TMessengerPostgreSQLReadStore.ActiveTargetsForUser(
  const AUserId: string): TArray<TMessengerPushTarget>;
var Cmd: IDbCommand; R: IDbReader; L: TList<TMessengerPushTarget>; T: TMessengerPushTarget;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_PUSH_TARGETS);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  R := Cmd.ExecuteQuery;
  L := TList<TMessengerPushTarget>.Create;
  try
    while R.Next do
    begin
      T := Default(TMessengerPushTarget);
      T.UserId := R.GetString(0);
      T.DeviceId := R.GetString(1);
      T.Provider := R.GetString(2);
      T.Token := R.GetString(3);
      L.Add(T);
    end;
    Result := L.ToArray;
  finally
    R.Close;
    L.Free;
  end;
end;

end.
