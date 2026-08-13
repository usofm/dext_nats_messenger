unit Dext.Messenger.Persistence.PostgreSQL.Conversations;

interface

uses
  System.SysUtils,
  Dext.Entity.Drivers.Interfaces,
  Dext.Messenger.Conversations,
  Dext.Messenger.ConversationLifecycle,
  Dext.Messenger.Persistence.DbContext;

type
  TMessengerPostgreSQLConversationLifecycleStore = class(TInterfacedObject,
    IMessengerConversationLifecycleStore)
  private
    FContext: TMessengerDbContext;
    class procedure CanonicalPair(const AUserA, AUserB: string;
      out ALow, AHigh: string); static;
    function TryReadDirectPair(const ALow, AHigh: string;
      out AInfo: TMessengerConversationInfo): Boolean;
    procedure InsertDirectConversation(const AConversationId,
      ACreatedBy: string);
    procedure InsertGroupConversation(const AConversationId, AGroupId,
      ATitle, ACreatedBy: string);
    procedure InsertMember(const AConversationId, AUserId: string;
      ARoleDb: Integer);
  public
    constructor Create(AContext: TMessengerDbContext);
    function CreateOrGetDirect(const AConversationId, AUserA,
      AUserB: string): TMessengerCreateConversationResult;
    function CreateGroup(const AConversationId, AGroupId, AOwnerUserId,
      ATitle: string): TMessengerConversationInfo;
  end;

implementation

uses
  System.Rtti;

const
  SQL_DIRECT_PAIR =
    'select conversation_id from messenger_direct_pairs ' +
    'where user_low_id=:user_low and user_high_id=:user_high';

  SQL_INSERT_DIRECT_CONVERSATION =
    'insert into messenger_conversations(id,kind,group_id,title,created_by,created_at,last_sequence) ' +
    'values(:id,1,null,null,:created_by,now(),0)';

  SQL_INSERT_GROUP_CONVERSATION =
    'insert into messenger_conversations(id,kind,group_id,title,created_by,created_at,last_sequence) ' +
    'values(:id,2,:group_id,:title,:created_by,now(),0)';

  SQL_INSERT_DIRECT_PAIR =
    'insert into messenger_direct_pairs(user_low_id,user_high_id,conversation_id) ' +
    'values(:user_low,:user_high,:conversation_id)';

  SQL_INSERT_MEMBER =
    'insert into messenger_members(conversation_id,user_id,role,joined_at,left_at) ' +
    'values(:conversation_id,:user_id,:role,now(),null)';

constructor TMessengerPostgreSQLConversationLifecycleStore.Create(
  AContext: TMessengerDbContext);
begin
  inherited Create;
  if not Assigned(AContext) then raise EArgumentNilException.Create('AContext');
  FContext := AContext;
end;

class procedure TMessengerPostgreSQLConversationLifecycleStore.CanonicalPair(
  const AUserA, AUserB: string; out ALow, AHigh: string);
begin
  if CompareStr(AUserA, AUserB) < 0 then
  begin
    ALow := AUserA;
    AHigh := AUserB;
  end
  else
  begin
    ALow := AUserB;
    AHigh := AUserA;
  end;
end;

function TMessengerPostgreSQLConversationLifecycleStore.TryReadDirectPair(
  const ALow, AHigh: string; out AInfo: TMessengerConversationInfo): Boolean;
var
  Cmd: IDbCommand;
  R: IDbReader;
begin
  AInfo := Default(TMessengerConversationInfo);
  Cmd := FContext.Connection.CreateCommand(SQL_DIRECT_PAIR);
  Cmd.AddParam('user_low', TValue.From<string>(ALow));
  Cmd.AddParam('user_high', TValue.From<string>(AHigh));
  R := Cmd.ExecuteQuery;
  try
    Result := R.Next;
    if Result then
    begin
      AInfo.ConversationId := R.GetString(0);
      AInfo.Kind := mckDirect;
      AInfo.GroupId := '';
    end;
  finally
    R.Close;
  end;
end;

procedure TMessengerPostgreSQLConversationLifecycleStore.InsertDirectConversation(
  const AConversationId, ACreatedBy: string);
