unit Dext.Messenger.Conversation.Tests;

interface

uses
  System.SysUtils,
  Dext.Testing,
  Dext.Testing.Attributes,
  Dext.Testing.Fluent,
  Dext.Messenger.Conversations,
  Dext.Messenger.ConversationLifecycle;

type
  TFixedConversationIds = class(TInterfacedObject, IMessengerConversationIdGenerator)
  public
    function NewConversationId: string;
    function NewGroupId: string;
  end;

  TMemoryLifecycleStore = class(TInterfacedObject, IMessengerConversationLifecycleStore)
  private
    FHasDirect: Boolean;
    FDirect: TMessengerConversationInfo;
  public
    function CreateOrGetDirect(const AConversationId, AUserA,
      AUserB: string): TMessengerCreateConversationResult;
    function CreateGroup(const AConversationId, AGroupId, AOwnerUserId,
      ATitle: string): TMessengerConversationInfo;
  end;

  [TestFixture('Dext Messenger Conversations')]
  TMessengerConversationTests = class
  public
    [Test, Category('Unit'), Category('Conversation')]
    procedure DirectCreate_ShouldConvergeOnExistingConversation;
    [Test, Category('Unit'), Category('Conversation')]
    procedure GroupCreate_ShouldReturnTypedGroupIdentity;
    [Test, Category('Unit'), Category('Security')]
    procedure DirectCreate_ShouldRejectSelfConversation;
  end;

implementation

function TFixedConversationIds.NewConversationId: string;
begin
  Result := 'conv-fixed';
end;

function TFixedConversationIds.NewGroupId: string;
begin
  Result := 'group-fixed';
end;

function TMemoryLifecycleStore.CreateOrGetDirect(const AConversationId, AUserA,
  AUserB: string): TMessengerCreateConversationResult;
begin
  Result := Default(TMessengerCreateConversationResult);
  if FHasDirect then
  begin
    Result.Conversation := FDirect;
    Result.WasExisting := True;
    Exit;
  end;
  FDirect := Default(TMessengerConversationInfo);
  FDirect.ConversationId := AConversationId;
  FDirect.Kind := mckDirect;
  FHasDirect := True;
  Result.Conversation := FDirect;
  Result.WasExisting := False;
end;

function TMemoryLifecycleStore.CreateGroup(const AConversationId, AGroupId,
  AOwnerUserId, ATitle: string): TMessengerConversationInfo;
begin
  Result := Default(TMessengerConversationInfo);
  Result.ConversationId := AConversationId;
  Result.Kind := mckGroup;
  Result.GroupId := AGroupId;
end;

procedure TMessengerConversationTests.DirectCreate_ShouldConvergeOnExistingConversation;
var
  Svc: TMessengerConversationLifecycleService;
  A, B: TMessengerCreateConversationResult;
begin
  Svc := TMessengerConversationLifecycleService.Create(
    TMemoryLifecycleStore.Create, TFixedConversationIds.Create);
  try
    A := Svc.CreateOrGetDirect('u-1', 'u-2');
    B := Svc.CreateOrGetDirect('u-1', 'u-2');
    Should(A.WasExisting).BeFalse;
    Should(B.WasExisting).BeTrue;
    Should(B.Conversation.ConversationId).Be(A.Conversation.ConversationId);
  finally
    Svc.Free;
  end;
end;

procedure TMessengerConversationTests.GroupCreate_ShouldReturnTypedGroupIdentity;
var
  Svc: TMessengerConversationLifecycleService;
  G: TMessengerConversationInfo;
begin
  Svc := TMessengerConversationLifecycleService.Create(
    TMemoryLifecycleStore.Create, TFixedConversationIds.Create);
  try
    G := Svc.CreateGroup('owner-1', 'Engineering');
    Should(Ord(G.Kind)).Be(Ord(mckGroup));
    Should(G.GroupId).Be('group-fixed');
    Should(G.ConversationId).Be('conv-fixed');
  finally
    Svc.Free;
  end;
end;

procedure TMessengerConversationTests.DirectCreate_ShouldRejectSelfConversation;
var
  Svc: TMessengerConversationLifecycleService;
  Raised: Boolean;
begin
  Svc := TMessengerConversationLifecycleService.Create(
    TMemoryLifecycleStore.Create, TFixedConversationIds.Create);
  try
    Raised := False;
    try
      Svc.CreateOrGetDirect('u-1', 'u-1');
    except
      on EArgumentException do Raised := True;
    end;
    Should(Raised).BeTrue;
  finally
    Svc.Free;
  end;
end;

end.
