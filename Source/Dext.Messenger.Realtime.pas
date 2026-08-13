unit Dext.Messenger.Realtime;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models,
  Dext.Messenger.Transport;

type
  TMessengerPresenceHandler = reference to procedure(const AEvent: TMessengerPresenceEvent);
  TMessengerTypingHandler = reference to procedure(const AEvent: TMessengerTypingEvent);
  TMessengerReceiptHandler = reference to procedure(const AReceipt: TMessengerReceipt);

  TMessengerRealtimeService = class
  private
    FTransport: IMessengerTransport;
    class function EncodePresence(const AEvent: TMessengerPresenceEvent): TBytes; static;
    class function EncodeTyping(const AEvent: TMessengerTypingEvent): TBytes; static;
    class function EncodeReceipt(const AReceipt: TMessengerReceipt): TBytes; static;
    class function DecodePresence(const AData: TBytes): TMessengerPresenceEvent; static;
    class function DecodeTyping(const AData: TBytes): TMessengerTypingEvent; static;
    class function DecodeReceipt(const AData: TBytes): TMessengerReceipt; static;
  public
    constructor Create(const ATransport: IMessengerTransport);

    procedure SendToGroup(const AGroupId: string; const AMessage: TMessengerMessage);
    function SubscribeGroup(const AGroupId: string;
      const AHandler: TProc<TMessengerMessage>): IMessengerSubscription;

    procedure PublishPresence(const AEvent: TMessengerPresenceEvent);
    function SubscribePresence(const AUserId: string;
      const AHandler: TMessengerPresenceHandler): IMessengerSubscription;

    procedure PublishTypingToUser(const ATargetUserId: string;
      const AEvent: TMessengerTypingEvent);
    procedure PublishTypingToGroup(const AGroupId: string;
      const AEvent: TMessengerTypingEvent);
    function SubscribeUserTyping(const AUserId: string;
      const AHandler: TMessengerTypingHandler): IMessengerSubscription;
    function SubscribeGroupTyping(const AGroupId: string;
      const AHandler: TMessengerTypingHandler): IMessengerSubscription;

    procedure PublishReceipt(const AReceipt: TMessengerReceipt);
    function SubscribeDeliveredReceipts(const AConversationId: string;
      const AHandler: TMessengerReceiptHandler): IMessengerSubscription;
    function SubscribeReadReceipts(const AConversationId: string;
      const AHandler: TMessengerReceiptHandler): IMessengerSubscription;
  end;

implementation

uses
  System.Classes,
  Dext.Core.Span,
  Dext.Json.Utf8,
  Dext.Messenger.Codec.Json,
  Dext.Messenger.Subjects,
  Dext.Messenger.Validation;

type
  PRTWriter = ^TRTWriter;
  TRTWriter = record
  private
    B: TBytes;
    L: Integer;
  public
    procedure Write(P: Pointer; N: Integer);
    function Bytes: TBytes;
  end;

procedure RTWrite(Ctx, Data: Pointer; Len: Integer);
begin
  if (Ctx <> nil) and (Data <> nil) and (Len > 0) then
    PRTWriter(Ctx)^.Write(Data, Len);
end;

procedure TRTWriter.Write(P: Pointer; N: Integer);
var C: Integer;
begin
  if N <= 0 then Exit;
  C := Length(B);
  if C < 256 then C := 256;
  while L + N > C do C := C * 2;
  if Length(B) < C then SetLength(B, C);
  Move(P^, B[L], N);
  Inc(L, N);
end;

function TRTWriter.Bytes: TBytes;
begin
  SetLength(Result, L);
  if L > 0 then Move(B[0], Result[0], L);
end;

function PresenceStateText(S: TMessengerPresenceState): string;
begin
  case S of
    mpsOnline: Result := 'online';
    mpsOffline: Result := 'offline';
    mpsHeartbeat: Result := 'heartbeat';
  else
    raise EArgumentOutOfRangeException.Create('presence state');
  end;
end;

function ReceiptStateText(S: TMessengerReceiptState): string;
begin
  case S of
    mrsDelivered: Result := 'delivered';
    mrsRead: Result := 'read';
  else
    raise EArgumentOutOfRangeException.Create('receipt state');
  end;
