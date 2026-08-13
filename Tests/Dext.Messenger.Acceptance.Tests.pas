unit Dext.Messenger.Acceptance.Tests;

interface

uses
  System.SysUtils,
  Dext.Testing,
  Dext.Testing.Attributes,
  Dext.Testing.Fluent,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Commands,
  Dext.Messenger.Models;

type
  TAllowAllAuthorizer = class(TInterfacedObject, IMessengerConversationAuthorizer)
  public
    function CanSend(const ASenderUserId, AConversationId: string;
      ADestinationKind: TMessengerDestinationKind;
      const ADestinationId: string): Boolean;
  end;

  TFixedIdGenerator = class(TInterfacedObject, IMessengerMessageIdGenerator)
  private
    FValue: string;
  public
    constructor Create(const AValue: string);
    function NewMessageId: string;
  end;

  TFixedClock = class(TInterfacedObject, IMessengerClock)
  private
    FValue: Int64;
  public
    constructor Create(AValue: Int64);
    function UnixTimeMilliseconds: Int64;
  end;

  TCanonicalStore = class(TInterfacedObject, IMessengerAcceptanceStore)
  private
    FHasValue: Boolean;
    FCanonical: TMessengerAcceptedMessage;
  public
    function AcceptOrGet(const ACommand: TMessengerAcceptMessageCommand;
      const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;
  end;

  [TestFixture('Dext Messenger Acceptance')]
  TMessengerAcceptanceTests = class
  public
    [Test, Category('Unit'), Category('Idempotency')]
    procedure Duplicate_ShouldReturnSameCanonicalMessageAndSequence;
    [Test, Category('Unit'), Category('Acceptance')]
    procedure Proposal_ShouldReceiveCanonicalSequenceFromStore;
  end;

implementation

function TAllowAllAuthorizer.CanSend(const ASenderUserId, AConversationId: string;
  ADestinationKind: TMessengerDestinationKind;
  const ADestinationId: string): Boolean;
begin
  Result := True;
end;

constructor TFixedIdGenerator.Create(const AValue: string);
begin
  inherited Create;
  FValue := AValue;
end;

function TFixedIdGenerator.NewMessageId: string;
begin
  Result := FValue;
end;

constructor TFixedClock.Create(AValue: Int64);
begin
  inherited Create;
  FValue := AValue;
end;

function TFixedClock.UnixTimeMilliseconds: Int64;
begin
  Result := FValue;
end;

function TCanonicalStore.AcceptOrGet(const ACommand: TMessengerAcceptMessageCommand;
  const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;
begin
  Result := Default(TMessengerAcceptanceStoreResult);
  if FHasValue then
  begin
    Result.Accepted := FCanonical;
    Result.WasDuplicate := True;
    Exit;
  end;

  FCanonical := TMessengerAcceptedMessage.Create(
    AProposal.Message,
    AProposal.DestinationKind,
    AProposal.DestinationId,
    AProposal.Partition,
    101);
  FHasValue := True;
  Result.Accepted := FCanonical;
  Result.WasDuplicate := False;
end;

procedure TMessengerAcceptanceTests.Duplicate_ShouldReturnSameCanonicalMessageAndSequence;
var
  Store: IMessengerAcceptanceStore;
  Service: TMessengerAcceptanceService;
  Command: TMessengerAcceptMessageCommand;
  First, Second: TMessengerAcceptanceResult;
begin
  Store := TCanonicalStore.Create;
  Service := TMessengerAcceptanceService.Create(
    TAllowAllAuthorizer.Create,
    Store,
    TFixedIdGenerator.Create('message-fixed'),
    TFixedClock.Create(1786590000000),
    64);
  try
    Command := TMessengerAcceptMessageCommand.CreateDirect(
      'client-1', 'conv-1', 'sender-1', 'target-1', mmkText,
      '{"text":"hello"}');

    First := Service.Accept(Command);
    Second := Service.Accept(Command);

    Should(Ord(First.Status)).Be(Ord(masAccepted));
    Should(Ord(Second.Status)).Be(Ord(masDuplicate));
    Should(Second.Accepted.Message.MessageId).Be(First.Accepted.Message.MessageId);
    Should(Second.Accepted.Sequence).Be(First.Accepted.Sequence);
  finally
    Service.Free;
  end;
end;

procedure TMessengerAcceptanceTests.Proposal_ShouldReceiveCanonicalSequenceFromStore;
var
  Service: TMessengerAcceptanceService;
  ResultValue: TMessengerAcceptanceResult;
begin
  Service := TMessengerAcceptanceService.Create(
    TAllowAllAuthorizer.Create,
    TCanonicalStore.Create,
    TFixedIdGenerator.Create('message-2'),
    TFixedClock.Create(1786590000100),
    64);
  try
    ResultValue := Service.Accept(TMessengerAcceptMessageCommand.CreateGroup(
      'client-2', 'conv-2', 'sender-2', 'group-2', mmkText,
      '{"text":"group"}'));
    Should(ResultValue.Accepted.Sequence).Be(Int64(101));
    Should(ResultValue.Accepted.IsCanonical).BeTrue;
  finally
    Service.Free;
  end;
end;

end.
