unit Dext.Messenger.Monitoring;

interface

uses
  System.SysUtils,
  System.SyncObjs;

type
  TMessengerMetricsSnapshot = record
  public
    Accepted: Int64;
    Duplicates: Int64;
    Rejected: Int64;
    OutboxPublished: Int64;
    OutboxFailed: Int64;
    OnlineDelivered: Int64;
    DeliveryRetried: Int64;
    DeadLettered: Int64;
    ActiveConnections: Int64;
  end;

  TMessengerMetrics = class
  private
    FAccepted: Int64;
    FDuplicates: Int64;
    FRejected: Int64;
    FOutboxPublished: Int64;
    FOutboxFailed: Int64;
    FOnlineDelivered: Int64;
    FDeliveryRetried: Int64;
    FDeadLettered: Int64;
    FActiveConnections: Int64;
  public
    procedure IncAccepted;
    procedure IncDuplicate;
    procedure IncRejected;
    procedure IncOutboxPublished;
    procedure IncOutboxFailed;
    procedure IncOnlineDelivered;
    procedure IncDeliveryRetried;
    procedure IncDeadLettered;
    procedure ConnectionOpened;
    procedure ConnectionClosed;
    function Snapshot: TMessengerMetricsSnapshot;
  end;

  TMessengerHealthState = (mhsHealthy, mhsDegraded, mhsUnhealthy);

  TMessengerHealthSnapshot = record
  public
    State: TMessengerHealthState;
    NatsConnected: Boolean;
    DatabaseReachable: Boolean;
    OutboxBacklog: Int64;
    DeadLetterBacklog: Int64;
    Description: string;
  end;

  IMessengerInfrastructureProbe = interface
    ['{72ED3588-1BD6-41D8-B2A3-8B25C135CA60}']
    function IsNatsConnected: Boolean;
    function IsDatabaseReachable: Boolean;
    function OutboxBacklog: Int64;
    function DeadLetterBacklog: Int64;
  end;

  TMessengerHealthEvaluator = class
  private
    FProbe: IMessengerInfrastructureProbe;
    FOutboxDegradedThreshold: Int64;
    FOutboxUnhealthyThreshold: Int64;
  public
    constructor Create(const AProbe: IMessengerInfrastructureProbe;
      AOutboxDegradedThreshold: Int64 = 10000;
      AOutboxUnhealthyThreshold: Int64 = 100000);
    function Evaluate: TMessengerHealthSnapshot;
  end;

implementation

procedure TMessengerMetrics.IncAccepted;
begin TInterlocked.Increment(FAccepted); end;
procedure TMessengerMetrics.IncDuplicate;
begin TInterlocked.Increment(FDuplicates); end;
procedure TMessengerMetrics.IncRejected;
begin TInterlocked.Increment(FRejected); end;
procedure TMessengerMetrics.IncOutboxPublished;
begin TInterlocked.Increment(FOutboxPublished); end;
procedure TMessengerMetrics.IncOutboxFailed;
begin TInterlocked.Increment(FOutboxFailed); end;
procedure TMessengerMetrics.IncOnlineDelivered;
begin TInterlocked.Increment(FOnlineDelivered); end;
procedure TMessengerMetrics.IncDeliveryRetried;
begin TInterlocked.Increment(FDeliveryRetried); end;
procedure TMessengerMetrics.IncDeadLettered;
begin TInterlocked.Increment(FDeadLettered); end;
procedure TMessengerMetrics.ConnectionOpened;
begin TInterlocked.Increment(FActiveConnections); end;
procedure TMessengerMetrics.ConnectionClosed;
begin
  if TInterlocked.Decrement(FActiveConnections) < 0 then
    TInterlocked.Exchange(FActiveConnections, 0);
end;

function TMessengerMetrics.Snapshot: TMessengerMetricsSnapshot;
begin
  Result := Default(TMessengerMetricsSnapshot);
  Result.Accepted := TInterlocked.Read(FAccepted);
  Result.Duplicates := TInterlocked.Read(FDuplicates);
  Result.Rejected := TInterlocked.Read(FRejected);
  Result.OutboxPublished := TInterlocked.Read(FOutboxPublished);
  Result.OutboxFailed := TInterlocked.Read(FOutboxFailed);
  Result.OnlineDelivered := TInterlocked.Read(FOnlineDelivered);
  Result.DeliveryRetried := TInterlocked.Read(FDeliveryRetried);
  Result.DeadLettered := TInterlocked.Read(FDeadLettered);
  Result.ActiveConnections := TInterlocked.Read(FActiveConnections);
end;

constructor TMessengerHealthEvaluator.Create(
  const AProbe: IMessengerInfrastructureProbe;
  AOutboxDegradedThreshold, AOutboxUnhealthyThreshold: Int64);
begin
  inherited Create;
  if AProbe = nil then raise EArgumentNilException.Create('AProbe');
  if AOutboxDegradedThreshold < 0 then
    raise EArgumentOutOfRangeException.Create('AOutboxDegradedThreshold');
  if AOutboxUnhealthyThreshold <= AOutboxDegradedThreshold then
    raise EArgumentOutOfRangeException.Create('AOutboxUnhealthyThreshold');
  FProbe := AProbe;
  FOutboxDegradedThreshold := AOutboxDegradedThreshold;
  FOutboxUnhealthyThreshold := AOutboxUnhealthyThreshold;
end;

function TMessengerHealthEvaluator.Evaluate: TMessengerHealthSnapshot;
begin
  Result := Default(TMessengerHealthSnapshot);
  Result.NatsConnected := FProbe.IsNatsConnected;
  Result.DatabaseReachable := FProbe.IsDatabaseReachable;
  Result.OutboxBacklog := FProbe.OutboxBacklog;
  Result.DeadLetterBacklog := FProbe.DeadLetterBacklog;

  if not Result.DatabaseReachable then
  begin
    Result.State := mhsUnhealthy;
    Result.Description := 'Database is unreachable';
    Exit;
  end;

  if Result.OutboxBacklog >= FOutboxUnhealthyThreshold then
  begin
    Result.State := mhsUnhealthy;
    Result.Description := 'Outbox backlog exceeded unhealthy threshold';
    Exit;
  end;

  if (not Result.NatsConnected) or
     (Result.OutboxBacklog >= FOutboxDegradedThreshold) or
     (Result.DeadLetterBacklog > 0) then
  begin
    Result.State := mhsDegraded;
    if not Result.NatsConnected then
      Result.Description := 'NATS is disconnected; durable DB acceptance may continue'
    else if Result.DeadLetterBacklog > 0 then
      Result.Description := 'Dead-letter backlog requires investigation'
    else
      Result.Description := 'Outbox backlog is elevated';
    Exit;
  end;

  Result.State := mhsHealthy;
  Result.Description := 'Messenger dependencies are healthy';
end;

end.
