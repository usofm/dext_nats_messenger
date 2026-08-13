unit Dext.Messenger.Outbox;

interface

uses
  System.SysUtils,
  Dext.Messenger.Commands;

type
  TMessengerOutboxItem = record
  public
    OutboxId: string;
    Accepted: TMessengerAcceptedMessage;
    AttemptCount: Integer;
    AvailableAtUnixMs: Int64;
    LeaseOwner: string;
    LeaseUntilUnixMs: Int64;

    class function Create(const AOutboxId: string;
      const AAccepted: TMessengerAcceptedMessage;
      AAvailableAtUnixMs: Int64): TMessengerOutboxItem; static;
  end;

  IMessengerOutboxStore = interface
    ['{88815622-8A71-4A24-A36B-0BD4EA1B853E}']
    function ClaimBatch(const AWorkerId: string; ANowUnixMs, ALeaseMs: Int64;
      AMaxItems: Integer): TArray<TMessengerOutboxItem>;
    procedure MarkPublished(const AOutboxId, AWorkerId: string);
    procedure ReleaseForRetry(const AOutboxId, AWorkerId: string;
      AAvailableAtUnixMs: Int64; const AError: string);
  end;

  IMessengerAcceptedPublisher = interface
    ['{20E9CA8C-683B-4CD1-A174-DFA81CC5D78E}']
    procedure PublishAccepted(const AAccepted: TMessengerAcceptedMessage);
  end;

  TMessengerOutboxDispatchStats = record
    Claimed: Integer;
    Published: Integer;
    Failed: Integer;
  end;

  TMessengerOutboxDispatcher = class
  private
    FStore: IMessengerOutboxStore;
    FPublisher: IMessengerAcceptedPublisher;
    FWorkerId: string;
    FLeaseMs: Int64;
    FBaseRetryMs: Int64;
    FMaxRetryMs: Int64;
    function RetryDelayMs(AAttempt: Integer): Int64;
  public
    constructor Create(const AStore: IMessengerOutboxStore;
      const APublisher: IMessengerAcceptedPublisher;
      const AWorkerId: string;
      ALeaseMs: Int64 = 30000;
      ABaseRetryMs: Int64 = 1000;
      AMaxRetryMs: Int64 = 60000);

    function ProcessBatch(ANowUnixMs: Int64;
      AMaxItems: Integer = 100): TMessengerOutboxDispatchStats;
  end;

implementation

class function TMessengerOutboxItem.Create(const AOutboxId: string;
  const AAccepted: TMessengerAcceptedMessage;
  AAvailableAtUnixMs: Int64): TMessengerOutboxItem;
begin
  if AOutboxId = '' then raise EArgumentException.Create('outbox_id must not be empty');
  if not AAccepted.IsCanonical then
    raise EArgumentException.Create('outbox accepted message must be canonical');
  if AAvailableAtUnixMs < 0 then
    raise EArgumentOutOfRangeException.Create('AAvailableAtUnixMs');

  Result := Default(TMessengerOutboxItem);
  Result.OutboxId := AOutboxId;
  Result.Accepted := AAccepted;
  Result.AvailableAtUnixMs := AAvailableAtUnixMs;
end;

constructor TMessengerOutboxDispatcher.Create(const AStore: IMessengerOutboxStore;
  const APublisher: IMessengerAcceptedPublisher; const AWorkerId: string;
  ALeaseMs, ABaseRetryMs, AMaxRetryMs: Int64);
begin
  inherited Create;
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  if APublisher = nil then raise EArgumentNilException.Create('APublisher');
  if AWorkerId = '' then raise EArgumentException.Create('worker_id must not be empty');
  if ALeaseMs <= 0 then raise EArgumentOutOfRangeException.Create('ALeaseMs');
  if ABaseRetryMs <= 0 then raise EArgumentOutOfRangeException.Create('ABaseRetryMs');
  if AMaxRetryMs < ABaseRetryMs then raise EArgumentOutOfRangeException.Create('AMaxRetryMs');

  FStore := AStore;
  FPublisher := APublisher;
  FWorkerId := AWorkerId;
  FLeaseMs := ALeaseMs;
  FBaseRetryMs := ABaseRetryMs;
  FMaxRetryMs := AMaxRetryMs;
end;

function TMessengerOutboxDispatcher.RetryDelayMs(AAttempt: Integer): Int64;
var
  I: Integer;
  Delay: Int64;
begin
  Delay := FBaseRetryMs;
  for I := 1 to AAttempt - 1 do
  begin
    if Delay >= FMaxRetryMs div 2 then
      Exit(FMaxRetryMs);
    Delay := Delay * 2;
  end;
  if Delay > FMaxRetryMs then Delay := FMaxRetryMs;
  Result := Delay;
end;

function TMessengerOutboxDispatcher.ProcessBatch(ANowUnixMs: Int64;
  AMaxItems: Integer): TMessengerOutboxDispatchStats;
var
  Items: TArray<TMessengerOutboxItem>;
  Item: TMessengerOutboxItem;
  Err: string;
  Delay: Int64;
begin
  Result := Default(TMessengerOutboxDispatchStats);
  if ANowUnixMs <= 0 then raise EArgumentOutOfRangeException.Create('ANowUnixMs');
  if AMaxItems <= 0 then raise EArgumentOutOfRangeException.Create('AMaxItems');

  Items := FStore.ClaimBatch(FWorkerId, ANowUnixMs, FLeaseMs, AMaxItems);
  Result.Claimed := Length(Items);

  for Item in Items do
  begin
    try
      FPublisher.PublishAccepted(Item.Accepted);
      FStore.MarkPublished(Item.OutboxId, FWorkerId);
      Inc(Result.Published);
    except
      on E: Exception do
      begin
        Inc(Result.Failed);
        Err := E.ClassName + ': ' + E.Message;
        Delay := RetryDelayMs(Item.AttemptCount + 1);
        FStore.ReleaseForRetry(Item.OutboxId, FWorkerId,
          ANowUnixMs + Delay, Err);
      end;
    end;
  end;
end;

end.
