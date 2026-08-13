unit Dext.Messenger.DeadLetter;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream;

type
  TMessengerDeadLetter = record
  public
    SourceStream: string;
    SourceConsumer: string;
    SourceSubject: string;
    SourceStreamSequence: UInt64;
    Partition: Integer;
    ErrorClass: string;
    ErrorMessage: string;
    FailedAtUnixMs: Int64;
    Payload: TBytes;
  end;

  IMessengerDeadLetterSink = interface
    ['{28458A21-A09A-4DBA-B160-38BC53E66D3C}']
    procedure Write(const ADeadLetter: TMessengerDeadLetter);
  end;

  TMessengerJetStreamDeadLetterSink = class(TInterfacedObject, IMessengerDeadLetterSink)
  private
    FJetStream: TDextNatsJetStreamContext;
    FMaxPayloadBytes: Integer;
  public
    constructor Create(AJetStream: TDextNatsJetStreamContext;
      AMaxPayloadBytes: Integer = 262144);
    procedure Write(const ADeadLetter: TMessengerDeadLetter);
  end;

implementation

uses
  Dext.Net.Nats.Protocol,
  Dext.Messenger.Subjects,
  Dext.Messenger.JetStream.Topology;

const
  HDR_ERROR_CLASS = 'X-Messenger-DLQ-Error-Class';
  HDR_ERROR_MESSAGE = 'X-Messenger-DLQ-Error-Message';
  HDR_SOURCE_STREAM = 'X-Messenger-DLQ-Source-Stream';
  HDR_SOURCE_CONSUMER = 'X-Messenger-DLQ-Source-Consumer';
  HDR_SOURCE_SUBJECT = 'X-Messenger-DLQ-Source-Subject';
  HDR_SOURCE_SEQUENCE = 'X-Messenger-DLQ-Source-Sequence';
  HDR_FAILED_AT = 'X-Messenger-DLQ-Failed-At-Unix-Ms';

constructor TMessengerJetStreamDeadLetterSink.Create(
  AJetStream: TDextNatsJetStreamContext; AMaxPayloadBytes: Integer);
begin
  inherited Create;
  if not Assigned(AJetStream) then
    raise EArgumentNilException.Create('AJetStream');
  if AMaxPayloadBytes <= 0 then
    raise EArgumentOutOfRangeException.Create('AMaxPayloadBytes');
  FJetStream := AJetStream;
  FMaxPayloadBytes := AMaxPayloadBytes;
end;

procedure TMessengerJetStreamDeadLetterSink.Write(
  const ADeadLetter: TMessengerDeadLetter);
var
  Payload: TBytes;
  Options: TNatsJetStreamPublishOptions;
  Subject: string;
  CopyLen: Integer;
begin
  if ADeadLetter.Partition < 0 then
    raise EArgumentOutOfRangeException.Create('Partition');
  if ADeadLetter.ErrorMessage = '' then
    raise EArgumentException.Create('error_message must not be empty');

  CopyLen := Length(ADeadLetter.Payload);
  if CopyLen > FMaxPayloadBytes then
    CopyLen := FMaxPayloadBytes;
  SetLength(Payload, CopyLen);
  if CopyLen > 0 then
    Move(ADeadLetter.Payload[0], Payload[0], CopyLen);

  Subject := TMessengerSubjects.DeliveryDeadLetter(ADeadLetter.Partition);
  Options := TNatsJetStreamPublishOptions.CreateDefault;
  Options.ExpectedStream := TMessengerJetStreamTopology.DeliveryDeadLetterStream;
  Options.MsgId := Format('%s:%s:%d', [
    ADeadLetter.SourceStream,
    ADeadLetter.SourceConsumer,
    ADeadLetter.SourceStreamSequence]);
  Options.ExtraHeaders := nil;
  Options.ExtraHeaders.Add(HDR_ERROR_CLASS, Copy(ADeadLetter.ErrorClass, 1, 200));
  Options.ExtraHeaders.Add(HDR_ERROR_MESSAGE, Copy(ADeadLetter.ErrorMessage, 1, 1000));
  Options.ExtraHeaders.Add(HDR_SOURCE_STREAM, ADeadLetter.SourceStream);
  Options.ExtraHeaders.Add(HDR_SOURCE_CONSUMER, ADeadLetter.SourceConsumer);
  Options.ExtraHeaders.Add(HDR_SOURCE_SUBJECT, ADeadLetter.SourceSubject);
  Options.ExtraHeaders.Add(HDR_SOURCE_SEQUENCE,
    UIntToStr(ADeadLetter.SourceStreamSequence));
  Options.ExtraHeaders.Add(HDR_FAILED_AT, IntToStr(ADeadLetter.FailedAtUnixMs));

  FJetStream.Publish(Subject, Payload, Options);
end;

end.
