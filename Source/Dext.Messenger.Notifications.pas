unit Dext.Messenger.Notifications;

interface

uses
  System.SysUtils,
  Dext.Messenger.Commands;

type
  TMessengerPushTarget = record
  public
    UserId: string;
    DeviceId: string;
    Provider: string;
    Token: string;
  end;

  TMessengerPushNotification = record
  public
    NotificationId: string;
    UserId: string;
    ConversationId: string;
    MessageId: string;
    Sequence: Int64;
    Kind: string;
    Title: string;
    Body: string;
    DataJson: string;
  end;

  IMessengerPushTargetStore = interface
    ['{73798295-0887-4A6F-A755-80B1F3BA42E7}']
    function ActiveTargetsForUser(const AUserId: string): TArray<TMessengerPushTarget>;
  end;

  IMessengerPushProvider = interface
    ['{34F51D08-9FEA-4E48-BB91-8A1913E8335D}']
    procedure Send(const ATarget: TMessengerPushTarget;
      const ANotification: TMessengerPushNotification);
  end;

  IMessengerOnlineState = interface
    ['{5868E54C-91A6-45C8-951F-31B10019A064}']
    function IsUserOnline(const AUserId: string): Boolean;
  end;

  TMessengerNotificationOptions = record
  public
    IncludeMessagePreview: Boolean;
    GenericTitle: string;
    GenericBody: string;
    class function PrivacyFirst: TMessengerNotificationOptions; static;
  end;

  TMessengerNotificationService = class
  private
    FTargets: IMessengerPushTargetStore;
    FProvider: IMessengerPushProvider;
    FOnline: IMessengerOnlineState;
    FOptions: TMessengerNotificationOptions;
  public
    constructor Create(const ATargets: IMessengerPushTargetStore;
      const AProvider: IMessengerPushProvider;
      const AOnline: IMessengerOnlineState;
      const AOptions: TMessengerNotificationOptions);
    function NotifyIfOffline(const AAccepted: TMessengerAcceptedMessage): Integer;
  end;

implementation

class function TMessengerNotificationOptions.PrivacyFirst:
  TMessengerNotificationOptions;
begin
  Result := Default(TMessengerNotificationOptions);
  Result.IncludeMessagePreview := False;
  Result.GenericTitle := 'New message';
  Result.GenericBody := 'Open the app to view it.';
end;

constructor TMessengerNotificationService.Create(
  const ATargets: IMessengerPushTargetStore;
  const AProvider: IMessengerPushProvider;
  const AOnline: IMessengerOnlineState;
  const AOptions: TMessengerNotificationOptions);
begin
  inherited Create;
  if ATargets = nil then raise EArgumentNilException.Create('ATargets');
  if AProvider = nil then raise EArgumentNilException.Create('AProvider');
  if AOnline = nil then raise EArgumentNilException.Create('AOnline');
  FTargets := ATargets;
  FProvider := AProvider;
  FOnline := AOnline;
  FOptions := AOptions;
end;

function TMessengerNotificationService.NotifyIfOffline(
  const AAccepted: TMessengerAcceptedMessage): Integer;
var
  Targets: TArray<TMessengerPushTarget>;
  Target: TMessengerPushTarget;
  N: TMessengerPushNotification;
begin
  Result := 0;
  { Group fan-out requires resolving group recipients; this service operates on
    a concrete user destination. A group notification worker should enumerate
    eligible offline members in bounded pages and call the same provider. }
  if not AAccepted.IsDirect then Exit;
  if FOnline.IsUserOnline(AAccepted.DestinationId) then Exit;

  N := Default(TMessengerPushNotification);
  N.NotificationId := 'msg:' + AAccepted.Message.MessageId;
  N.UserId := AAccepted.DestinationId;
  N.ConversationId := AAccepted.Message.ConversationId;
  N.MessageId := AAccepted.Message.MessageId;
  N.Sequence := AAccepted.Sequence;
  N.Kind := 'message';
  N.Title := FOptions.GenericTitle;
  N.Body := FOptions.GenericBody;
  N.DataJson := Format(
    '{"conversation_id":"%s","message_id":"%s","sequence":%d}',
    [AAccepted.Message.ConversationId, AAccepted.Message.MessageId,
     AAccepted.Sequence]);

  { Privacy-first default intentionally does not copy PayloadJson into push.
    Preview rendering, when enabled by product policy, must be a separate
    sanitized formatter rather than raw payload injection. }
  Targets := FTargets.ActiveTargetsForUser(AAccepted.DestinationId);
  for Target in Targets do
  begin
    if (Target.Token = '') or (Target.Provider = '') then Continue;
    FProvider.Send(Target, N);
    Inc(Result);
  end;
end;

end.
