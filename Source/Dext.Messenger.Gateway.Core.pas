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
    DestinationKind: TMessengerDestinationKind;
    DestinationId: string;
    Kind: TMessengerMessageKind;
    PayloadJson: string;

    class function Direct(const AClientMessageId, AConversationId,
      ATargetUserId: string; AKind: TMessengerMessageKind;
      const APayloadJson: string): TMessengerClientSend; static;
    class function Group(const AClientMessageId, AConversationId,
      AGroupId: string; AKind: TMessengerMessageKind;
      const APayloadJson: string): TMessengerClientSend; static;
  end;

  IMessengerGatewayRateLimiter = interface
    ['{7297A5B5-278A-4BD2-A13A-4AE1B4531097}']
    function TryAcquire(const AUserId, AOperation: string): Boolean;
  end;

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
      LastSweepMs: Int64;
      constructor Create;
      destructor Destroy; override;
    end;
  private
    FShards: TObjectList<TRateShard>;
    FLimit: Integer;
    FWindowMs: Cardinal;
    FShardCount: Integer;
    FIdleRetentionMs: Int64;
    class function MonotonicMs: Int64; static;
    function KeyOf(const AUserId, AOperation: string): string;
    function ShardFor(const AKey: string): TRateShard;
    procedure SweepStaleBuckets(AShard: TRateShard; ANowMs: Int64);
  public
    constructor Create(ALimit: Integer; AWindowMs: Cardinal = 1000;
      AShardCount: Integer = 64; AIdleRetentionWindows: Integer = 10);
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

class function TMessengerClientSend.Direct(const AClientMessageId,
  AConversationId, ATargetUserId: string; AKind: TMessengerMessageKind;
  const APayloadJson: string): TMessengerClientSend;
begin
  Result := Default(TMessengerClientSend);
  Result.ClientMessageId := AClientMessageId;
  Result.ConversationId := AConversationId;
  Result.DestinationKind := mdkUser;
  Result.DestinationId := ATargetUserId;
  Result.Kind := AKind;
  Result.PayloadJson := APayloadJson;
end;

class function TMessengerClientSend.Group(const AClientMessageId,
  AConversationId, AGroupId: string; AKind: TMessengerMessageKind;
  const APayloadJson: string): TMessengerClientSend;
begin
  Result := Default(TMessengerClientSend);
  Result.ClientMessageId := AClientMessageId;
  Result.ConversationId := AConversationId;
  Result.DestinationKind := mdkGroup;
  Result.DestinationId := AGroupId;
  Result.Kind := AKind;
  Result.PayloadJson := APayloadJson;
end;

constructor TMessengerFixedWindowRateLimiter.TRateShard.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  Buckets := TDictionary<string, TRateBucket>.Create;
  LastSweepMs := 0;
end;

destructor TMessengerFixedWindowRateLimiter.TRateShard.Destroy;
begin
  Buckets.Free;
  Lock.Free;
  inherited;
end;

class function TMessengerFixedWindowRateLimiter.MonotonicMs: Int64;
begin
  Result := (TStopwatch.GetTimeStamp * Int64(1000)) div TStopwatch.Frequency;
end;

constructor TMessengerFixedWindowRateLimiter.Create(ALimit: Integer;
  AWindowMs: Cardinal; AShardCount, AIdleRetentionWindows: Integer);
var
  I: Integer;
begin
  inherited Create;
  if ALimit <= 0 then raise EArgumentOutOfRangeException.Create('ALimit');
  if AWindowMs = 0 then raise EArgumentOutOfRangeException.Create('AWindowMs');
  if AShardCount <= 0 then raise EArgumentOutOfRangeException.Create('AShardCount');
  if AIdleRetentionWindows < 2 then
    raise EArgumentOutOfRangeException.Create('AIdleRetentionWindows');

  FLimit := ALimit;
  FWindowMs := AWindowMs;
  FShardCount := AShardCount;
  FIdleRetentionMs := Int64(AWindowMs) * AIdleRetentionWindows;
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

procedure TMessengerFixedWindowRateLimiter.SweepStaleBuckets(
  AShard: TRateShard; ANowMs: Int64);
var
  Pair: TPair<string, TRateBucket>;
  Stale: TList<string>;
  K: string;
begin
  if (AShard.LastSweepMs <> 0) and
     (ANowMs - AShard.LastSweepMs < FIdleRetentionMs) then
    Exit;

  Stale := TList<string>.Create;
  try
    for Pair in AShard.Buckets do
      if ANowMs - Pair.Value.WindowStartedMs >= FIdleRetentionMs then
        Stale.Add(Pair.Key);
    for K in Stale do
      AShard.Buckets.Remove(K);
    AShard.LastSweepMs := ANowMs;
  finally
    Stale.Free;
  end;
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
    SweepStaleBuckets(Shard, NowMs);
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
  if AClientSend.DestinationId = '' then raise EMessengerGatewayError.Create('destination_id is required');

  case AClientSend.DestinationKind of
    mdkUser:
      Result := TMessengerAcceptMessageCommand.CreateDirect(
        AClientSend.ClientMessageId, AClientSend.ConversationId,
        ASession.UserId, AClientSend.DestinationId,
        AClientSend.Kind, AClientSend.PayloadJson);
    mdkGroup:
      Result := TMessengerAcceptMessageCommand.CreateGroup(
        AClientSend.ClientMessageId, AClientSend.ConversationId,
        ASession.UserId, AClientSend.DestinationId,
        AClientSend.Kind, AClientSend.PayloadJson);
  else
    raise EMessengerGatewayError.Create('Unsupported destination kind');
  end;
end;

end.
