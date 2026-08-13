unit Dext.Messenger.JetStream.AcceptedSink;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream,
  Dext.Messenger.Outbox,
  Dext.Messenger.Commands;

type
  TMessengerJetStreamAcceptedSink = class(TInterfacedObject, IMessengerAcceptedPublisher)
  private
    FJetStream: TDextNatsJetStreamContext;
  public
    constructor Create(AJetStream: TDextNatsJetStreamContext);
    procedure PublishAccepted(const AAccepted: TMessengerAcceptedMessage);
  end;

implementation

uses
  Dext.Net.Nats.Protocol,
  Dext.Messenger.Codec.Json,
  Dext.Messenger.Subjects,
  Dext.Messenger.JetStream.Topology;

const
  HDR_DESTINATION_KIND = 'X-Messenger-Destination-Kind';
  HDR_DESTINATION_ID = 'X-Messenger-Destination-Id';
  HDR_CONVERSATION = 'X-Messenger-Conversation';
  HDR_PARTITION = 'X-Messenger-Partition';
  HDR_SEQUENCE = 'X-Messenger-Sequence';
  HDR_EVENT_TYPE = 'X-Messenger-Event-Type';

function DestinationKindText(AKind: TMessengerDestinationKind): string;
begin
  case AKind of
    mdkUser: Result := 'user';
    mdkGroup: Result := 'group';
  else
    raise EArgumentOutOfRangeException.Create('destination kind');
  end;
end;

constructor TMessengerJetStreamAcceptedSink.Create(
  AJetStream: TDextNatsJetStreamContext);
begin
  inherited Create;
  if not Assigned(AJetStream) then
    raise EArgumentNilException.Create('AJetStream');
  FJetStream := AJetStream;
end;

procedure TMessengerJetStreamAcceptedSink.PublishAccepted(
  const AAccepted: TMessengerAcceptedMessage);
var
  Subject: string;
  Payload: TBytes;
  Options: TNatsJetStreamPublishOptions;
begin
  if not AAccepted.IsCanonical then
    raise EArgumentException.Create('Only canonical accepted messages may be published');

  Subject := TMessengerSubjects.AcceptedMessage(AAccepted.Partition);
  Payload := TMessengerJsonCodec.EncodeMessage(AAccepted.Message);

  Options := TNatsJetStreamPublishOptions.CreateDefault;
  { Stable across outbox retries. Database uniqueness is the permanent
    idempotency authority; JetStream dedup prevents duplicate broker entries
    during the configured transport window. }
  Options.MsgId := AAccepted.Message.SenderUserId + ':' +
    AAccepted.Message.ClientMessageId;
  Options.ExpectedStream := TMessengerJetStreamTopology.AcceptedMessagesStream;
  Options.ExtraHeaders := nil;
  Options.ExtraHeaders.Add(HDR_EVENT_TYPE, 'message.accepted.v1');
  Options.ExtraHeaders.Add(HDR_DESTINATION_KIND,
    DestinationKindText(AAccepted.DestinationKind));
  Options.ExtraHeaders.Add(HDR_DESTINATION_ID, AAccepted.DestinationId);
  Options.ExtraHeaders.Add(HDR_CONVERSATION, AAccepted.Message.ConversationId);
  Options.ExtraHeaders.Add(HDR_PARTITION, IntToStr(AAccepted.Partition));
  Options.ExtraHeaders.Add(HDR_SEQUENCE, IntToStr(AAccepted.Sequence));

  FJetStream.Publish(Subject, Payload, Options);
end;

end.
