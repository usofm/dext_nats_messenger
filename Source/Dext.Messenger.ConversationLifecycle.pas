unit Dext.Messenger.ConversationLifecycle;

interface

uses
  System.SysUtils,
  System.Classes,
  Dext.Messenger.Conversations;

type
  TMessengerCreateConversationResult = record
  public
    Conversation: TMessengerConversationInfo;
    WasExisting: Boolean;
  end;

  IMessengerConversationIdGenerator = interface
    ['{2F29C28D-2E2C-4C69-B862-7491624EAF40}']
    function NewConversationId: string;
    function NewGroupId: string;
  end;

  IMessengerConversationLifecycleStore = interface
    ['{31EE1D9E-9249-4EC6-B916-256CFBDF45F7}']
    function CreateOrGetDirect(const AConversationId, AUserA,
      AUserB: string): TMessengerCreateConversationResult;
    function CreateGroup(const AConversationId, AGroupId, AOwnerUserId,
      ATitle: string): TMessengerConversationInfo;
  end;

  TMessengerGuidConversationIdGenerator = class(TInterfacedObject,
    IMessengerConversationIdGenerator)
  private
    class function NewGuidText: string; static;
  public
    function NewConversationId: string;
    function NewGroupId: string;
  end;

  TMessengerConversationLifecycleService = class
  private
    FStore: IMessengerConversationLifecycleStore;
    FIds: IMessengerConversationIdGenerator;
    class procedure ValidateUser(const AName, AValue: string); static;
  public
    constructor Create(const AStore: IMessengerConversationLifecycleStore;
      const AIds: IMessengerConversationIdGenerator);
    function CreateOrGetDirect(const AActorUserId,
      AOtherUserId: string): TMessengerCreateConversationResult;
    function CreateGroup(const AOwnerUserId,
      ATitle: string): TMessengerConversationInfo;
  end;

implementation

class function TMessengerGuidConversationIdGenerator.NewGuidText: string;
var
  G: TGUID;
begin
  if CreateGUID(G) <> 0 then
    raise EInvalidOperation.Create('Unable to generate conversation identifier');
  Result := LowerCase(GUIDToString(G));
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

function TMessengerGuidConversationIdGenerator.NewConversationId: string;
begin
  Result := NewGuidText;
end;

function TMessengerGuidConversationIdGenerator.NewGroupId: string;
begin
  Result := 'g_' + NewGuidText;
end;

constructor TMessengerConversationLifecycleService.Create(
  const AStore: IMessengerConversationLifecycleStore;
  const AIds: IMessengerConversationIdGenerator);
begin
  inherited Create;
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  if AIds = nil then raise EArgumentNilException.Create('AIds');
  FStore := AStore;
  FIds := AIds;
end;

class procedure TMessengerConversationLifecycleService.ValidateUser(
  const AName, AValue: string);
begin
  if Trim(AValue) = '' then
    raise EArgumentException.CreateFmt('%s must not be empty', [AName]);
end;

function TMessengerConversationLifecycleService.CreateOrGetDirect(
  const AActorUserId, AOtherUserId: string): TMessengerCreateConversationResult;
begin
  ValidateUser('actor_user_id', AActorUserId);
  ValidateUser('other_user_id', AOtherUserId);
  if SameText(AActorUserId, AOtherUserId) then
    raise EArgumentException.Create('Direct conversation requires two different users');
  Result := FStore.CreateOrGetDirect(FIds.NewConversationId,
    AActorUserId, AOtherUserId);
end;

function TMessengerConversationLifecycleService.CreateGroup(
  const AOwnerUserId, ATitle: string): TMessengerConversationInfo;
begin
  ValidateUser('owner_user_id', AOwnerUserId);
  if Length(Trim(ATitle)) > 200 then
    raise EArgumentOutOfRangeException.Create('group title exceeds 200 characters');
  Result := FStore.CreateGroup(FIds.NewConversationId, FIds.NewGroupId,
    AOwnerUserId, Trim(ATitle));
end;

end.
