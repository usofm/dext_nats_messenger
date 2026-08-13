unit Dext.Messenger.Delivery;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream,
  Dext.Messenger.Commands,
  Dext.Messenger.Transport;

type
  EMessengerDeliveryPoison = class(Exception);

  TMessengerDeliveryHandler = reference to procedure(
    const ADelivery: TMessengerAcceptedMessage);

  TMessengerDeliveryCodec = record
  public
    class function Encode(const AAccepted: TMessengerAcceptedMessage): TBytes; static;
    class function Decode(const AData: TBytes): TMessengerAcceptedMessage; static;
  end;

  { Consumes canonical durable events from JetStream and fans them to Core NATS.
    Core NATS is intentionally online-only; offline recovery comes from DB sync. }
  TMessengerJetStreamDeliveryProcessor = class
  private
    FJetStream: TDextNatsJetStreamContext;
    FTransport: IMessengerTransport;
    FRetryDelayMs: Integer;
  public
    constructor Create(AJetStream: TDextNatsJetStreamContext;
      const ATransport: IMessengerTransport; ARetryDelayMs: Integer = 500);
    procedure Process(const AMsg: TNatsJsMsg);
  end;

  { Gateway/client-side subscription helper for the sequenced production
    delivery envelope. This is separate from the bootstrap MessageService that
    publishes raw TMessengerMessage in developer/direct-NATS mode. }
  TMessengerOnlineDeliveryService = class
  private
    FTransport: IMessengerTransport;
  public
    constructor Create(const ATransport: IMessengerTransport);
    function SubscribeUser(const AUserId: string;
      const AHandler: TMessengerDeliveryHandler): IMessengerSubscription;
    function SubscribeGroup(const AGroupId: string;
      const AHandler: TMessengerDeliveryHandler): IMessengerSubscription;
  end;

implementation

uses
  System.Classes,
  Dext.Core.Span,
  Dext.Json.Utf8,
  Dext.Net.Nats.Protocol,
  Dext.Messenger.Codec.Json,
  Dext.Messenger.Subjects;

const
  HDR_DESTINATION_KIND = 'X-Messenger-Destination-Kind';
  HDR_DESTINATION_ID = 'X-Messenger-Destination-Id';
  HDR_PARTITION = 'X-Messenger-Partition';
  HDR_SEQUENCE = 'X-Messenger-Sequence';
  HDR_EVENT_TYPE = 'X-Messenger-Event-Type';

type
  PDeliveryWriter = ^TDeliveryWriter;
  TDeliveryWriter = record
  private
    FBuffer: TBytes;
    FLength: Integer;
  public
    procedure WriteBytes(AData: Pointer; ALength: Integer);
    function ToBytes: TBytes;
  end;

procedure DeliveryWrite(AContext, AData: Pointer; ALength: Integer);
begin
  if (AContext <> nil) and (AData <> nil) and (ALength > 0) then
    PDeliveryWriter(AContext)^.WriteBytes(AData, ALength);
end;

procedure TDeliveryWriter.WriteBytes(AData: Pointer; ALength: Integer);
var
  Capacity: Integer;
begin
  if (AData = nil) or (ALength <= 0) then Exit;
  Capacity := Length(FBuffer);
  if Capacity < 256 then Capacity := 256;
  while FLength + ALength > Capacity do Capacity := Capacity * 2;
  if Length(FBuffer) < Capacity then SetLength(FBuffer, Capacity);
  Move(AData^, FBuffer[FLength], ALength);
  Inc(FLength, ALength);
end;

function TDeliveryWriter.ToBytes: TBytes;
begin
  SetLength(Result, FLength);
  if FLength > 0 then Move(FBuffer[0], Result[0], FLength);
end;

function DestinationKindText(AKind: TMessengerDestinationKind): string;
begin
  case AKind of
    mdkUser: Result := 'user';
    mdkGroup: Result := 'group';
  else
    raise EMessengerDeliveryPoison.Create('Invalid destination kind');
  end;
end;

function DestinationKindFromText(const AValue: string): TMessengerDestinationKind;
begin
  if AValue = 'user' then Exit(mdkUser);
  if AValue = 'group' then Exit(mdkGroup);
  raise EMessengerDeliveryPoison.Create('Invalid destination kind');
end;

procedure CopyJsonValue(var AReader: TUtf8JsonReader;
  var AWriter: TUtf8JsonWriter); forward;

procedure CopyJsonObject(var AReader: TUtf8JsonReader;
  var AWriter: TUtf8JsonWriter);
begin
  AWriter.WriteStartObject;
  while AReader.Read do
  begin
    if AReader.TokenType = TJsonTokenType.EndObject then Break;
    if AReader.TokenType <> TJsonTokenType.PropertyName then
      raise EMessengerDeliveryPoison.Create('Invalid nested JSON object');
    AWriter.WritePropertyName(AReader.GetString);
    if not AReader.Read then
      raise EMessengerDeliveryPoison.Create('Unexpected end of nested JSON object');
    CopyJsonValue(AReader, AWriter);
  end;
  AWriter.WriteEndObject;
end;

