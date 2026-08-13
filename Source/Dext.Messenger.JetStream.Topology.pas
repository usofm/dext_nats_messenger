unit Dext.Messenger.JetStream.Topology;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream;

type
  TMessengerJetStreamTopology = record
  public const
    AcceptedMessagesStream = 'MESSENGER_ACCEPTED_V1';
    DefaultPartitionCount = 64;
    DefaultReplicas = 3;
  public
    class function AcceptedMessagesConfig(
      ANumReplicas: Integer = DefaultReplicas
    ): TNatsStreamConfig; static;

    class function EnsureAcceptedMessagesStream(
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

  { Keep accepted events long enough for operational replay/recovery. The
    searchable long-term message history belongs to the persistence database. }
  Result.MaxAge := Int64(7) * 24 * 60 * 60 * NS_PER_SECOND;

  { JetStream Nats-Msg-Id dedup is a transport safety net, not the permanent
    product idempotency store. Keep the window comfortably above normal client
    reconnect/retry intervals. }
  Result.DuplicateWindow := Int64(10) * 60 * NS_PER_SECOND;
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

end.
