unit Dext.Messenger.Codec.Json;

interface

uses
  System.SysUtils,
  System.Classes,
  Dext.Messenger.Models;

type
  EMessengerCodecError = class(Exception);

  TMessengerJsonCodec = record
  public
    class function EncodeMessage(const AMessage: TMessengerMessage): TBytes; static;
    class function DecodeMessage(const AData: TBytes): TMessengerMessage; static;
  end;

implementation

uses
  Dext.Core.Span,
  Dext.Json.Utf8,
  Dext.Messenger.Validation;

type
  PMessengerByteWriter = ^TMessengerByteWriter;

  TMessengerByteWriter = record
  private
    FBuffer: TBytes;
    FLength: Integer;
  public
    procedure Reset;
    procedure WriteBytes(AData: Pointer; ALength: Integer);
    function ToBytes: TBytes;
  end;

procedure MessengerUtf8Write(AContext, AData: Pointer; ALength: Integer);
begin
  if (AContext <> nil) and (AData <> nil) and (ALength > 0) then
    PMessengerByteWriter(AContext)^.WriteBytes(AData, ALength);
end;

procedure TMessengerByteWriter.Reset;
begin
  FLength := 0;
end;

procedure TMessengerByteWriter.WriteBytes(AData: Pointer; ALength: Integer);
var
  NewCapacity: Integer;
begin
  if (AData = nil) or (ALength <= 0) then
    Exit;

  if FLength + ALength > Length(FBuffer) then
  begin
    NewCapacity := Length(FBuffer);
    if NewCapacity < 256 then
      NewCapacity := 256;
    while FLength + ALength > NewCapacity do
      NewCapacity := NewCapacity * 2;
    SetLength(FBuffer, NewCapacity);
  end;

  Move(AData^, FBuffer[FLength], ALength);
  Inc(FLength, ALength);
end;

function TMessengerByteWriter.ToBytes: TBytes;
begin
  SetLength(Result, FLength);
  if FLength > 0 then
    Move(FBuffer[0], Result[0], FLength);
end;

function MessageKindToString(AKind: TMessengerMessageKind): string;
begin
  case AKind of
    mmkText: Result := 'text';
    mmkImage: Result := 'image';
    mmkAudio: Result := 'audio';
    mmkVideo: Result := 'video';
    mmkFile: Result := 'file';
    mmkSystem: Result := 'system';
  else
    raise EMessengerCodecError.Create('Unsupported message kind');
  end;
end;

function StringToMessageKind(const AValue: string): TMessengerMessageKind;
begin
  if AValue = 'text' then Exit(mmkText);
  if AValue = 'image' then Exit(mmkImage);
  if AValue = 'audio' then Exit(mmkAudio);
  if AValue = 'video' then Exit(mmkVideo);
  if AValue = 'file' then Exit(mmkFile);
  if AValue = 'system' then Exit(mmkSystem);
  raise EMessengerCodecError.CreateFmt('Unsupported message kind "%s"', [AValue]);
end;

procedure CopyJsonValue(var AReader: TUtf8JsonReader; var AWriter: TUtf8JsonWriter); forward;

procedure CopyJsonObject(var AReader: TUtf8JsonReader; var AWriter: TUtf8JsonWriter);
begin
  AWriter.WriteStartObject;
  while AReader.Read do
  begin
    if AReader.TokenType = TJsonTokenType.EndObject then
      Break;
    if AReader.TokenType <> TJsonTokenType.PropertyName then
      raise EMessengerCodecError.Create('Invalid JSON object');
    AWriter.WritePropertyName(AReader.GetString);
    if not AReader.Read then
      raise EMessengerCodecError.Create('Unexpected end of JSON object');
    CopyJsonValue(AReader, AWriter);
  end;
  AWriter.WriteEndObject;
end;

procedure CopyJsonArray(var AReader: TUtf8JsonReader; var AWriter: TUtf8JsonWriter);
begin
  AWriter.WriteStartArray;
  while AReader.Read do
  begin
    if AReader.TokenType = TJsonTokenType.EndArray then
      Break;
    CopyJsonValue(AReader, AWriter);
  end;
  AWriter.WriteEndArray;
end;

procedure CopyJsonValue(var AReader: TUtf8JsonReader; var AWriter: TUtf8JsonWriter);
var
  NumberText: string;
begin
  case AReader.TokenType of
    TJsonTokenType.StartObject: CopyJsonObject(AReader, AWriter);
    TJsonTokenType.StartArray: CopyJsonArray(AReader, AWriter);
    TJsonTokenType.StringValue: AWriter.WriteString(AReader.GetString);
    TJsonTokenType.Number:
      begin
        NumberText := AReader.ValueSpan.ToString;
        if (Pos('.', NumberText) > 0) or (Pos('e', NumberText) > 0) or (Pos('E', NumberText) > 0) then
          AWriter.WriteNumber(AReader.GetDouble)
        else
          AWriter.WriteNumber(AReader.GetInt64);
      end;
    TJsonTokenType.TrueValue: AWriter.WriteBoolean(True);
    TJsonTokenType.FalseValue: AWriter.WriteBoolean(False);
    TJsonTokenType.NullValue: AWriter.WriteNull;
  else
    raise EMessengerCodecError.Create('Unsupported JSON token');
  end;