procedure CopyJsonArray(var AReader: TUtf8JsonReader;
  var AWriter: TUtf8JsonWriter);
begin
  AWriter.WriteStartArray;
  while AReader.Read do
  begin
    if AReader.TokenType = TJsonTokenType.EndArray then Break;
    CopyJsonValue(AReader, AWriter);
  end;
  AWriter.WriteEndArray;
end;

procedure CopyJsonValue(var AReader: TUtf8JsonReader;
  var AWriter: TUtf8JsonWriter);
var
  N: string;
begin
  case AReader.TokenType of
    TJsonTokenType.StartObject: CopyJsonObject(AReader, AWriter);
    TJsonTokenType.StartArray: CopyJsonArray(AReader, AWriter);
    TJsonTokenType.StringValue: AWriter.WriteString(AReader.GetString);
    TJsonTokenType.Number:
      begin
        N := AReader.ValueSpan.ToString;
        if (Pos('.', N) > 0) or (Pos('e', N) > 0) or (Pos('E', N) > 0) then
          AWriter.WriteNumber(AReader.GetDouble)
        else
          AWriter.WriteNumber(AReader.GetInt64);
      end;
    TJsonTokenType.TrueValue: AWriter.WriteBoolean(True);
    TJsonTokenType.FalseValue: AWriter.WriteBoolean(False);
    TJsonTokenType.NullValue: AWriter.WriteNull;
  else
    raise EMessengerDeliveryPoison.Create('Unsupported JSON token');
  end;
end;

procedure WriteRawJson(var AWriter: TUtf8JsonWriter; const AJson: TBytes);
var
  R: TUtf8JsonReader;
  S: TByteSpan;
begin
  if Length(AJson) = 0 then
    raise EMessengerDeliveryPoison.Create('Nested message JSON is empty');
  S := TByteSpan.Create(@AJson[0], Length(AJson));
  R := TUtf8JsonReader.Create(S);
  if not R.Read then
    raise EMessengerDeliveryPoison.Create('Invalid nested message JSON');
  CopyJsonValue(R, AWriter);
end;

function ReadCurrentJsonValue(var AReader: TUtf8JsonReader): TBytes;
var
  W: TDeliveryWriter;
  J: TUtf8JsonWriter;
begin
  W := Default(TDeliveryWriter);
  J := TUtf8JsonWriter.Create(@W, DeliveryWrite, False);
  CopyJsonValue(AReader, J);
  Result := W.ToBytes;
end;

class function TMessengerDeliveryCodec.Encode(
  const AAccepted: TMessengerAcceptedMessage): TBytes;
var
  W: TDeliveryWriter;
  J: TUtf8JsonWriter;
  MessageJson: TBytes;
begin
  if not AAccepted.IsCanonical then
    raise EMessengerDeliveryPoison.Create('Delivery requires canonical sequence');

  MessageJson := TMessengerJsonCodec.EncodeMessage(AAccepted.Message);
  W := Default(TDeliveryWriter);
  J := TUtf8JsonWriter.Create(@W, DeliveryWrite, False);
  J.WriteStartObject;
  J.WritePropertyName('version'); J.WriteNumber(1);
  J.WritePropertyName('sequence'); J.WriteNumber(AAccepted.Sequence);
  J.WritePropertyName('partition'); J.WriteNumber(AAccepted.Partition);
  J.WritePropertyName('destination_kind');
  J.WriteString(DestinationKindText(AAccepted.DestinationKind));
  J.WritePropertyName('destination_id'); J.WriteString(AAccepted.DestinationId);
  J.WritePropertyName('message'); WriteRawJson(J, MessageJson);
  J.WriteEndObject;
  Result := W.ToBytes;
end;

class function TMessengerDeliveryCodec.Decode(
  const AData: TBytes): TMessengerAcceptedMessage;
var
  S: TByteSpan;
  R: TUtf8JsonReader;
  Name, KindText: string;
  Version, Partition: Integer;
  Sequence: Int64;
  DestinationId: string;
  DestinationKind: TMessengerDestinationKind;
  MessageJson: TBytes;
  Message: Dext.Messenger.Models.TMessengerMessage;
