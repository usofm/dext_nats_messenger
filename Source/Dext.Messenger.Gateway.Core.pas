unit Dext.Messenger.Gateway.Core;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
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

  { Per-user/operation fixed-window limiter with sharded locks. This is a
    process-local first line of defense. A distributed limiter can replace it
    behind IMessengerGatewayRateLimiter without changing gateway code. }
  TMessengerFixedWindowRateLimiter = class(TInterfacedObject, IMessengerGatewayRateLimiter)
  private type
    TRateBucket = record
      WindowStartedMs: Int64;
      Count: Integer;
    end;
    TRateShard = class
    public
      Lock: TCriticalSection;
      Buckets: TDictionary<string, TRateBucket>;
      constructor Create;
      destructor Destroy; override;
    end;
  private
    FShards: TObjectList<TRateShard>;
    FLimit: Integer;
    FWindowMs: Cardinal;
    FShardCount: Integer;
    class function MonotonicMs: Int64; static;
    function KeyOf(const AUserId, AOperation: string): string;
    function ShardFor(const AKey: string): TRateShard;
  public
    constructor Create(ALimit: Integer; AWindowMs: Cardinal = 1000;
      AShardCount: Integer = 64);
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

uses
  System.Diagnostics,
  Dext.Messenger.Partitioning;

{ TMessengerSession }

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

{ TMessengerFixedWindowRateLimiter.TRateShard }

constructor TMessengerFixedWindowRateLimiter.TRateShard.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Buckets := TDictionary<string, TRateBucket>.Create;
end;

destructor TMessengerFixedWindowRateLimiter.TRateShard.Destroy;
begin
  Buckets.Free;
  Lock.Free;
  inherited;
end;

{ TMessengerFixedWindowRateLimiter }

class function TMessengerFixedWindowRateLimiter.MonotonicMs: Int64;
begin
  Result := (TStopwatch.GetTimeStamp * Int64(1000)) div TStopwatch.Frequency;
end;

constructor TMessengerFixedWindowRateLimiter.Create(ALimit: Integer;
  AWindowMs: Cardinal; AShardCount: Integer);
var
  I: Integer;
begin
  inherited Create;
  if ALimit <= 0 then raise EArgumentOutOfRangeException.Create('ALimit');
  if AWindowMs = 0 then raise EArgumentOutOfRangeException.Create('AWindowMs');
  if AShardCount <= 0 then raise EArgumentOutOfRangeException.Create('AShardCount');

  FLimit := ALimit;
  FWindowMs := AWindowMs;
  FShardCount := AShardCount;
  FShards := TObjectList<TRateShard>.Create(True);
  for I := 0 to FShardCount - 1 do
    FShards.Add(TRateShard.Create);
end;

destructor TMessengerFixedWindowRateLimiter.Destroy;
begin
  FShards.Free;
  inherited;
end;

function TMessengerFixedWindowRateLimiter.KeyOf(const AUserId,
  AOperation: string): string;
begin
  if AUserId = '' then raise EArgumentException.Create('user_id must not be empty');
  if AOperation = '' then raise EArgumentException.Create('operation must not be empty');
  Result := AUserId + #31 + AOperation;
end;

function TMessengerFixedWindowRateLimiter.ShardFor(
  const AKey: string): TRateShard;
var
  Index: Integer;
begin
  Index := Integer(TMessengerPartitioner.StableHash32(AKey) mod UInt32(FShardCount));
  Result := FShards[Index];
end;

function TMessengerFixedWindowRateLimiter.TryAcquire(const AUserId,
  AOperation: string): Boolean;
var
  K: string;
  Shard: TRateShard;
  Bucket: TRateBucket;
  NowMs: Int64;
begin
  K := KeyOf(AUserId, AOperation);
  Shard := ShardFor(K);
  NowMs := MonotonicMs;

  Shard.Lock.Enter;
  try
    if not Shard.Buckets.TryGetValue(K, Bucket) then
    begin
      Bucket.WindowStartedMs := NowMs;
      Bucket.Count := 0;
    end
    else if NowMs - Bucket.WindowStartedMs >= FWindowMs then
    begin
      Bucket.WindowStartedMs := NowMs;
      Bucket.Count := 0;
    end;

    if Bucket.Count >= FLimit then
      Exit(False);

    Inc(Bucket.Count);
    Shard.Buckets.AddOrSetValue(K, Bucket);
    Result := True;
  finally
    Shard.Lock.Leave;
  end;
end;

{ TMessengerGatewayCommandFactory }

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
