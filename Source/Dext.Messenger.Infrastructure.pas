unit Dext.Messenger.Infrastructure;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Commands,
  Dext.Messenger.Outbox;

type
  TMessengerSystemClock = class(TInterfacedObject, IMessengerClock)
  public
    function UnixTimeMilliseconds: Int64;
  end;

  TMessengerGuidIdGenerator = class(TInterfacedObject, IMessengerMessageIdGenerator)
  public
    function NewMessageId: string;
  end;

  TMessengerAuthorizationCallback = reference to function(
    const ASenderUserId, AConversationId: string;
    ADestinationKind: TMessengerDestinationKind;
    const ADestinationId: string): Boolean;

  TMessengerCallbackAuthorizer = class(TInterfacedObject, IMessengerConversationAuthorizer)
  private
    FCallback: TMessengerAuthorizationCallback;
  public
    constructor Create(const ACallback: TMessengerAuthorizationCallback);
    function CanSend(const ASenderUserId, AConversationId: string;
      ADestinationKind: TMessengerDestinationKind;
      const ADestinationId: string): Boolean;
  end;

  { Development/test reference implementation. It models the same atomicity the
    PostgreSQL adapter must provide: canonical message + conversation sequence +
    outbox are created under one lock. It is NOT durable across process restarts. }
  TMessengerMemoryAcceptanceOutboxStore = class(TInterfacedObject,
    IMessengerAcceptanceStore, IMessengerOutboxStore)
  private
    FLock: TCriticalSection;
    FAccepted: TDictionary<string, TMessengerAcceptedMessage>;
    FConversationSequence: TDictionary<string, Int64>;
    FOutbox: TDictionary<string, TMessengerOutboxItem>;
    FLastErrors: TDictionary<string, string>;
    class function IdempotencyKey(const ASenderUserId,
      AClientMessageId: string): string; static;
    class function OutboxIdFor(const AAccepted: TMessengerAcceptedMessage): string; static;
    class function SameLogicalCommand(const AExisting: TMessengerAcceptedMessage;
      const ACommand: TMessengerAcceptMessageCommand): Boolean; static;
  public
    constructor Create;
    destructor Destroy; override;

    function AcceptOrGet(const ACommand: TMessengerAcceptMessageCommand;
      const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;

    function ClaimBatch(const AWorkerId: string; ANowUnixMs, ALeaseMs: Int64;
      AMaxItems: Integer): TArray<TMessengerOutboxItem>;
    procedure MarkPublished(const AOutboxId, AWorkerId: string);
    procedure ReleaseForRetry(const AOutboxId, AWorkerId: string;
      AAvailableAtUnixMs: Int64; const AError: string);

    function PendingOutboxCount: Integer;
  end;

implementation

uses
  System.DateUtils;

function TMessengerSystemClock.UnixTimeMilliseconds: Int64;
var
  UtcNow: TDateTime;
begin
  UtcNow := TTimeZone.Local.ToUniversalTime(Now);
  Result := DateTimeToUnix(UtcNow, False) * Int64(1000) + MilliSecondOf(UtcNow);
end;

function TMessengerGuidIdGenerator.NewMessageId: string;
var
  G: TGUID;
begin
  if CreateGUID(G) <> 0 then
    raise EMessengerAcceptanceError.Create('Unable to generate message id');
  Result := LowerCase(GUIDToString(G));
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := StringReplace(Result, '-', '', [rfReplaceAll]);
end;

constructor TMessengerCallbackAuthorizer.Create(
  const ACallback: TMessengerAuthorizationCallback);
begin
  inherited Create;
  if not Assigned(ACallback) then raise EArgumentNilException.Create('ACallback');
  FCallback := ACallback;
end;

function TMessengerCallbackAuthorizer.CanSend(const ASenderUserId,
  AConversationId: string; ADestinationKind: TMessengerDestinationKind;
  const ADestinationId: string): Boolean;
begin
  Result := FCallback(ASenderUserId, AConversationId,
    ADestinationKind, ADestinationId);
end;

class function TMessengerMemoryAcceptanceOutboxStore.IdempotencyKey(
  const ASenderUserId, AClientMessageId: string): string;
begin
  Result := ASenderUserId + #31 + AClientMessageId;
end;

class function TMessengerMemoryAcceptanceOutboxStore.OutboxIdFor(
  const AAccepted: TMessengerAcceptedMessage): string;
begin
  Result := 'message.accepted:' + AAccepted.Message.MessageId;
end;

class function TMessengerMemoryAcceptanceOutboxStore.SameLogicalCommand(
  const AExisting: TMessengerAcceptedMessage;
  const ACommand: TMessengerAcceptMessageCommand): Boolean;
begin
  Result :=
    (AExisting.Message.ConversationId = ACommand.ConversationId) and
    (AExisting.Message.SenderUserId = ACommand.SenderUserId) and
    (AExisting.DestinationKind = ACommand.DestinationKind) and
    (AExisting.DestinationId = ACommand.DestinationId) and
    (AExisting.Message.Kind = ACommand.Kind) and
    (AExisting.Message.PayloadJson = ACommand.PayloadJson);
end;

constructor TMessengerMemoryAcceptanceOutboxStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAccepted := TDictionary<string, TMessengerAcceptedMessage>.Create;
  FConversationSequence := TDictionary<string, Int64>.Create;
  FOutbox := TDictionary<string, TMessengerOutboxItem>.Create;
  FLastErrors := TDictionary<string, string>.Create;
end;

destructor TMessengerMemoryAcceptanceOutboxStore.Destroy;
begin
  FLastErrors.Free;
  FOutbox.Free;
  FConversationSequence.Free;
  FAccepted.Free;
  FLock.Free;
  inherited;
end;

function TMessengerMemoryAcceptanceOutboxStore.AcceptOrGet(
  const ACommand: TMessengerAcceptMessageCommand;
  const AProposal: TMessengerAcceptedMessage): TMessengerAcceptanceStoreResult;
var
  Key: string;
  Existing: TMessengerAcceptedMessage;
  Canonical: TMessengerAcceptedMessage;
  Sequence: Int64;
  OutboxItem: TMessengerOutboxItem;
begin
  Key := IdempotencyKey(ACommand.SenderUserId, ACommand.ClientMessageId);

  FLock.Enter;
  try
    if FAccepted.TryGetValue(Key, Existing) then
    begin
      if not SameLogicalCommand(Existing, ACommand) then
        raise EMessengerAcceptanceError.Create(
          'client_message_id was already used for a different logical command');
      Result.Accepted := Existing;
      Result.WasDuplicate := True;
      Exit;
    end;

    if not FConversationSequence.TryGetValue(ACommand.ConversationId, Sequence) then
      Sequence := 0;
    Inc(Sequence);

    Canonical := AProposal;
    Canonical.Sequence := Sequence;

    { All mutations below are in one critical section, modeling one DB
      transaction in the production adapter. }
    FConversationSequence.AddOrSetValue(ACommand.ConversationId, Sequence);
    FAccepted.Add(Key, Canonical);

    OutboxItem := TMessengerOutboxItem.Create(
      OutboxIdFor(Canonical), Canonical, Canonical.Message.CreatedAtUnixMs);
    FOutbox.Add(OutboxItem.OutboxId, OutboxItem);

    Result.Accepted := Canonical;
    Result.WasDuplicate := False;
  finally
    FLock.Leave;
  end;
end;

function TMessengerMemoryAcceptanceOutboxStore.ClaimBatch(
  const AWorkerId: string; ANowUnixMs, ALeaseMs: Int64;
  AMaxItems: Integer): TArray<TMessengerOutboxItem>;
var
  Keys: TArray<string>;
  K: string;
  Item: TMessengerOutboxItem;
  N: Integer;
begin
  if AWorkerId = '' then raise EArgumentException.Create('worker_id must not be empty');
  if ANowUnixMs <= 0 then raise EArgumentOutOfRangeException.Create('ANowUnixMs');
  if ALeaseMs <= 0 then raise EArgumentOutOfRangeException.Create('ALeaseMs');
  if AMaxItems <= 0 then raise EArgumentOutOfRangeException.Create('AMaxItems');

  SetLength(Result, 0);
  FLock.Enter;
  try
    Keys := FOutbox.Keys.ToArray;
    SetLength(Result, AMaxItems);
    N := 0;
    for K in Keys do
    begin
      if N >= AMaxItems then Break;
      if not FOutbox.TryGetValue(K, Item) then Continue;
      if Item.AvailableAtUnixMs > ANowUnixMs then Continue;
      if (Item.LeaseOwner <> '') and (Item.LeaseUntilUnixMs > ANowUnixMs) then Continue;

      Item.LeaseOwner := AWorkerId;
      Item.LeaseUntilUnixMs := ANowUnixMs + ALeaseMs;
      FOutbox.AddOrSetValue(K, Item);
      Result[N] := Item;
      Inc(N);
    end;
    SetLength(Result, N);
  finally
    FLock.Leave;
  end;
end;

procedure TMessengerMemoryAcceptanceOutboxStore.MarkPublished(
  const AOutboxId, AWorkerId: string);
var
  Item: TMessengerOutboxItem;
begin
  FLock.Enter;
  try
    if not FOutbox.TryGetValue(AOutboxId, Item) then Exit;
    if Item.LeaseOwner <> AWorkerId then
      raise EInvalidOperation.Create('Outbox lease owner mismatch');
    FOutbox.Remove(AOutboxId);
    FLastErrors.Remove(AOutboxId);
  finally
    FLock.Leave;
  end;
end;

procedure TMessengerMemoryAcceptanceOutboxStore.ReleaseForRetry(
  const AOutboxId, AWorkerId: string; AAvailableAtUnixMs: Int64;
  const AError: string);
var
  Item: TMessengerOutboxItem;
begin
  FLock.Enter;
  try
    if not FOutbox.TryGetValue(AOutboxId, Item) then Exit;
    if Item.LeaseOwner <> AWorkerId then
      raise EInvalidOperation.Create('Outbox lease owner mismatch');
    Inc(Item.AttemptCount);
    Item.AvailableAtUnixMs := AAvailableAtUnixMs;
    Item.LeaseOwner := '';
    Item.LeaseUntilUnixMs := 0;
    FOutbox.AddOrSetValue(AOutboxId, Item);
    FLastErrors.AddOrSetValue(AOutboxId, Copy(AError, 1, 2000));
  finally
    FLock.Leave;
  end;
end;

function TMessengerMemoryAcceptanceOutboxStore.PendingOutboxCount: Integer;
begin
  FLock.Enter;
  try
    Result := FOutbox.Count;
  finally
    FLock.Leave;
  end;
end;

end.