begin
  Version := 0;
  Partition := -1;
  Sequence := 0;
  DestinationId := '';
  KindText := '';
  MessageJson := nil;

  if Length(AData) = 0 then
    raise EMessengerDeliveryPoison.Create('Delivery payload is empty');
  S := TByteSpan.Create(@AData[0], Length(AData));
  R := TUtf8JsonReader.Create(S);
  if (not R.Read) or (R.TokenType <> TJsonTokenType.StartObject) then
    raise EMessengerDeliveryPoison.Create('Delivery envelope must be an object');

  while R.Read do
  begin
    if R.TokenType = TJsonTokenType.EndObject then Break;
    if R.TokenType <> TJsonTokenType.PropertyName then
      raise EMessengerDeliveryPoison.Create('Invalid delivery envelope');
    Name := R.GetString;
    if not R.Read then raise EMessengerDeliveryPoison.Create('Unexpected end of delivery envelope');

    if Name = 'version' then Version := R.GetInt32
    else if Name = 'sequence' then Sequence := R.GetInt64
    else if Name = 'partition' then Partition := R.GetInt32
    else if Name = 'destination_kind' then KindText := R.GetString
    else if Name = 'destination_id' then DestinationId := R.GetString
    else if Name = 'message' then MessageJson := ReadCurrentJsonValue(R)
    else if R.TokenType in [TJsonTokenType.StartObject, TJsonTokenType.StartArray] then R.Skip;
  end;

  if Version <> 1 then raise EMessengerDeliveryPoison.Create('Unsupported delivery version');
  if Sequence <= 0 then raise EMessengerDeliveryPoison.Create('Invalid delivery sequence');
  if Partition < 0 then raise EMessengerDeliveryPoison.Create('Invalid delivery partition');
  if DestinationId = '' then raise EMessengerDeliveryPoison.Create('Missing destination_id');
  DestinationKind := DestinationKindFromText(KindText);
  Message := TMessengerJsonCodec.DecodeMessage(MessageJson);
  Result := TMessengerAcceptedMessage.Create(Message, DestinationKind,
    DestinationId, Partition, Sequence);
end;

constructor TMessengerJetStreamDeliveryProcessor.Create(
  AJetStream: TDextNatsJetStreamContext; const ATransport: IMessengerTransport;
  ARetryDelayMs: Integer);
begin
  inherited Create;
  if not Assigned(AJetStream) then raise EArgumentNilException.Create('AJetStream');
  if ATransport = nil then raise EArgumentNilException.Create('ATransport');
  if ARetryDelayMs < 0 then raise EArgumentOutOfRangeException.Create('ARetryDelayMs');
  FJetStream := AJetStream;
  FTransport := ATransport;
  FRetryDelayMs := ARetryDelayMs;
end;

procedure TMessengerJetStreamDeliveryProcessor.Process(const AMsg: TNatsJsMsg);
var
  EventType, KindText, DestinationId, SequenceText, PartitionText: string;
  Sequence: Int64;
  Partition: Integer;
  DestinationKind: TMessengerDestinationKind;
  Message: Dext.Messenger.Models.TMessengerMessage;
  Accepted: TMessengerAcceptedMessage;
  Subject: string;
begin
  try
    EventType := AMsg.Headers.GetValue(HDR_EVENT_TYPE);
    if EventType <> 'message.accepted.v1' then
      raise EMessengerDeliveryPoison.Create('Unsupported event type');

    KindText := AMsg.Headers.GetValue(HDR_DESTINATION_KIND);
    DestinationId := AMsg.Headers.GetValue(HDR_DESTINATION_ID);
    SequenceText := AMsg.Headers.GetValue(HDR_SEQUENCE);
    PartitionText := AMsg.Headers.GetValue(HDR_PARTITION);
    if DestinationId = '' then raise EMessengerDeliveryPoison.Create('Missing destination header');
    if not TryStrToInt64(SequenceText, Sequence) or (Sequence <= 0) then
      raise EMessengerDeliveryPoison.Create('Invalid sequence header');
    if not TryStrToInt(PartitionText, Partition) or (Partition < 0) then
      raise EMessengerDeliveryPoison.Create('Invalid partition header');

    DestinationKind := DestinationKindFromText(KindText);
    Message := TMessengerJsonCodec.DecodeMessage(AMsg.Payload);
    Accepted := TMessengerAcceptedMessage.Create(Message, DestinationKind,
      DestinationId, Partition, Sequence);

    if DestinationKind = mdkUser then
      Subject := TMessengerSubjects.UserMessage(DestinationId)
    else
      Subject := TMessengerSubjects.GroupMessage(DestinationId);

    FTransport.Publish(Subject, TMessengerDeliveryCodec.Encode(Accepted));
    FJetStream.Ack(AMsg);
  except
    on E: EMessengerDeliveryPoison do
      FJetStream.Term(AMsg);
    on E: Exception do
      FJetStream.Nak(AMsg, FRetryDelayMs);
  end;
end;

constructor TMessengerOnlineDeliveryService.Create(
  const ATransport: IMessengerTransport);
begin
  inherited Create;
  if ATransport = nil then raise EArgumentNilException.Create('ATransport');
  FTransport := ATransport;
end;

function TMessengerOnlineDeliveryService.SubscribeUser(const AUserId: string;
  const AHandler: TMessengerDeliveryHandler): IMessengerSubscription;
begin
  if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler');
  Result := FTransport.Subscribe(TMessengerSubjects.UserMessage(AUserId),
    procedure(const ASubject: string; const APayload: TBytes)
    begin
      AHandler(TMessengerDeliveryCodec.Decode(APayload));
    end);
end;

function TMessengerOnlineDeliveryService.SubscribeGroup(const AGroupId: string;
  const AHandler: TMessengerDeliveryHandler): IMessengerSubscription;
begin
  if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler');
  Result := FTransport.Subscribe(TMessengerSubjects.GroupMessage(AGroupId),
    procedure(const ASubject: string; const APayload: TBytes)
    begin
      AHandler(TMessengerDeliveryCodec.Decode(APayload));
    end);
end;

end.