end;

procedure WriteRawJsonValue(var AWriter: TUtf8JsonWriter; const AJson: string);
var
  Bytes: TBytes;
  Span: TByteSpan;
  Reader: TUtf8JsonReader;
begin
  Bytes := TEncoding.UTF8.GetBytes(AJson);
  if Length(Bytes) = 0 then
  begin
    AWriter.WriteNull;
    Exit;
  end;

  Span := TByteSpan.Create(@Bytes[0], Length(Bytes));
  Reader := TUtf8JsonReader.Create(Span);
  if not Reader.Read then
    raise EMessengerCodecError.Create('Invalid payload JSON');
  CopyJsonValue(Reader, AWriter);
end;

function ReadCurrentJsonValue(var AReader: TUtf8JsonReader): string;
var
  WriterBuffer: TMessengerByteWriter;
  Writer: TUtf8JsonWriter;
begin
  WriterBuffer.Reset;
  Writer := TUtf8JsonWriter.Create(@WriterBuffer, MessengerUtf8Write, False);
  CopyJsonValue(AReader, Writer);
  Result := TEncoding.UTF8.GetString(WriterBuffer.ToBytes);
end;

class function TMessengerJsonCodec.EncodeMessage(const AMessage: TMessengerMessage): TBytes;
var
  Buffer: TMessengerByteWriter;
  Writer: TUtf8JsonWriter;
begin
  TMessengerValidator.ValidateMessage(AMessage);

  Buffer.Reset;
  Writer := TUtf8JsonWriter.Create(@Buffer, MessengerUtf8Write, False);
  Writer.WriteStartObject;
  Writer.WritePropertyName('version');
  Writer.WriteNumber(AMessage.Version);
  Writer.WritePropertyName('message_id');
  Writer.WriteString(AMessage.MessageId);
  Writer.WritePropertyName('client_message_id');
  Writer.WriteString(AMessage.ClientMessageId);
  Writer.WritePropertyName('conversation_id');
  Writer.WriteString(AMessage.ConversationId);
  Writer.WritePropertyName('sender_user_id');
  Writer.WriteString(AMessage.SenderUserId);
  Writer.WritePropertyName('kind');
  Writer.WriteString(MessageKindToString(AMessage.Kind));
  Writer.WritePropertyName('created_at_unix_ms');
  Writer.WriteNumber(AMessage.CreatedAtUnixMs);
  Writer.WritePropertyName('payload');
  WriteRawJsonValue(Writer, AMessage.PayloadJson);
  Writer.WriteEndObject;
  Result := Buffer.ToBytes;
end;

class function TMessengerJsonCodec.DecodeMessage(const AData: TBytes): TMessengerMessage;
var
  Span: TByteSpan;
  Reader: TUtf8JsonReader;
  PropertyName: string;
  KindText: string;
  VersionValue: Int64;
begin
  Result := Default(TMessengerMessage);
  if Length(AData) = 0 then
    raise EMessengerCodecError.Create('Message payload is empty');

  Span := TByteSpan.Create(@AData[0], Length(AData));
  Reader := TUtf8JsonReader.Create(Span);
  if (not Reader.Read) or (Reader.TokenType <> TJsonTokenType.StartObject) then
    raise EMessengerCodecError.Create('Message envelope must be a JSON object');

  while Reader.Read do
  begin
    if Reader.TokenType = TJsonTokenType.EndObject then
      Break;
    if Reader.TokenType <> TJsonTokenType.PropertyName then
      raise EMessengerCodecError.Create('Invalid message envelope');

    PropertyName := Reader.GetString;
    if not Reader.Read then
      raise EMessengerCodecError.Create('Unexpected end of message envelope');

    if PropertyName = 'version' then
    begin
      VersionValue := Reader.GetInt64;
      if (VersionValue < Low(Integer)) or (VersionValue > High(Integer)) then
        raise EMessengerCodecError.Create('Message version is outside the supported integer range');
      Result.Version := Integer(VersionValue);
    end
    else if PropertyName = 'message_id' then
      Result.MessageId := Reader.GetString
    else if PropertyName = 'client_message_id' then
      Result.ClientMessageId := Reader.GetString
    else if PropertyName = 'conversation_id' then
      Result.ConversationId := Reader.GetString
    else if PropertyName = 'sender_user_id' then
      Result.SenderUserId := Reader.GetString
    else if PropertyName = 'kind' then
    begin
      KindText := Reader.GetString;
      Result.Kind := StringToMessageKind(KindText);
    end
    else if PropertyName = 'created_at_unix_ms' then
      Result.CreatedAtUnixMs := Reader.GetInt64
    else if PropertyName = 'payload' then
      Result.PayloadJson := ReadCurrentJsonValue(Reader)
    else
      ReadCurrentJsonValue(Reader);
  end;

  TMessengerValidator.ValidateMessage(Result);
end;

end.