var
  Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_INSERT_DIRECT_CONVERSATION);
  Cmd.AddParam('id', TValue.From<string>(AConversationId));
  Cmd.AddParam('created_by', TValue.From<string>(ACreatedBy));
  Cmd.ExecuteNonQuery;
end;

procedure TMessengerPostgreSQLConversationLifecycleStore.InsertGroupConversation(
  const AConversationId, AGroupId, ATitle, ACreatedBy: string);
var
  Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_INSERT_GROUP_CONVERSATION);
  Cmd.AddParam('id', TValue.From<string>(AConversationId));
  Cmd.AddParam('group_id', TValue.From<string>(AGroupId));
  Cmd.AddParam('title', TValue.From<string>(ATitle));
  Cmd.AddParam('created_by', TValue.From<string>(ACreatedBy));
  Cmd.ExecuteNonQuery;
end;

procedure TMessengerPostgreSQLConversationLifecycleStore.InsertMember(
  const AConversationId, AUserId: string; ARoleDb: Integer);
var
  Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_INSERT_MEMBER);
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('role', TValue.From<Integer>(ARoleDb));
  Cmd.ExecuteNonQuery;
end;

function TMessengerPostgreSQLConversationLifecycleStore.CreateOrGetDirect(
  const AConversationId, AUserA, AUserB: string): TMessengerCreateConversationResult;
var
  LowUser, HighUser: string;
  Existing: TMessengerConversationInfo;
  Cmd: IDbCommand;
begin
  if (AConversationId = '') or (AUserA = '') or (AUserB = '') then
    raise EArgumentException.Create('conversation and user ids are required');
  CanonicalPair(AUserA, AUserB, LowUser, HighUser);

  if TryReadDirectPair(LowUser, HighUser, Existing) then
  begin
    Result := Default(TMessengerCreateConversationResult);
    Result.Conversation := Existing;
    Result.WasExisting := True;
    Exit;
  end;

  FContext.BeginTransaction;
  try
    InsertDirectConversation(AConversationId, AUserA);

    Cmd := FContext.Connection.CreateCommand(SQL_INSERT_DIRECT_PAIR);
    Cmd.AddParam('user_low', TValue.From<string>(LowUser));
    Cmd.AddParam('user_high', TValue.From<string>(HighUser));
    Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
    Cmd.ExecuteNonQuery;

    InsertMember(AConversationId, AUserA, 1);
    InsertMember(AConversationId, AUserB, 1);
    FContext.Commit;

    Result := Default(TMessengerCreateConversationResult);
    Result.Conversation.ConversationId := AConversationId;
    Result.Conversation.Kind := mckDirect;
    Result.Conversation.GroupId := '';
    Result.WasExisting := False;
  except
    on E: Exception do
    begin
      FContext.Rollback;
      { A concurrent creator may have won the unique direct-pair race. Re-read
        the canonical pair; only rethrow when the failure was unrelated. }
      if TryReadDirectPair(LowUser, HighUser, Existing) then
      begin
        Result := Default(TMessengerCreateConversationResult);
        Result.Conversation := Existing;
        Result.WasExisting := True;
        Exit;
      end;
      raise;
    end;
  end;
end;

function TMessengerPostgreSQLConversationLifecycleStore.CreateGroup(
  const AConversationId, AGroupId, AOwnerUserId,
  ATitle: string): TMessengerConversationInfo;
begin
  if (AConversationId = '') or (AGroupId = '') or (AOwnerUserId = '') then
    raise EArgumentException.Create('conversation, group and owner ids are required');

  FContext.BeginTransaction;
  try
    InsertGroupConversation(AConversationId, AGroupId, ATitle, AOwnerUserId);
    { DB role values are 1=member, 2=moderator, 3=admin, 4=owner. }
    InsertMember(AConversationId, AOwnerUserId, 4);
    FContext.Commit;
  except
    FContext.Rollback;
    raise;
  end;

  Result := Default(TMessengerConversationInfo);
  Result.ConversationId := AConversationId;
  Result.Kind := mckGroup;
  Result.GroupId := AGroupId;
end;

end.
