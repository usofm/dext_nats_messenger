unit Dext.Messenger.Infrastructure;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Commands;

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
    const ASenderUserId, AConversationId, ATargetUserId: string): Boolean;

  TMessengerCallbackAuthorizer = class(TInterfacedObject, IMessengerConversationAuthorizer)
  private
    FCallback: TMessengerAuthorizationCallback;
  public
    constructor Create(const ACallback: TMessengerAuthorizationCallback);
    function CanSend(const ASenderUserId, AConversationId,
      ATargetUserId: string): Boolean;
  end;

  { Development/test implementation only. Production uses the database-backed
    unique sender/client key so idempotency survives process restarts. }
  TMessengerMemoryIdempotencyStore = class(TInterfacedObject, IMessengerIdempotencyStore)
  private
    FLock: TCriticalSection;
    FItems: TDictionary<string, TMessengerAcceptedMessage>;
    class function KeyOf(const ASenderUserId, AClientMessageId: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;
    function TryGetAccepted(const ASenderUserId, AClientMessageId: string;
      out AAccepted: TMessengerAcceptedMessage): Boolean;
    procedure StoreAccepted(const ASenderUserId, AClientMessageId: string;
      const AAccepted: TMessengerAcceptedMessage);
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
  AConversationId, ATargetUserId: string): Boolean;
begin
  Result := FCallback(ASenderUserId, AConversationId, ATargetUserId);
end;

class function TMessengerMemoryIdempotencyStore.KeyOf(const ASenderUserId,
  AClientMessageId: string): string;
begin
  Result := ASenderUserId + #31 + AClientMessageId;
end;

constructor TMessengerMemoryIdempotencyStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TDictionary<string, TMessengerAcceptedMessage>.Create;
end;

destructor TMessengerMemoryIdempotencyStore.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

function TMessengerMemoryIdempotencyStore.TryGetAccepted(const ASenderUserId,
  AClientMessageId: string; out AAccepted: TMessengerAcceptedMessage): Boolean;
begin
  FLock.Enter;
  try
    Result := FItems.TryGetValue(KeyOf(ASenderUserId, AClientMessageId), AAccepted);
  finally
    FLock.Leave;
  end;
end;

procedure TMessengerMemoryIdempotencyStore.StoreAccepted(const ASenderUserId,
  AClientMessageId: string; const AAccepted: TMessengerAcceptedMessage);
var
  K: string;
begin
  K := KeyOf(ASenderUserId, AClientMessageId);
  FLock.Enter;
  try
    { First accepted canonical result wins. }
    if not FItems.ContainsKey(K) then
      FItems.Add(K, AAccepted);
  finally
    FLock.Leave;
  end;
end;

end.
