unit Dext.Messenger.Conversations;

interface

uses
  System.SysUtils,
  Dext.Messenger.Commands,
  Dext.Messenger.Acceptance;

type
  TMessengerConversationKind = (mckDirect, mckGroup);
  TMessengerMemberRole = (mmrMember, mmrModerator, mmrAdmin, mmrOwner);

  TMessengerConversationInfo = record
  public
    ConversationId: string;
    Kind: TMessengerConversationKind;
    GroupId: string;
  end;

  IMessengerConversationStore = interface
    ['{F12C2B08-39B3-49E0-98B2-B9F9100827F4}']
    function TryGetConversation(const AConversationId: string;
      out AInfo: TMessengerConversationInfo): Boolean;
    function IsActiveMember(const AConversationId, AUserId: string): Boolean;
    function MemberRole(const AConversationId, AUserId: string): TMessengerMemberRole;
    procedure AddMember(const AConversationId, AActorUserId, AUserId: string;
      ARole: TMessengerMemberRole);
    procedure RemoveMember(const AConversationId, AActorUserId,
      AUserId: string);
  end;

  TMessengerConversationAuthorizer = class(TInterfacedObject,
    IMessengerConversationAuthorizer)
  private
    FStore: IMessengerConversationStore;
  public
    constructor Create(const AStore: IMessengerConversationStore);
    function CanSend(const ASenderUserId, AConversationId: string;
      ADestinationKind: TMessengerDestinationKind;
      const ADestinationId: string): Boolean;
  end;

  TMessengerGroupService = class
  private
    FStore: IMessengerConversationStore;
    class function CanManageMembers(ARole: TMessengerMemberRole): Boolean; static;
  public
    constructor Create(const AStore: IMessengerConversationStore);
    procedure AddMember(const AConversationId, AActorUserId, AUserId: string;
      ARole: TMessengerMemberRole = mmrMember);
    procedure RemoveMember(const AConversationId, AActorUserId,
      AUserId: string);
  end;

implementation

constructor TMessengerConversationAuthorizer.Create(
  const AStore: IMessengerConversationStore);
begin
  inherited Create;
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  FStore := AStore;
end;

function TMessengerConversationAuthorizer.CanSend(const ASenderUserId,
  AConversationId: string; ADestinationKind: TMessengerDestinationKind;
  const ADestinationId: string): Boolean;
var
  Info: TMessengerConversationInfo;
begin
  Result := False;
  if (ASenderUserId = '') or (AConversationId = '') or
     (ADestinationId = '') then Exit;
  if not FStore.TryGetConversation(AConversationId, Info) then Exit;
  if not FStore.IsActiveMember(AConversationId, ASenderUserId) then Exit;

  case Info.Kind of
    mckDirect:
      begin
        if ADestinationKind <> mdkUser then Exit;
        { Both sender and destination must be active members of this exact
          direct conversation; clients cannot route through another conv id. }
        Result := FStore.IsActiveMember(AConversationId, ADestinationId) and
          (not SameText(ASenderUserId, ADestinationId));
      end;
    mckGroup:
      begin
        if ADestinationKind <> mdkGroup then Exit;
        Result := (Info.GroupId <> '') and SameText(Info.GroupId, ADestinationId);
      end;
  end;
end;

constructor TMessengerGroupService.Create(
  const AStore: IMessengerConversationStore);
begin
  inherited Create;
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  FStore := AStore;
end;

class function TMessengerGroupService.CanManageMembers(
  ARole: TMessengerMemberRole): Boolean;
begin
  Result := ARole in [mmrAdmin, mmrOwner];
end;

procedure TMessengerGroupService.AddMember(const AConversationId,
  AActorUserId, AUserId: string; ARole: TMessengerMemberRole);
var
  Info: TMessengerConversationInfo;
begin
  if not FStore.TryGetConversation(AConversationId, Info) or
     (Info.Kind <> mckGroup) then
    raise EMessengerAcceptanceError.Create('Group conversation not found');
  if not FStore.IsActiveMember(AConversationId, AActorUserId) or
     not CanManageMembers(FStore.MemberRole(AConversationId, AActorUserId)) then
    raise EMessengerUnauthorized.Create('Actor cannot manage group members');
  if ARole = mmrOwner then
    raise EMessengerAcceptanceError.Create(
      'Ownership transfer requires an explicit ownership operation');
  FStore.AddMember(AConversationId, AActorUserId, AUserId, ARole);
end;

procedure TMessengerGroupService.RemoveMember(const AConversationId,
  AActorUserId, AUserId: string);
var
  Info: TMessengerConversationInfo;
  TargetRole: TMessengerMemberRole;
begin
  if not FStore.TryGetConversation(AConversationId, Info) or
     (Info.Kind <> mckGroup) then
    raise EMessengerAcceptanceError.Create('Group conversation not found');
  if not FStore.IsActiveMember(AConversationId, AActorUserId) or
     not CanManageMembers(FStore.MemberRole(AConversationId, AActorUserId)) then
    raise EMessengerUnauthorized.Create('Actor cannot manage group members');

  if FStore.IsActiveMember(AConversationId, AUserId) then
  begin
    TargetRole := FStore.MemberRole(AConversationId, AUserId);
    if TargetRole = mmrOwner then
      raise EMessengerAcceptanceError.Create('Group owner cannot be removed');
  end;
  FStore.RemoveMember(AConversationId, AActorUserId, AUserId);
end;

end.
