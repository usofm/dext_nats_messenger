unit VCLClient.Main;

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Dext.Net.Nats,
  Dext.Messenger.Models,
  Dext.Messenger.Transport,
  Dext.Messenger.Nats,
  Dext.Messenger.MessageService;

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
    procedure FormDestroy(Sender: TObject);
    procedure btnConnectClick(Sender: TObject);
    procedure btnDisconnectClick(Sender: TObject);
    procedure btnSendClick(Sender: TObject);
  private
    FNats: TDextNatsClient;
    FTransport: IMessengerTransport;
    FMessageService: IMessengerMessageService;
    FSubscription: IMessengerSubscription;
    procedure SetConnectedUi(AConnected: Boolean);
    procedure DisconnectClient;
    procedure AppendChat(const ALine: string);
    procedure HandleIncoming(const AMessage: TMessengerMessage);
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
  Result := GUIDToString(G);
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
  Result := LowerCase(Result);
end;

class function TMainForm.UnixMsNow: Int64;
begin
  Result := DateTimeToUnix(Now, False) * Int64(1000);
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
  edtHost.Enabled := not AConnected;
  edtPort.Enabled := not AConnected;
  edtUserId.Enabled := not AConnected;
  if AConnected then
    lblStatus.Caption := 'Connected as ' + edtUserId.Text
  else
    lblStatus.Caption := 'Disconnected';
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

  if not TryStrToInt(Trim(edtPort.Text), PortValue) or
     (PortValue < 1) or (PortValue > 65535) then
    raise Exception.Create('Invalid NATS port');

  DisconnectClient;

  Options := TDextNatsOptions.CreateDefault;
  Options.Name := 'dext-messenger-vcl-' + UserId;
  FNats := TDextNatsClient.Create(Options);
  try
    FNats.Connect(Trim(edtHost.Text), Word(PortValue));

    FTransport := TDextMessengerNatsTransport.Create(FNats, False);
    FMessageService := TMessengerMessageService.Create(FTransport);
    FSubscription := FMessageService.SubscribeUser(UserId, HandleIncoming);

    SetConnectedUi(True);
    AppendChat('[SYSTEM] Connected to NATS and subscribed to user delivery subject.');
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
  TargetUserId: string;
  TextValue: string;
  Message: TMessengerMessage;
  MessageId: string;
begin
  if FMessageService = nil then
    raise Exception.Create('Not connected');

  TargetUserId := Trim(edtTargetUserId.Text);
  TextValue := edtMessage.Text;
  if TargetUserId = '' then
    raise Exception.Create('Target user ID is required');
  if TextValue = '' then
    Exit;

  MessageId := NewId;
  Message := TMessengerMessage.CreateV1(
    MessageId,
    NewId,
    'direct-' + edtUserId.Text + '-' + TargetUserId,
    edtUserId.Text,
    mmkText,
    UnixMsNow,
    '{"text":' + JsonString(TextValue) + '}'
  );

  FMessageService.SendToUser(TargetUserId, Message);
  AppendChat(Format('[OUT -> %s] %s', [TargetUserId, TextValue]));
  edtMessage.Clear;
end;

procedure TMainForm.DisconnectClient;
begin
  FSubscription := nil;
  FMessageService := nil;
  FTransport := nil;

  if Assigned(FNats) then
  begin
    try
      FNats.Disconnect;
    except
      { UI shutdown/disconnect should continue even if socket teardown reports an error. }
    end;
    FreeAndNil(FNats);
  end;

  SetConnectedUi(False);
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  DisconnectClient;
end;

end.
