unit Dext.Messenger.Acceptance;

interface

uses
  System.SysUtils,
  Dext.Messenger.Commands,
  Dext.Messenger.Models;

type
  EMessengerAcceptanceError = class(Exception);
  EMessengerUnauthorized = class(EMessengerAcceptanceError);

  TMessengerAcceptanceStatus = (masAccepted, masDuplicate);

  TMessengerAcceptanceResult = record
  public
    Status: TMessengerAcceptanceStatus;
    Accepted: TMessengerAcceptedMessage;
  end;

  { Authorization is evaluated against the typed destination. Concrete
    implementations normally query/cache conversation membership and roles. }
  IMessengerConversationAuthorizer = interface
    ['{C89EF39F-9D6B-4BA0-B5CB-1EB61ACF5F77}']
    function CanSend(const ASenderUserId, AConversationId: string;
      ADestinationKind: TMessengerDestinationKind;
      const ADestinationId: string): Boolean;
  end;

  IMessengerMessageIdGenerator = interface
    ['{B2BD704A-EBED-48E7-8C91-92F9128DAE4C}']
    function NewMessageId: string;
  end;

  IMessengerClock = interface
    ['{D90E51A0-EB4D-43BB-9EA0-D9581343D7B1}']
    function UnixTimeMilliseconds: Int64;
  end;

  { Result of ONE atomic acceptance transaction. The store MUST either:
      - insert the canonical message, allocate its conversation sequence and
        insert the outbox event in the same transaction; or
      - return the already-existing canonical message for the same
        (sender_user_id, client_message_id).
    It must never return a proposal that was not committed. }
  TMessengerAcceptanceStoreResult = record
  public
    Accepted: TMessengerAcceptedMessage;
    WasDuplicate: Boolean;
  end;

  IMessengerAcceptanceStore = interface
    ['{9527F148-773B-4DBE-B935-F0A86F1D511B}']
    function AcceptOrGet(const ACommand: TMessengerAcceptMessageCommand;
      const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;
  end;

  TMessengerAcceptanceService = class
  private
    FAuthorizer: IMessengerConversationAuthorizer;
    FStore: IMessengerAcceptanceStore;
    FIdGenerator: IMessengerMessageIdGenerator;
    FClock: IMessengerClock;
    FPartitionCount: Integer;
    class procedure ValidateCommand(const ACommand: TMessengerAcceptMessageCommand); static;
  public
    constructor Create(
      const AAuthorizer: IMessengerConversationAuthorizer;
      const AStore: IMessengerAcceptanceStore;
      const AIdGenerator: IMessengerMessageIdGenerator;
      const AClock: IMessengerClock;
      APartitionCount: Integer = 64);

    function Accept(const ACommand: TMessengerAcceptMessageCommand): TMessengerAcceptanceResult;
  end;

implementation

uses
  Dext.Messenger.Partitioning;

constructor TMessengerAcceptanceService.Create(
  const AAuthorizer: IMessengerConversationAuthorizer;
  const AStore: IMessengerAcceptanceStore;
  const AIdGenerator: IMessengerMessageIdGenerator;
  const AClock: IMessengerClock;
  APartitionCount: Integer);
begin
  inherited Create;
  if AAuthorizer = nil then raise EArgumentNilException.Create('AAuthorizer');
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  if AIdGenerator = nil then raise EArgumentNilException.Create('AIdGenerator');
  if AClock = nil then raise EArgumentNilException.Create('AClock');
  if APartitionCount <= 0 then raise EArgumentOutOfRangeException.Create('APartitionCount');
  FAuthorizer := AAuthorizer;
  FStore := AStore;
  FIdGenerator := AIdGenerator;
  FClock := AClock;
  FPartitionCount := APartitionCount;
end;

class procedure TMessengerAcceptanceService.ValidateCommand(
  const ACommand: TMessengerAcceptMessageCommand);
begin
  if ACommand.ClientMessageId = '' then
    raise EMessengerAcceptanceError.Create('client_message_id must not be empty');
  if ACommand.ConversationId = '' then
    raise EMessengerAcceptanceError.Create('conversation_id must not be empty');
  if ACommand.SenderUserId = '' then
    raise EMessengerAcceptanceError.Create('sender_user_id must not be empty');
  if ACommand.DestinationId = '' then
    raise EMessengerAcceptanceError.Create('destination_id must not be empty');
  if (ACommand.Kind <> mmkSystem) and (ACommand.PayloadJson = '') then
    raise EMessengerAcceptanceError.Create('payload_json must not be empty');
end;

function TMessengerAcceptanceService.Accept(
  const ACommand: TMessengerAcceptMessageCommand): TMessengerAcceptanceResult;
var
  Message: TMessengerMessage;
  Proposal: TMessengerAcceptedMessage;
  Stored: TMessengerAcceptanceStoreResult;
  Partition: Integer;
begin
  ValidateCommand(ACommand);

  if not FAuthorizer.CanSend(ACommand.SenderUserId, ACommand.ConversationId,
    ACommand.DestinationKind, ACommand.DestinationId) then
    raise EMessengerUnauthorized.Create('Sender is not authorized for this conversation');

  Partition := TMessengerPartitioner.PartitionFor(
    ACommand.ConversationId, FPartitionCount);

  Message := TMessengerMessage.CreateV1(
    FIdGenerator.NewMessageId,
    ACommand.ClientMessageId,
    ACommand.ConversationId,
    ACommand.SenderUserId,
    ACommand.Kind,
    FClock.UnixTimeMilliseconds,
    ACommand.PayloadJson);

  { Sequence=0 means proposal. The store assigns the canonical sequence and
    writes message + outbox atomically. If a concurrent retry wins, the store
    returns that winner instead of this proposal. }
  Proposal := TMessengerAcceptedMessage.Create(
    Message, ACommand.DestinationKind, ACommand.DestinationId, Partition, 0);

  Stored := FStore.AcceptOrGet(ACommand, Proposal);
  if not Stored.Accepted.IsCanonical then
    raise EMessengerAcceptanceError.Create(
      'Acceptance store returned a non-canonical message without sequence');

  Result.Accepted := Stored.Accepted;
  if Stored.WasDuplicate then
    Result.Status := masDuplicate
  else
    Result.Status := masAccepted;
end;

end.
