unit Dext.Messenger.Workers;

interface

uses
  System.SysUtils,
  System.Classes,
  Dext.Messenger.Outbox,
  Dext.Messenger.Delivery.Worker;

type
  TMessengerWorkerLoopOptions = record
  public
    IdleSleepMs: Integer;
    OutboxBatchSize: Integer;
    class function Default: TMessengerWorkerLoopOptions; static;
    procedure Validate;
  end;

  TMessengerShouldStop = reference to function: Boolean;

  TMessengerWorkerRuntime = class
  private
    FOutbox: TMessengerOutboxDispatcher;
    FDelivery: TMessengerDeliveryWorker;
    FOptions: TMessengerWorkerLoopOptions;
    class function UnixMsNow: Int64; static;
  public
    constructor Create(AOutbox: TMessengerOutboxDispatcher;
      ADelivery: TMessengerDeliveryWorker;
      const AOptions: TMessengerWorkerLoopOptions);
    procedure Initialize;
    function ProcessOnce: Integer;
    procedure Run(const AShouldStop: TMessengerShouldStop);
  end;

implementation

uses
  System.DateUtils;

class function TMessengerWorkerLoopOptions.Default: TMessengerWorkerLoopOptions;
begin
  Result := System.Default(TMessengerWorkerLoopOptions);
  Result.IdleSleepMs := 25;
  Result.OutboxBatchSize := 100;
end;

procedure TMessengerWorkerLoopOptions.Validate;
begin
  if IdleSleepMs < 1 then raise EArgumentOutOfRangeException.Create('IdleSleepMs');
  if OutboxBatchSize < 1 then raise EArgumentOutOfRangeException.Create('OutboxBatchSize');
end;

constructor TMessengerWorkerRuntime.Create(AOutbox: TMessengerOutboxDispatcher;
  ADelivery: TMessengerDeliveryWorker;
  const AOptions: TMessengerWorkerLoopOptions);
begin
  inherited Create;
  if not Assigned(AOutbox) then raise EArgumentNilException.Create('AOutbox');
  if not Assigned(ADelivery) then raise EArgumentNilException.Create('ADelivery');
  AOptions.Validate;
  FOutbox := AOutbox;
  FDelivery := ADelivery;
  FOptions := AOptions;
end;

class function TMessengerWorkerRuntime.UnixMsNow: Int64;
var
  Utc: TDateTime;
begin
  Utc := TTimeZone.Local.ToUniversalTime(Now);
  Result := DateTimeToUnix(Utc, False) * Int64(1000) + MilliSecondOf(Utc);
end;

procedure TMessengerWorkerRuntime.Initialize;
begin
  FDelivery.EnsureConsumer;
end;

function TMessengerWorkerRuntime.ProcessOnce: Integer;
var
  OutboxStats: TMessengerOutboxDispatchStats;
begin
  OutboxStats := FOutbox.ProcessBatch(UnixMsNow, FOptions.OutboxBatchSize);
  Result := OutboxStats.PublishedCount + FDelivery.ProcessOnce;
end;

procedure TMessengerWorkerRuntime.Run(const AShouldStop: TMessengerShouldStop);
var
  WorkCount: Integer;
begin
  if not Assigned(AShouldStop) then
    raise EArgumentNilException.Create('AShouldStop');
  Initialize;
  while not AShouldStop() do
  begin
    WorkCount := ProcessOnce;
    if WorkCount = 0 then
      TThread.Sleep(FOptions.IdleSleepMs);
  end;
end;

end.
