unit Dext.Messenger.Gateway.Core;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  Dext.Messenger.Commands,
  Dext.Messenger.Models;

type
  EMessengerGatewayError = class(Exception);
  EMessengerRateLimitExceeded = class(EMessengerGatewayError);
  EMessengerSessionRejected = class(EMessengerGatewayError);

  TMessengerSession = record
  public
    UserId: string;
    DeviceId: string;
    SessionId: string;
    GatewayId: string;
    Authenticated: Boolean;
    class function AuthenticatedSession(const AUserId, ADeviceId,
      ASessionId, AGatewayId: string): TMessengerSession; static;
  end;

  TMessengerClientSend = record
  public
    ClientMessageId: string;
    ConversationId: string;
    TargetUserId: string;
    Kind: TMessengerMessageKind;
    PayloadJson: string;
  end;

  IMessengerGatewayRateLimiter = interface
    ['{7297A5B5-278A-4BD2-A13A-4AE1B4531097}']
    function TryAcquire(const AUserId, AOperation: string): Boolean;
  end;

  TMessengerFixedWindowRateLimiter = class(TInterfacedObject, IMessengerGatewayRateLimiter)
  private
    FLock: TCriticalSection;
    FWindowStartedMs: UInt64;
    FCount: Integer;
    FLimit: Integer;
    FWindowMs: Cardinal;
  public
    constructor Create(ALimit: Integer; AWindowMs: Cardinal = 1000);
    destructor Destroy; override;
    function TryAcquire(const AUserId, AOperation: string): Boolean;
  end;

  TMessengerGatewayCommandFactory = class
  private
    FRateLimiter: IMessengerGatewayRateLimiter;
    class procedure ValidateSession(const ASession: TMessengerSession); static;
  public
    constructor Create(const ARateLimiter: IMessengerGatewayRateLimiter);
    function CreateAcceptCommand(const ASession: TMessengerSession;
      const AClientSend: TMessengerClientSend): TMessengerAcceptMessageCommand;
  end;

implementation

class function TMessengerSession.AuthenticatedSession(const AUserId,
  ADeviceId, ASessionId, AGatewayId: string): TMessengerSession;
begin
  Result := Default(TMessengerSession);
  Result.UserId := AUserId;
  Result.DeviceId := ADeviceId;
  Result.SessionId := ASessionId;
  Result.GatewayId := AGatewayId;
  Result.Authenticated := True;
end;

constructor TMessengerFixedWindowRateLimiter.Create(ALimit: Integer;
  AWindowMs: Cardinal);
begin
  inherited Create;
  if ALimit <= 0 then raise EArgumentOutOfRangeException.Create('ALimit');
  if AWindowMs = 0 then raise EArgumentOutOfRangeException.Create('AWindowMs');
  FLock := TCriticalSection.Create;
  FLimit := ALimit;
  FWindowMs := AWindowMs;
  FWindowStartedMs := TThread.GetTickCount64;
  FCount := 0;
end;

destructor TMessengerFixedWindowRateLimiter.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMessengerFixedWindowRateLimiter.TryAcquire(const AUserId,
  AOperation: string): Boolean;
var
  NowMs: UInt64;
begin
  { This implementation is process-level protection suitable as a default
    gateway circuit breaker. Production per-user distributed policies may be
    supplied through the same interface. }
  NowMs := TThread.GetTickCount64;
  FLock.Enter;
  try
    if NowMs - FWindowStartedMs >= FWindowMs then
    begin
      FWindowStartedMs := NowMs;
      FCount := 0;
    end;
    if FCount >= FLimit then Exit(False);
    Inc(FCount);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

constructor TMessengerGatewayCommandFactory.Create(
  const ARateLimiter: IMessengerGatewayRateLimiter);
begin
  inherited Create;
  if ARateLimiter = nil then raise EArgumentNilException.Create('ARateLimiter');
  FRateLimiter := ARateLimiter;
end;

class procedure TMessengerGatewayCommandFactory.ValidateSession(
  const ASession: TMessengerSession);
begin
  if not ASession.Authenticated then
    raise EMessengerSessionRejected.Create('Unauthenticated session');
  if ASession.UserId = '' then raise EMessengerSessionRejected.Create('Missing user identity');
  if ASession.DeviceId = '' then raise EMessengerSessionRejected.Create('Missing device identity');
  if ASession.SessionId = '' then raise EMessengerSessionRejected.Create('Missing session identity');
  if ASession.GatewayId = '' then raise EMessengerSessionRejected.Create('Missing gateway identity');
end;

function TMessengerGatewayCommandFactory.CreateAcceptCommand(
  const ASession: TMessengerSession;
  const AClientSend: TMessengerClientSend): TMessengerAcceptMessageCommand;
begin
  ValidateSession(ASession);
  if not FRateLimiter.TryAcquire(ASession.UserId, 'message.send') then
    raise EMessengerRateLimitExceeded.Create('Message send rate limit exceeded');

  if AClientSend.ClientMessageId = '' then raise EMessengerGatewayError.Create('client_message_id is required');
  if AClientSend.ConversationId = '' then raise EMessengerGatewayError.Create('conversation_id is required');
  if AClientSend.TargetUserId = '' then raise EMessengerGatewayError.Create('target_user_id is required');

  { SenderUserId is ALWAYS derived from authenticated session state. The client
    wire payload has no authority to choose or override sender identity. }
  Result := TMessengerAcceptMessageCommand.Create(
    AClientSend.ClientMessageId,
    AClientSend.ConversationId,
    ASession.UserId,
    AClientSend.TargetUserId,
    AClientSend.Kind,
    AClientSend.PayloadJson);
end;

end.
