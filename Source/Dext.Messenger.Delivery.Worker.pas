unit Dext.Messenger.Delivery.Worker;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream,
  Dext.Messenger.Delivery;

type
  TMessengerDeliveryWorkerOptions = record
  public
    BatchSize: Integer;
    FetchExpiresMs: Integer;
    AckWaitMs: Integer;
    MaxDeliver: Integer;
    MaxAckPending: Integer;
    MaxWaiting: Integer;
    class function Default: TMessengerDeliveryWorkerOptions; static;
    procedure Validate;
  end;

  TMessengerDeliveryWorker = class
  public const
    DurableConsumerName = 'MESSENGER_DELIVERY_V1';
  private
    FJetStream: TDextNatsJetStreamContext;
    FProcessor: TMessengerJetStreamDeliveryProcessor;
    FOptions: TMessengerDeliveryWorkerOptions;
  public
    constructor Create(AJetStream: TDextNatsJetStreamContext;
      AProcessor: TMessengerJetStreamDeliveryProcessor;
      const AOptions: TMessengerDeliveryWorkerOptions);

    function EnsureConsumer: TNatsConsumerInfo;
    function ProcessOnce: Integer;
  end;

implementation

uses
  Dext.Collections,
  Dext.Messenger.Subjects,
  Dext.Messenger.JetStream.Topology;

const
  NS_PER_MS: Int64 = 1000000;

class function TMessengerDeliveryWorkerOptions.Default:
  TMessengerDeliveryWorkerOptions;
begin
  Result := System.Default(TMessengerDeliveryWorkerOptions);
  Result.BatchSize := 128;
  Result.FetchExpiresMs := 2000;
  Result.AckWaitMs := 30000;
  Result.MaxDeliver := 10;
  Result.MaxAckPending := 20000;
  Result.MaxWaiting := 512;
end;

procedure TMessengerDeliveryWorkerOptions.Validate;
begin
  if BatchSize <= 0 then raise EArgumentOutOfRangeException.Create('BatchSize');
  if FetchExpiresMs <= 0 then raise EArgumentOutOfRangeException.Create('FetchExpiresMs');
  if AckWaitMs <= 0 then raise EArgumentOutOfRangeException.Create('AckWaitMs');
  if MaxDeliver <= 0 then raise EArgumentOutOfRangeException.Create('MaxDeliver');
  if MaxAckPending <= 0 then raise EArgumentOutOfRangeException.Create('MaxAckPending');
  if MaxWaiting <= 0 then raise EArgumentOutOfRangeException.Create('MaxWaiting');
end;

constructor TMessengerDeliveryWorker.Create(
  AJetStream: TDextNatsJetStreamContext;
  AProcessor: TMessengerJetStreamDeliveryProcessor;
  const AOptions: TMessengerDeliveryWorkerOptions);
begin
  inherited Create;
  if not Assigned(AJetStream) then raise EArgumentNilException.Create('AJetStream');
  if not Assigned(AProcessor) then raise EArgumentNilException.Create('AProcessor');
  AOptions.Validate;
  FJetStream := AJetStream;
  FProcessor := AProcessor;
  FOptions := AOptions;
end;

function TMessengerDeliveryWorker.EnsureConsumer: TNatsConsumerInfo;
var
  Config: TNatsConsumerConfig;
begin
  Config := TNatsConsumerConfig.CreateDefault(
    DurableConsumerName,
    TMessengerSubjects.AcceptedMessageWildcard);
  Config.Description := 'Dext Messenger horizontally scalable online delivery workers';
  Config.DeliverPolicy := dpAll;
  Config.AckPolicy := apExplicit;
  Config.AckWait := Int64(FOptions.AckWaitMs) * NS_PER_MS;
  Config.MaxDeliver := FOptions.MaxDeliver;
  Config.MaxAckPending := FOptions.MaxAckPending;
  Config.MaxWaiting := FOptions.MaxWaiting;

  { NATS durable consumer creation is idempotent when the existing durable has
    the same configuration; incompatible drift is surfaced instead of silently
    mutating delivery semantics. }
  Result := FJetStream.CreateConsumer(
    TMessengerJetStreamTopology.AcceptedMessagesStream, Config);
end;

function TMessengerDeliveryWorker.ProcessOnce: Integer;
var
  Messages: IList<TNatsJsMsg>;
  I: Integer;
begin
  Messages := FJetStream.Fetch(
    TMessengerJetStreamTopology.AcceptedMessagesStream,
    DurableConsumerName,
    FOptions.BatchSize,
    FOptions.FetchExpiresMs);

  Result := Messages.Count;
  for I := 0 to Messages.Count - 1 do
    FProcessor.Process(Messages[I]);
end;

end.
