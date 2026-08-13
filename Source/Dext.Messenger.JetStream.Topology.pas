unit Dext.Messenger.JetStream.Topology;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream;

type
  TMessengerJetStreamTopology = record
  public const
    AcceptedMessagesStream = 'MESSENGER_ACCEPTED_V1';
    DeliveryDeadLetterStream = 'MESSENGER_DELIVERY_DLQ_V1';
    DefaultPartitionCount = 64;
    DefaultReplicas = 3;
  public
    class function AcceptedMessagesConfig(
      ANumReplicas: Integer = DefaultReplicas
    ): TNatsStreamConfig; static;
    class function DeliveryDeadLetterConfig(
      ANumReplicas: Integer = DefaultReplicas
    ): TNatsStreamConfig; static;

    class function EnsureAcceptedMessagesStream(
      AJetStream: TDextNatsJetStreamContext;
      ANumReplicas: Integer = DefaultReplicas
    ): TNatsStreamInfo; static;
    class function EnsureDeliveryDeadLetterStream(
      AJetStream: TDextNatsJetStreamContext;
      ANumReplicas: Integer = DefaultReplicas
    ): TNatsStreamInfo; static;
  end;

implementation

uses
  Dext.Messenger.Subjects;

const
  NS_PER_SECOND: Int64 = 1000000000;

class function TMessengerJetStreamTopology.AcceptedMessagesConfig(
  ANumReplicas: Integer
): TNatsStreamConfig;
begin
  if ANumReplicas <= 0 then
    raise EArgumentOutOfRangeException.Create('ANumReplicas');

  Result := TNatsStreamConfig.CreateDefault(
    AcceptedMessagesStream,
    [TMessengerSubjects.AcceptedMessageWildcard]
  );
  Result.Description := 'Dext Messenger v1 accepted message durable pipeline';
  Result.Retention := srLimits;
  Result.Storage := ssFile;
  Result.NumReplicas := ANumReplicas;
  Result.MaxAge := Int64(7) * 24 * 60 * 60 * NS_PER_SECOND;
  Result.DuplicateWindow := Int64(10) * 60 * NS_PER_SECOND;
end;

class function TMessengerJetStreamTopology.DeliveryDeadLetterConfig(
  ANumReplicas: Integer): TNatsStreamConfig;
begin
  if ANumReplicas <= 0 then
    raise EArgumentOutOfRangeException.Create('ANumReplicas');

  Result := TNatsStreamConfig.CreateDefault(
    DeliveryDeadLetterStream,
    [TMessengerSubjects.DeliveryDeadLetterWildcard]
  );
  Result.Description := 'Dext Messenger v1 delivery poison/dead-letter events';
  Result.Retention := srLimits;
  Result.Storage := ssFile;
  Result.NumReplicas := ANumReplicas;
  { DLQ is operational evidence; retain longer than transient accepted events. }
  Result.MaxAge := Int64(30) * 24 * 60 * 60 * NS_PER_SECOND;
  Result.DuplicateWindow := Int64(60) * 60 * NS_PER_SECOND;
end;

class function TMessengerJetStreamTopology.EnsureAcceptedMessagesStream(
  AJetStream: TDextNatsJetStreamContext;
  ANumReplicas: Integer
): TNatsStreamInfo;
var
  Config: TNatsStreamConfig;
begin
  if not Assigned(AJetStream) then
    raise EArgumentNilException.Create('AJetStream');

  Config := AcceptedMessagesConfig(ANumReplicas);
  if AJetStream.StreamExists(AcceptedMessagesStream) then
    Result := AJetStream.GetStreamInfo(AcceptedMessagesStream)
  else
    Result := AJetStream.CreateStream(Config);
end;

class function TMessengerJetStreamTopology.EnsureDeliveryDeadLetterStream(
  AJetStream: TDextNatsJetStreamContext;
  ANumReplicas: Integer): TNatsStreamInfo;
var
  Config: TNatsStreamConfig;
begin
  if not Assigned(AJetStream) then
    raise EArgumentNilException.Create('AJetStream');

  Config := DeliveryDeadLetterConfig(ANumReplicas);
  if AJetStream.StreamExists(DeliveryDeadLetterStream) then
    Result := AJetStream.GetStreamInfo(DeliveryDeadLetterStream)
  else
    Result := AJetStream.CreateStream(Config);
end;

end.
