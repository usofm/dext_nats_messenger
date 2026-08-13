unit Dext.Messenger.Client.Http;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Net.HttpClient,
  System.Net.URLClient;

type
  EMessengerHttpClientError = class(Exception);

  TMessengerHttpSendResult = record
  public
    MessageId: string;
    ConversationId: string;
    Sequence: Int64;
    Duplicate: Boolean;
  end;

  TMessengerHttpClient = class
  private
    FHttp: THTTPClient;
    FBaseUrl: string;
    FBearerToken: string;
    function Url(const APath: string): string;
    function ExecuteJson(const AMethod, APath, AJson: string): string;
    class function ParseSendResult(const AJson: string): TMessengerHttpSendResult; static;
  public
    constructor Create(const ABaseUrl: string);
    destructor Destroy; override;
    procedure SetBearerToken(const AToken: string);

    function SendMessage(const AClientMessageId, AConversationId,
      ADestinationType, ADestinationId, AKind, APayloadJson: string):
      TMessengerHttpSendResult;

    function SyncConversationJson(const AConversationId: string;
      AAfterSequence: Int64; ALimit: Integer = 100): string;

    procedure MarkDelivered(const AConversationId: string; ASequence: Int64);
    procedure MarkRead(const AConversationId: string; ASequence: Int64);

    function CreateUploadJson(const AFileName, AContentType: string;
      ASizeBytes: Int64): string;
    function CommitUploadJson(const AMediaId, ASha256Hex: string;
      AActualSizeBytes: Int64): string;
    function ResolveMediaJson(const AMediaId: string): string;
  end;

implementation

function JsonStringValue(const AValue: string): TJSONString;
begin
  Result := TJSONString.Create(AValue);
end;

constructor TMessengerHttpClient.Create(const ABaseUrl: string);
begin
  inherited Create;
  if Trim(ABaseUrl) = '' then
    raise EArgumentException.Create('base_url is required');
  FBaseUrl := ABaseUrl.TrimRight(['/']);
  FHttp := THTTPClient.Create;
  FHttp.ConnectionTimeout := 10000;
  FHttp.ResponseTimeout := 30000;
end;

destructor TMessengerHttpClient.Destroy;
begin
  FHttp.Free;
  inherited;
end;

procedure TMessengerHttpClient.SetBearerToken(const AToken: string);
begin
  FBearerToken := Trim(AToken);
end;

function TMessengerHttpClient.Url(const APath: string): string;
begin
  if APath.StartsWith('/') then
    Result := FBaseUrl + APath
  else
    Result := FBaseUrl + '/' + APath;
end;

function TMessengerHttpClient.ExecuteJson(const AMethod, APath,
  AJson: string): string;
var
  Req: IHTTPRequest;
  Resp: IHTTPResponse;
  Body: TStringStream;
begin
  Body := TStringStream.Create(AJson, TEncoding.UTF8);
  try
    Req := FHttp.GetRequest(AMethod, Url(APath));
    Req.AddHeader('Accept', 'application/json');
    Req.AddHeader('Content-Type', 'application/json; charset=utf-8');
    if FBearerToken <> '' then
      Req.AddHeader('Authorization', 'Bearer ' + FBearerToken);
    Req.SourceStream := Body;
    Resp := FHttp.Execute(Req);
    Result := Resp.ContentAsString(TEncoding.UTF8);
    if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
      raise EMessengerHttpClientError.CreateFmt(
        'Gateway HTTP %d: %s', [Resp.StatusCode, Result]);
  finally
    Body.Free;
  end;
end;

class function TMessengerHttpClient.ParseSendResult(
  const AJson: string): TMessengerHttpSendResult;
var
  V: TJSONValue;
  O: TJSONObject;
