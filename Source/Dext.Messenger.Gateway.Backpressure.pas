unit Dext.Messenger.Gateway.Backpressure;

interface

uses
  System.SysUtils,
  System.SyncObjs;

type
  TMessengerBackpressureDecision = (
    mbdAccept,
    mbdRejectTransient,
    mbdDisconnectSlowConsumer
  );

  TMessengerOutboundQueueLimits = record
  public
    MaxMessages: Integer;
    MaxBytes: Int64;
    DisconnectAtPercent: Integer;
    class function Default: TMessengerOutboundQueueLimits; static;
    procedure Validate;
  end;

  { Lightweight accounting guard to be placed in front of a concrete socket/
    Hub send queue. It intentionally does not own messages. Call Reserve before
    enqueue and Release exactly once when bytes leave/drop from the queue. }
  TMessengerOutboundQueueGuard = class
  private
    FLock: TCriticalSection;
    FLimits: TMessengerOutboundQueueLimits;
    FMessages: Integer;
    FBytes: Int64;
  public
    constructor Create(const ALimits: TMessengerOutboundQueueLimits);
    destructor Destroy; override;
    function Reserve(AMessageBytes: Integer): TMessengerBackpressureDecision;
    procedure Release(AMessageBytes: Integer);
    function MessageCount: Integer;
    function ByteCount: Int64;
  end;

implementation

class function TMessengerOutboundQueueLimits.Default:
  TMessengerOutboundQueueLimits;
begin
  Result := Default(TMessengerOutboundQueueLimits);
  Result.MaxMessages := 1024;
  Result.MaxBytes := Int64(8) * 1024 * 1024;
  Result.DisconnectAtPercent := 90;
end;

procedure TMessengerOutboundQueueLimits.Validate;
begin
  if MaxMessages <= 0 then raise EArgumentOutOfRangeException.Create('MaxMessages');
  if MaxBytes <= 0 then raise EArgumentOutOfRangeException.Create('MaxBytes');
  if (DisconnectAtPercent < 50) or (DisconnectAtPercent > 100) then
    raise EArgumentOutOfRangeException.Create('DisconnectAtPercent');
end;

constructor TMessengerOutboundQueueGuard.Create(
  const ALimits: TMessengerOutboundQueueLimits);
begin
  inherited Create;
  ALimits.Validate;
  FLimits := ALimits;
  FLock := TCriticalSection.Create;
end;

destructor TMessengerOutboundQueueGuard.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMessengerOutboundQueueGuard.Reserve(
  AMessageBytes: Integer): TMessengerBackpressureDecision;
var
  NextMessages: Integer;
  NextBytes: Int64;
  PercentMessages, PercentBytes: Int64;
begin
  if AMessageBytes <= 0 then
    raise EArgumentOutOfRangeException.Create('AMessageBytes');

  FLock.Enter;
  try
    NextMessages := FMessages + 1;
    NextBytes := FBytes + AMessageBytes;

    if (NextMessages > FLimits.MaxMessages) or (NextBytes > FLimits.MaxBytes) then
      Exit(mbdDisconnectSlowConsumer);

    PercentMessages := (Int64(NextMessages) * 100) div FLimits.MaxMessages;
    PercentBytes := (NextBytes * 100) div FLimits.MaxBytes;
    if (PercentMessages >= FLimits.DisconnectAtPercent) or
       (PercentBytes >= FLimits.DisconnectAtPercent) then
      Exit(mbdRejectTransient);

    FMessages := NextMessages;
    FBytes := NextBytes;
    Result := mbdAccept;
  finally
    FLock.Leave;
  end;
end;

procedure TMessengerOutboundQueueGuard.Release(AMessageBytes: Integer);
begin
  if AMessageBytes <= 0 then Exit;
  FLock.Enter;
  try
    if FMessages > 0 then Dec(FMessages);
    FBytes := FBytes - AMessageBytes;
    if FBytes < 0 then FBytes := 0;
  finally
    FLock.Leave;
  end;
end;

function TMessengerOutboundQueueGuard.MessageCount: Integer;
begin
  FLock.Enter;
  try Result := FMessages; finally FLock.Leave; end;
end;

function TMessengerOutboundQueueGuard.ByteCount: Int64;
begin
  FLock.Enter;
  try Result := FBytes; finally FLock.Leave; end;
end;

end.