end;

function PresenceStateFromText(const S: string): TMessengerPresenceState;
begin
  if S = 'online' then Exit(mpsOnline);
  if S = 'offline' then Exit(mpsOffline);
  if S = 'heartbeat' then Exit(mpsHeartbeat);
  raise EMessengerValidationError.Create('Invalid presence state');
end;

function ReceiptStateFromText(const S: string): TMessengerReceiptState;
begin
  if S = 'delivered' then Exit(mrsDelivered);
  if S = 'read' then Exit(mrsRead);
  raise EMessengerValidationError.Create('Invalid receipt state');
end;

procedure SkipUnknown(var R: TUtf8JsonReader);
begin
  if R.TokenType in [TJsonTokenType.StartObject, TJsonTokenType.StartArray] then
    R.Skip;
end;

constructor TMessengerRealtimeService.Create(const ATransport: IMessengerTransport);
begin
  inherited Create;
  if ATransport = nil then raise EArgumentNilException.Create('ATransport');
  FTransport := ATransport;
end;

procedure TMessengerRealtimeService.SendToGroup(const AGroupId: string;
  const AMessage: TMessengerMessage);
begin
  TMessengerValidator.ValidateMessage(AMessage);
  FTransport.Publish(TMessengerSubjects.GroupMessage(AGroupId),
    TMessengerJsonCodec.EncodeMessage(AMessage));
end;

function TMessengerRealtimeService.SubscribeGroup(const AGroupId: string;
  const AHandler: TProc<TMessengerMessage>): IMessengerSubscription;
begin
  if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler');
  Result := FTransport.Subscribe(TMessengerSubjects.GroupMessage(AGroupId),
    procedure(const S: string; const P: TBytes)
    begin
      AHandler(TMessengerJsonCodec.DecodeMessage(P));
    end);
end;

class function TMessengerRealtimeService.EncodePresence(
  const AEvent: TMessengerPresenceEvent): TBytes;
var W: TRTWriter; J: TUtf8JsonWriter;
begin
  TMessengerValidator.ValidatePresence(AEvent);
  W := Default(TRTWriter); J := TUtf8JsonWriter.Create(@W, RTWrite, False);
  J.WriteStartObject;
  J.WritePropertyName('version'); J.WriteNumber(AEvent.Version);
  J.WritePropertyName('user_id'); J.WriteString(AEvent.UserId);
  J.WritePropertyName('device_id'); J.WriteString(AEvent.DeviceId);
  J.WritePropertyName('gateway_id'); J.WriteString(AEvent.GatewayId);
  J.WritePropertyName('state'); J.WriteString(PresenceStateText(AEvent.State));
  J.WritePropertyName('at_unix_ms'); J.WriteNumber(AEvent.AtUnixMs);
  J.WriteEndObject;
  Result := W.Bytes;
end;

class function TMessengerRealtimeService.EncodeTyping(
  const AEvent: TMessengerTypingEvent): TBytes;
var W: TRTWriter; J: TUtf8JsonWriter;
begin
  TMessengerValidator.ValidateTyping(AEvent);
  W := Default(TRTWriter); J := TUtf8JsonWriter.Create(@W, RTWrite, False);
  J.WriteStartObject;
  J.WritePropertyName('version'); J.WriteNumber(AEvent.Version);
  J.WritePropertyName('conversation_id'); J.WriteString(AEvent.ConversationId);
  J.WritePropertyName('user_id'); J.WriteString(AEvent.UserId);
  J.WritePropertyName('is_typing'); J.WriteBoolean(AEvent.IsTyping);
  J.WritePropertyName('at_unix_ms'); J.WriteNumber(AEvent.AtUnixMs);
  J.WriteEndObject;
  Result := W.Bytes;
end;

class function TMessengerRealtimeService.EncodeReceipt(
  const AReceipt: TMessengerReceipt): TBytes;
