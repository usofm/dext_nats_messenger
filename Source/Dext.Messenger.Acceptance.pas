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
    class function NewAccepted(const AAccepted: TMessengerAcceptedMessage): TMessengerAcceptanceResult; static;
    class function Duplicate(const AAccepted: TMessengerAcceptedMessage): TMessengerAcceptanceResult; static;
  end;

  IMessengerConversationAuthorizer = interface
    ['{C89EF39F-9D6B-4BA0-B5CB-1EB61ACF5F77}']
    function CanSend(const ASenderUserId, AConversationId, ATargetUserId: string): Boolean;
  end;

  IMessengerIdempotencyStore = interface
    ['{96FCE5C9-E28B-4449-B188-4334F62613B2}']
    function TryGetAccepted(const ASenderUserId, AClientMessageId: string;
      out AAccepted: TMessengerAcceptedMessage): Boolean;
    procedure StoreAccepted(const ASenderUserId, AClientMessageId: string;
      const AAccepted: TMessengerAcceptedMessage);
  end;

  IMessengerMessageIdGenerator = interface
    ['{B2BD704A-EBED-48E7-8C91-92F9128DAE4C}']
    function NewMessageId: string;
  end;

  IMessengerClock = interface
    ['{D90E51A0-EB4D-43BB-9EA0-D9581343D7B1}']
    function UnixTimeMilliseconds: Int64;
  end;

  IMessengerAcceptedMessageSink = interface
    ['{3DDF2DB4-2866-4F5F-A56E-E6C5E3478233}']
    procedure PublishAccepted(const AAccepted: TMessengerAcceptedMessage);
  end;

  TMessengerAcceptanceService = class
  private
    FAuthorizer: IMessengerConversationAuthorizer;
    FIdempotency: IMessengerIdempotencyStore;
    FIdGenerator: IMessengerMessageIdGenerator;
    FClock: IMessengerClock;
    FSink: IMessengerAcceptedMessageSink;
    FPartitionCount: Integer;
    class procedure ValidateCommand(const ACommand: TMessengerAcceptMessageCommand); static;
  public
    constructor Create(
      const AAuthorizer: IMessengerConversationAuthorizer;
      const AIdempotency: IMessengerIdempotencyStore;
      const AIdGenerator: IMessengerMessageIdGenerator;
      const AClock: IMessengerClock;
      const ASink: IMessengerAcceptedMessageSink;
      APartitionCount: Integer = 64);

    function Accept(const ACommand: TMessengerAcceptMessageCommand): TMessengerAcceptanceResult;
  end;

implementation

uses
  Dext.Messenger.Partitioning;

class function TMessengerAcceptanceResult.NewAccepted(
  const AAccepted: TMessengerAcceptedMessage): TMessengerAcceptanceResult;
begin
  Result := Default(TMessengerAcceptanceResult);
  Result.Status := masAccepted;
  Result.Accepted := AAccepted;
end;

class function TMessengerAcceptanceResult.Duplicate(
  const AAccepted: TMessengerAcceptedMessage): TMessengerAcceptanceResult;
begin
  Result := Default(TMessengerAcceptanceResult);
  Result.Status := masDuplicate;
  Result.Accepted := AAccepted;
end;

constructor TMessengerAcceptanceService.Create(
  const AAuthorizer: IMessengerConversationAuthorizer;
  const AIdempotency: IMessengerIdempotencyStore;
  const AIdGenerator: IMessengerMessageIdGenerator;
  const AClock: IMessengerClock;
  const ASink: IMessengerAcceptedMessageSink;
  APartitionCount: Integer);
begin
  inherited Create;
  if AAuthorizer = nil then raise EArgumentNilException.Create('AAuthorizer');
  if AIdempotency = nil then raise EArgumentNilException.Create('AIdempotency');
  if AIdGenerator = nil then raise EArgumentNilException.Create('AIdGenerator');
  if AClock = nil then raise EArgumentNilException.Create('AClock');
  if ASink = nil then raise EArgumentNilException.Create('ASink');
  if APartitionCount <= 0 then raise EArgumentOutOfRangeException.Create('APartitionCount');
  FAuthorizer := AAuthorizer;
  FIdempotency := AIdempotency;
  FIdGenerator := AIdGenerator;
  FClock := AClock;
  FSink := ASink;
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
  if ACommand.TargetUserId = '' then
    raise EMessengerAcceptanceError.Create('target_user_id must not be empty');
  if (ACommand.Kind <> mmkSystem) and (ACommand.PayloadJson = '') then
    raise EMessengerAcceptanceError.Create('payload_json must not be empty');
end;

function TMessengerAcceptanceService.Accept(
  const ACommand: TMessengerAcceptMessageCommand): TMessengerAcceptanceResult;
var
  Existing: TMessengerAcceptedMessage;
  Message: TMessengerMessage;
  Accepted: TMessengerAcceptedMessage;
  Partition: Integer;
begin
  ValidateCommand(ACommand);

  { The permanent idempotency lookup is deliberately before authorization and
    publishing. A retry of an already accepted request returns the canonical
    result and never creates a second message. }
  if FIdempotency.TryGetAccepted(ACommand.SenderUserId,
    ACommand.ClientMessageId, Existing) then
    Exit(TMessengerAcceptanceResult.Duplicate(Existing));

  if not FAuthorizer.CanSend(ACommand.SenderUserId, ACommand.ConversationId,
    ACommand.TargetUserId) then
    raise EMessengerUnauthorized.Create('Sender is not authorized for this conversation');

  Partition := TMessengerPartitioning.PartitionFor(
    ACommand.ConversationId, FPartitionCount);

  Message := TMessengerMessage.CreateV1(
    FIdGenerator.NewMessageId,
    ACommand.ClientMessageId,
    ACommand.ConversationId,
    ACommand.SenderUserId,
    ACommand.Kind,
    FClock.UnixTimeMilliseconds,
    ACommand.PayloadJson);

  Accepted := TMessengerAcceptedMessage.Create(
    Message, ACommand.TargetUserId, Partition);

  { Publish first; StoreAccepted only after durable sink acknowledges. Concrete
    persistence implementations should make the product idempotency record
    durable and race-safe (unique sender_user_id + client_message_id). }
  FSink.PublishAccepted(Accepted);
  FIdempotency.StoreAccepted(ACommand.SenderUserId,
    ACommand.ClientMessageId, Accepted);

  Result := TMessengerAcceptanceResult.NewAccepted(Accepted);
end;

end.
