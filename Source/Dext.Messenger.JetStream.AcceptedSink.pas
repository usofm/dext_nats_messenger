unit Dext.Messenger.JetStream.AcceptedSink;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Commands;

type
  TMessengerJetStreamAcceptedSink = class(TInterfacedObject, IMessengerAcceptedMessageSink)
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
  HDR_TARGET_USER = 'X-Messenger-Target-User';
  HDR_CONVERSATION = 'X-Messenger-Conversation';
  HDR_PARTITION = 'X-Messenger-Partition';
  HDR_EVENT_TYPE = 'X-Messenger-Event-Type';

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
  Subject := TMessengerSubjects.AcceptedMessage(AAccepted.Partition);
  Payload := TMessengerJsonCodec.EncodeMessage(AAccepted.Message);

  Options := TNatsJetStreamPublishOptions.CreateDefault;
  { Nats-Msg-Id protects the transport retry window. Permanent idempotency is
    still enforced by IMessengerIdempotencyStore at the acceptance boundary. }
  Options.MsgId := AAccepted.Message.SenderUserId + ':' +
    AAccepted.Message.ClientMessageId;
  Options.ExpectedStream := TMessengerJetStreamTopology.AcceptedMessagesStream;
  Options.ExtraHeaders := nil;
  Options.ExtraHeaders.Add(HDR_EVENT_TYPE, 'message.accepted.v1');
  Options.ExtraHeaders.Add(HDR_TARGET_USER, AAccepted.TargetUserId);
  Options.ExtraHeaders.Add(HDR_CONVERSATION, AAccepted.Message.ConversationId);
  Options.ExtraHeaders.Add(HDR_PARTITION, IntToStr(AAccepted.Partition));

  { Publish returns only after JetStream acknowledges persistence according to
    the stream replication policy. An exception means acceptance did not pass
    the durable boundary and must not be recorded as successful. }
  FJetStream.Publish(Subject, Payload, Options);
end;

end.