var W: TRTWriter; J: TUtf8JsonWriter;
begin
  TMessengerValidator.ValidateReceipt(AReceipt);
  W := Default(TRTWriter); J := TUtf8JsonWriter.Create(@W, RTWrite, False);
  J.WriteStartObject;
  J.WritePropertyName('version'); J.WriteNumber(AReceipt.Version);
  J.WritePropertyName('message_id'); J.WriteString(AReceipt.MessageId);
  J.WritePropertyName('conversation_id'); J.WriteString(AReceipt.ConversationId);
  J.WritePropertyName('user_id'); J.WriteString(AReceipt.UserId);
  J.WritePropertyName('device_id'); J.WriteString(AReceipt.DeviceId);
  J.WritePropertyName('state'); J.WriteString(ReceiptStateText(AReceipt.State));
  J.WritePropertyName('at_unix_ms'); J.WriteNumber(AReceipt.AtUnixMs);
  J.WriteEndObject;
  Result := W.Bytes;
end;

class function TMessengerRealtimeService.DecodePresence(const AData: TBytes): TMessengerPresenceEvent;
var R: TUtf8JsonReader; S: TByteSpan; N, V: string;
begin
  Result := Default(TMessengerPresenceEvent);
  if Length(AData)=0 then raise EMessengerValidationError.Create('Empty presence payload');
  S := TByteSpan.Create(@AData[0], Length(AData)); R := TUtf8JsonReader.Create(S);
  if (not R.Read) or (R.TokenType<>TJsonTokenType.StartObject) then raise EMessengerValidationError.Create('Invalid presence JSON');
  while R.Read do begin
    if R.TokenType=TJsonTokenType.EndObject then Break;
    if R.TokenType<>TJsonTokenType.PropertyName then raise EMessengerValidationError.Create('Invalid presence JSON');
    N:=R.GetString; if not R.Read then Break;
    if N='version' then Result.Version:=R.GetInt32
    else if N='user_id' then Result.UserId:=R.GetString
    else if N='device_id' then Result.DeviceId:=R.GetString
    else if N='gateway_id' then Result.GatewayId:=R.GetString
    else if N='state' then begin V:=R.GetString; Result.State:=PresenceStateFromText(V); end
    else if N='at_unix_ms' then Result.AtUnixMs:=R.GetInt64 else SkipUnknown(R);
  end;
  TMessengerValidator.ValidatePresence(Result);
end;

class function TMessengerRealtimeService.DecodeTyping(const AData: TBytes): TMessengerTypingEvent;
var R: TUtf8JsonReader; S: TByteSpan; N: string;
begin
  Result := Default(TMessengerTypingEvent);
  if Length(AData)=0 then raise EMessengerValidationError.Create('Empty typing payload');
  S:=TByteSpan.Create(@AData[0],Length(AData)); R:=TUtf8JsonReader.Create(S);
  if (not R.Read) or (R.TokenType<>TJsonTokenType.StartObject) then raise EMessengerValidationError.Create('Invalid typing JSON');
  while R.Read do begin
    if R.TokenType=TJsonTokenType.EndObject then Break;
    if R.TokenType<>TJsonTokenType.PropertyName then raise EMessengerValidationError.Create('Invalid typing JSON');
    N:=R.GetString; if not R.Read then Break;
    if N='version' then Result.Version:=R.GetInt32
    else if N='conversation_id' then Result.ConversationId:=R.GetString
    else if N='user_id' then Result.UserId:=R.GetString
    else if N='is_typing' then Result.IsTyping:=R.TokenType=TJsonTokenType.TrueValue
    else if N='at_unix_ms' then Result.AtUnixMs:=R.GetInt64 else SkipUnknown(R);
  end;
  TMessengerValidator.ValidateTyping(Result);
end;