begin
  Result := Default(TMessengerHttpSendResult);
  V := TJSONObject.ParseJSONValue(AJson);
  try
    if not (V is TJSONObject) then
      raise EMessengerHttpClientError.Create('Invalid send response JSON');
    O := TJSONObject(V);
    O.TryGetValue<string>('MessageId', Result.MessageId);
    if Result.MessageId = '' then O.TryGetValue<string>('messageId', Result.MessageId);
    O.TryGetValue<string>('ConversationId', Result.ConversationId);
    if Result.ConversationId = '' then O.TryGetValue<string>('conversationId', Result.ConversationId);
    if not O.TryGetValue<Int64>('Sequence', Result.Sequence) then
      O.TryGetValue<Int64>('sequence', Result.Sequence);
    if not O.TryGetValue<Boolean>('Duplicate', Result.Duplicate) then
      O.TryGetValue<Boolean>('duplicate', Result.Duplicate);
    if (Result.MessageId = '') or (Result.Sequence <= 0) then
      raise EMessengerHttpClientError.Create('Incomplete send response');
  finally
    V.Free;
  end;
end;

function TMessengerHttpClient.SendMessage(const AClientMessageId,
  AConversationId, ADestinationType, ADestinationId, AKind,
  APayloadJson: string): TMessengerHttpSendResult;
var
  O: TJSONObject;
  Json, Response: string;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('ClientMessageId', JsonStringValue(AClientMessageId));
    O.AddPair('ConversationId', JsonStringValue(AConversationId));
    O.AddPair('DestinationType', JsonStringValue(ADestinationType));
    O.AddPair('DestinationId', JsonStringValue(ADestinationId));
    O.AddPair('Kind', JsonStringValue(AKind));
    O.AddPair('PayloadJson', JsonStringValue(APayloadJson));
    Json := O.ToJSON;
  finally
    O.Free;
  end;
  Response := ExecuteJson('POST', '/api/messenger/messages', Json);
  Result := ParseSendResult(Response);
end;

function TMessengerHttpClient.SyncConversationJson(const AConversationId: string;
  AAfterSequence: Int64; ALimit: Integer): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('ConversationId', AConversationId);
    O.AddPair('AfterSequence', TJSONNumber.Create(AAfterSequence));
    O.AddPair('Limit', TJSONNumber.Create(ALimit));
    Result := ExecuteJson('POST', '/api/messenger/sync', O.ToJSON);
  finally
    O.Free;
  end;
end;

procedure TMessengerHttpClient.MarkDelivered(const AConversationId: string;
  ASequence: Int64);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('ConversationId', AConversationId);
    O.AddPair('Sequence', TJSONNumber.Create(ASequence));
    ExecuteJson('POST', '/api/messenger/cursors/delivered', O.ToJSON);
  finally
    O.Free;
  end;
end;

procedure TMessengerHttpClient.MarkRead(const AConversationId: string;
  ASequence: Int64);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('ConversationId', AConversationId);
    O.AddPair('Sequence', TJSONNumber.Create(ASequence));
    ExecuteJson('POST', '/api/messenger/cursors/read', O.ToJSON);
  finally
    O.Free;
  end;
end;

function TMessengerHttpClient.CreateUploadJson(const AFileName,
  AContentType: string; ASizeBytes: Int64): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('FileName', AFileName);
    O.AddPair('ContentType', AContentType);
    O.AddPair('SizeBytes', TJSONNumber.Create(ASizeBytes));
    Result := ExecuteJson('POST', '/api/messenger/media/uploads', O.ToJSON);
  finally
    O.Free;
  end;
end;

function TMessengerHttpClient.CommitUploadJson(const AMediaId, ASha256Hex: string;
  AActualSizeBytes: Int64): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('MediaId', AMediaId);
    O.AddPair('Sha256Hex', ASha256Hex);
    O.AddPair('ActualSizeBytes', TJSONNumber.Create(AActualSizeBytes));
    Result := ExecuteJson('POST', '/api/messenger/media/commit', O.ToJSON);
  finally
    O.Free;
  end;
end;

function TMessengerHttpClient.ResolveMediaJson(const AMediaId: string): string;
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.AddPair('MediaId', AMediaId);
    Result := ExecuteJson('POST', '/api/messenger/media/resolve', O.ToJSON);
  finally
    O.Free;
  end;
end;

end.
