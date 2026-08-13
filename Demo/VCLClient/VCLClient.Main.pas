unit VCLClient.Main;

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.JSON,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Dext.Net.Nats,
  Dext.Messenger.Models,
  Dext.Messenger.Transport,
  Dext.Messenger.Nats,
  Dext.Messenger.MessageService,
  Dext.Messenger.Client.Http;

type
  TMainForm = class(TForm)
    pnlTop: TPanel;
    lblHost: TLabel;
    edtHost: TEdit;
    lblPort: TLabel;
    edtPort: TEdit;
    lblUser: TLabel;
    edtUserId: TEdit;
    btnConnect: TButton;
    btnDisconnect: TButton;
    pnlSend: TPanel;
    lblTarget: TLabel;
    edtTargetUserId: TEdit;
    edtMessage: TEdit;
    btnSend: TButton;
    memChat: TMemo;
    lblStatus: TLabel;
    chkProduction: TCheckBox;
    lblApiUrl: TLabel;
    edtApiUrl: TEdit;
    lblJwt: TLabel;
    edtJwt: TEdit;
    lblConversation: TLabel;
    edtConversationId: TEdit;
    tmrSync: TTimer;
    procedure FormDestroy(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
    procedure chkProductionClick(Sender: TObject);
    procedure tmrSyncTimer(Sender: TObject);
  private
    FNats: TDextNatsClient;
    FTransport: IMessengerTransport;
    FMessageService: IMessengerMessageService;
    FSubscription: IMessengerSubscription;
    FHttp: TMessengerHttpClient;
    FLastSequence: Int64;
    procedure SetConnectedUi(AConnected: Boolean);
    procedure UpdateModeUi;
    procedure DisconnectClient;
    procedure AppendChat(const ALine: string);
    procedure HandleIncoming(const AMessage: TMessengerMessage);
    procedure SyncProduction;
    procedure ProcessSyncJson(const AJson: string);
    class function NewId: string; static;
    class function UnixMsNow: Int64; static;
    class function JsonString(const AValue: string): string; static;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

class function TMainForm.NewId: string;
var
  G: TGUID;
begin
  CreateGUID(G);
  Result := LowerCase(GUIDToString(G));
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
end;

class function TMainForm.UnixMsNow: Int64;
var
  Utc: TDateTime;
begin
  Utc := TTimeZone.Local.ToUniversalTime(Now);
  Result := DateTimeToUnix(Utc, False) * Int64(1000) + MilliSecondOf(Utc);
end;

class function TMainForm.JsonString(const AValue: string): string;
var
  S: string;
begin
  S := StringReplace(AValue, '\', '\\', [rfReplaceAll]);
  S := StringReplace(S, '"', '\"', [rfReplaceAll]);
  S := StringReplace(S, #13#10, '\n', [rfReplaceAll]);
  S := StringReplace(S, #13, '\n', [rfReplaceAll]);
  S := StringReplace(S, #10, '\n', [rfReplaceAll]);
  Result := '"' + S + '"';
end;

procedure TMainForm.AppendChat(const ALine: string);
begin
  if TThread.Current.ThreadID = MainThreadID then
    memChat.Lines.Add(ALine)
  else
    TThread.Queue(nil,
      procedure
      begin
        if not (csDestroying in ComponentState) then
          memChat.Lines.Add(ALine);
      end);
end;

procedure TMainForm.SetConnectedUi(AConnected: Boolean);
begin
  btnConnect.Enabled := not AConnected;
  btnDisconnect.Enabled := AConnected;
  btnSend.Enabled := AConnected;
  chkProduction.Enabled := not AConnected;
  edtUserId.Enabled := not AConnected;
  edtApiUrl.Enabled := (not AConnected) and chkProduction.Checked;
  edtJwt.Enabled := (not AConnected) and chkProduction.Checked;
  edtHost.Enabled := (not AConnected) and (not chkProduction.Checked);
  edtPort.Enabled := (not AConnected) and (not chkProduction.Checked);
  edtConversationId.Enabled := not AConnected;
  tmrSync.Enabled := AConnected and chkProduction.Checked;

  if AConnected then
  begin
    if chkProduction.Checked then
      lblStatus.Caption := 'Production Gateway connected as ' + edtUserId.Text
    else
      lblStatus.Caption := 'Developer NATS connected as ' + edtUserId.Text;
  end
  else
    lblStatus.Caption := 'Disconnected';
end;

procedure TMainForm.UpdateModeUi;
begin
  edtApiUrl.Enabled := chkProduction.Checked and btnConnect.Enabled;
  edtJwt.Enabled := chkProduction.Checked and btnConnect.Enabled;
  edtHost.Enabled := (not chkProduction.Checked) and btnConnect.Enabled;
  edtPort.Enabled := (not chkProduction.Checked) and btnConnect.Enabled;
end;

procedure TMainForm.chkProductionClick(Sender: TObject);
begin
  UpdateModeUi;
end;

procedure TMainForm.HandleIncoming(const AMessage: TMessengerMessage);
begin
  AppendChat(Format('[IN] %s: %s', [AMessage.SenderUserId, AMessage.PayloadJson]));
end;

procedure TMainForm.btnConnectClick(Sender: TObject);
var
  Options: TDextNatsOptions;
  PortValue: Integer;
  UserId: string;
begin
  UserId := Trim(edtUserId.Text);
  if UserId = '' then
    raise Exception.Create('User ID is required');

  DisconnectClient;
  FLastSequence := 0;

  if chkProduction.Checked then
  begin
    if Trim(edtApiUrl.Text) = '' then
      raise Exception.Create('Gateway API URL is required');
    if Trim(edtJwt.Text) = '' then
      raise Exception.Create('JWT is required in production mode');
    if Trim(edtConversationId.Text) = '' then
      raise Exception.Create('Conversation ID is required');

    FHttp := TMessengerHttpClient.Create(Trim(edtApiUrl.Text));
    FHttp.SetBearerToken(Trim(edtJwt.Text));
    SetConnectedUi(True);
    AppendChat('[SYSTEM] Production mode: HTTP Gateway commands + cursor sync.');
    SyncProduction;
    Exit;
  end;

  if not TryStrToInt(Trim(edtPort.Text), PortValue) or
     (PortValue < 1) or (PortValue > 65535) then
    raise Exception.Create('Invalid NATS port');

  Options := TDextNatsOptions.CreateDefault;
  Options.Name := 'dext-messenger-vcl-' + UserId;
  FNats := TDextNatsClient.Create(Options);
  try
    FNats.Connect(Trim(edtHost.Text), Word(PortValue));
    FTransport := TDextMessengerNatsTransport.Create(FNats, False);
    FMessageService := TMessengerMessageService.Create(FTransport);
    FSubscription := FMessageService.SubscribeUser(UserId, HandleIncoming);
    SetConnectedUi(True);
    AppendChat('[SYSTEM] Developer mode: direct NATS subject subscription.');
  except
    DisconnectClient;
    raise;
  end;
end;

procedure TMainForm.btnDisconnectClick(Sender: TObject);
begin
  DisconnectClient;
end;

procedure TMainForm.btnSendClick(Sender: TObject);
var
  TargetUserId, TextValue, Payload, MessageId: string;
  Message: TMessengerMessage;
  SendResult: TMessengerHttpSendResult;
begin
  TargetUserId := Trim(edtTargetUserId.Text);
  TextValue := edtMessage.Text;
  if TargetUserId = '' then
    raise Exception.Create('Target user ID is required');
  if TextValue = '' then Exit;

  Payload := '{"text":' + JsonString(TextValue) + '}';

  if chkProduction.Checked then
  begin
    if not Assigned(FHttp) then raise Exception.Create('Not connected');
    SendResult := FHttp.SendMessage(NewId, Trim(edtConversationId.Text),
      'user', TargetUserId, 'text', Payload);
    if SendResult.Sequence > FLastSequence then
      FLastSequence := SendResult.Sequence;
    AppendChat(Format('[OUT -> %s] %s (seq=%d, duplicate=%s)',
      [TargetUserId, TextValue, SendResult.Sequence,
       BoolToStr(SendResult.Duplicate, True)]));
    edtMessage.Clear;
    Exit;
  end;

  if FMessageService = nil then raise Exception.Create('Not connected');
  MessageId := NewId;
  Message := TMessengerMessage.CreateV1(
    MessageId,
    NewId,
    Trim(edtConversationId.Text),
    edtUserId.Text,
    mmkText,
    UnixMsNow,
    Payload);
  FMessageService.SendToUser(TargetUserId, Message);
  AppendChat(Format('[OUT -> %s] %s', [TargetUserId, TextValue]));
  edtMessage.Clear;
end;

procedure TMainForm.ProcessSyncJson(const AJson: string);
var
  Root, Item, MessageValue: TJSONValue;
  Obj, ItemObj, MessageObj: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
  Seq: Int64;
  Sender, Payload: string;
begin
  Root := TJSONObject.ParseJSONValue(AJson);
  try
    if not (Root is TJSONObject) then Exit;
    Obj := TJSONObject(Root);
    Arr := Obj.GetValue<TJSONArray>('Messages');
    if Arr = nil then Arr := Obj.GetValue<TJSONArray>('messages');
    if Arr = nil then Exit;

    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.Items[I];
      if not (Item is TJSONObject) then Continue;
      ItemObj := TJSONObject(Item);
      Seq := 0;
      if not ItemObj.TryGetValue<Int64>('Sequence', Seq) then
        ItemObj.TryGetValue<Int64>('sequence', Seq);
      if Seq <= FLastSequence then Continue;

      MessageValue := ItemObj.GetValue('Message');
      if MessageValue = nil then MessageValue := ItemObj.GetValue('message');
      if MessageValue is TJSONObject then
      begin
        MessageObj := TJSONObject(MessageValue);
        Sender := '';
        Payload := '';
        if not MessageObj.TryGetValue<string>('SenderUserId', Sender) then
          MessageObj.TryGetValue<string>('senderUserId', Sender);
        if not MessageObj.TryGetValue<string>('PayloadJson', Payload) then
          MessageObj.TryGetValue<string>('payloadJson', Payload);
        AppendChat(Format('[SYNC #%d] %s: %s', [Seq, Sender, Payload]));
      end;
      if Seq > FLastSequence then FLastSequence := Seq;
    end;

    if FLastSequence > 0 then
      FHttp.MarkDelivered(Trim(edtConversationId.Text), FLastSequence);
  finally
    Root.Free;
  end;
end;

procedure TMainForm.SyncProduction;
var
  Json: string;
begin
  if not Assigned(FHttp) then Exit;
  try
    Json := FHttp.SyncConversationJson(Trim(edtConversationId.Text),
      FLastSequence, 100);
    ProcessSyncJson(Json);
  except
    on E: Exception do
      AppendChat('[SYNC ERROR] ' + E.Message);
  end;
end;

procedure TMainForm.tmrSyncTimer(Sender: TObject);
begin
  SyncProduction;
end;

procedure TMainForm.DisconnectClient;
begin
  tmrSync.Enabled := False;
  FreeAndNil(FHttp);
  FSubscription := nil;
  FMessageService := nil;
  FTransport := nil;

  if Assigned(FNats) then
  begin
    try FNats.Disconnect; except end;
    FreeAndNil(FNats);
  end;

  SetConnectedUi(False);
  UpdateModeUi;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  DisconnectClient;
end;

end.