class function TMessengerRealtimeService.DecodeReceipt(const AData: TBytes): TMessengerReceipt;
var R: TUtf8JsonReader; S: TByteSpan; N,V: string;
begin
  Result:=Default(TMessengerReceipt);
  if Length(AData)=0 then raise EMessengerValidationError.Create('Empty receipt payload');
  S:=TByteSpan.Create(@AData[0],Length(AData)); R:=TUtf8JsonReader.Create(S);
  if (not R.Read) or (R.TokenType<>TJsonTokenType.StartObject) then raise EMessengerValidationError.Create('Invalid receipt JSON');
  while R.Read do begin
    if R.TokenType=TJsonTokenType.EndObject then Break;
    if R.TokenType<>TJsonTokenType.PropertyName then raise EMessengerValidationError.Create('Invalid receipt JSON');
    N:=R.GetString; if not R.Read then Break;
    if N='version' then Result.Version:=R.GetInt32
    else if N='message_id' then Result.MessageId:=R.GetString
    else if N='conversation_id' then Result.ConversationId:=R.GetString
    else if N='user_id' then Result.UserId:=R.GetString
    else if N='device_id' then Result.DeviceId:=R.GetString
    else if N='state' then begin V:=R.GetString; Result.State:=ReceiptStateFromText(V); end
    else if N='at_unix_ms' then Result.AtUnixMs:=R.GetInt64 else SkipUnknown(R);
  end;
  TMessengerValidator.ValidateReceipt(Result);
end;

procedure TMessengerRealtimeService.PublishPresence(const AEvent: TMessengerPresenceEvent);
begin FTransport.Publish(TMessengerSubjects.UserPresence(AEvent.UserId), EncodePresence(AEvent)); end;

function TMessengerRealtimeService.SubscribePresence(const AUserId: string; const AHandler: TMessengerPresenceHandler): IMessengerSubscription;
begin
  if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler');
  Result:=FTransport.Subscribe(TMessengerSubjects.UserPresence(AUserId), procedure(const S:string; const P:TBytes) begin AHandler(DecodePresence(P)); end);
end;

procedure TMessengerRealtimeService.PublishTypingToUser(const ATargetUserId:string; const AEvent:TMessengerTypingEvent);
begin FTransport.Publish(TMessengerSubjects.UserTyping(ATargetUserId),EncodeTyping(AEvent)); end;

procedure TMessengerRealtimeService.PublishTypingToGroup(const AGroupId:string; const AEvent:TMessengerTypingEvent);
begin FTransport.Publish(TMessengerSubjects.GroupTyping(AGroupId),EncodeTyping(AEvent)); end;

function TMessengerRealtimeService.SubscribeUserTyping(const AUserId:string; const AHandler:TMessengerTypingHandler):IMessengerSubscription;
begin if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler'); Result:=FTransport.Subscribe(TMessengerSubjects.UserTyping(AUserId),procedure(const S:string;const P:TBytes)begin AHandler(DecodeTyping(P));end); end;

function TMessengerRealtimeService.SubscribeGroupTyping(const AGroupId:string; const AHandler:TMessengerTypingHandler):IMessengerSubscription;
begin if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler'); Result:=FTransport.Subscribe(TMessengerSubjects.GroupTyping(AGroupId),procedure(const S:string;const P:TBytes)begin AHandler(DecodeTyping(P));end); end;

procedure TMessengerRealtimeService.PublishReceipt(const AReceipt:TMessengerReceipt);
var S:string;
begin
  if AReceipt.State=mrsDelivered then S:=TMessengerSubjects.DeliveredReceipt(AReceipt.ConversationId) else S:=TMessengerSubjects.ReadReceipt(AReceipt.ConversationId);
  FTransport.Publish(S,EncodeReceipt(AReceipt));
end;

function TMessengerRealtimeService.SubscribeDeliveredReceipts(const AConversationId:string; const AHandler:TMessengerReceiptHandler):IMessengerSubscription;
begin if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler'); Result:=FTransport.Subscribe(TMessengerSubjects.DeliveredReceipt(AConversationId),procedure(const S:string;const P:TBytes)begin AHandler(DecodeReceipt(P));end); end;

function TMessengerRealtimeService.SubscribeReadReceipts(const AConversationId:string; const AHandler:TMessengerReceiptHandler):IMessengerSubscription;
begin if not Assigned(AHandler) then raise EArgumentNilException.Create('AHandler'); Result:=FTransport.Subscribe(TMessengerSubjects.ReadReceipt(AConversationId),procedure(const S:string;const P:TBytes)begin AHandler(DecodeReceipt(P));end); end;

end.
