unit Dext.Messenger.Gateway.Hubs;

interface

uses
  System.SysUtils,
  System.Rtti,
  Dext.Web.Hubs.Hub,
  Dext.Web.Hubs.Types,
  Dext.Web.Hubs.Interfaces,
  Dext.Messenger.Models;

type
  { Thin connection Hub. Business commands are intentionally not implemented
    here because the current Dext Hub dispatcher constructs Hub instances with
    a parameterless constructor. Authenticated command handling belongs in the
    typed HTTP/application boundary until Dext exposes a DI Hub activator. }
  TMessengerHub = class(THub)
  public
    procedure OnConnectedAsync; override;
    [HubMethod]
    procedure Ping(const ANonce: string);
  end;

  IMessengerRealtimePush = interface
    ['{34418947-BA71-45E6-ADDB-27C5D60CE2F4}']
    procedure PushMessage(const ATargetUserId: string;
      const AMessage: TMessengerMessage);
    procedure PushPresence(const ATargetUserId: string;
      const AEventJson: string);
    procedure PushTyping(const ATargetUserId: string;
      const AEventJson: string);
    procedure PushReceipt(const ATargetUserId: string;
      const AReceiptJson: string);
  end;

  TMessengerHubRealtimePush = class(TInterfacedObject, IMessengerRealtimePush)
  public const
    ClientMessageMethod = 'Messenger.Message';
    ClientPresenceMethod = 'Messenger.Presence';
    ClientTypingMethod = 'Messenger.Typing';
    ClientReceiptMethod = 'Messenger.Receipt';
  private
    FHubContext: IHubContext;
  public
    constructor Create(const AHubContext: IHubContext);
    procedure PushMessage(const ATargetUserId: string;
      const AMessage: TMessengerMessage);
    procedure PushPresence(const ATargetUserId: string;
      const AEventJson: string);
    procedure PushTyping(const ATargetUserId: string;
      const AEventJson: string);
    procedure PushReceipt(const ATargetUserId: string;
      const AReceiptJson: string);
  end;

implementation

uses
  System.Classes,
  Dext.Messenger.Codec.Json;

{ TMessengerHub }

procedure TMessengerHub.OnConnectedAsync;
begin
  inherited;
  { Fail closed. Dext derives UserIdentifier from authenticated claims. An
    anonymous connection is not useful for the private messenger Hub. }
  if (Context = nil) or (Context.UserIdentifier = '') then
  begin
    Context.Abort;
    Exit;
  end;

  Clients.Caller.SendAsync('Messenger.Connected', Context.UserIdentifier);
end;

procedure TMessengerHub.Ping(const ANonce: string);
begin
  if Length(ANonce) > 128 then
    raise EArgumentOutOfRangeException.Create('ANonce');
  Clients.Caller.SendAsync('Messenger.Pong', ANonce);
end;

{ TMessengerHubRealtimePush }

constructor TMessengerHubRealtimePush.Create(const AHubContext: IHubContext);
begin
  inherited Create;
  if AHubContext = nil then
    raise EArgumentNilException.Create('AHubContext');
  FHubContext := AHubContext;
end;

procedure TMessengerHubRealtimePush.PushMessage(const ATargetUserId: string;
  const AMessage: TMessengerMessage);
var
  Payload: TBytes;
  Json: string;
begin
  if ATargetUserId = '' then
    raise EArgumentException.Create('target_user_id must not be empty');
  Payload := TMessengerJsonCodec.EncodeMessage(AMessage);
  Json := TEncoding.UTF8.GetString(Payload);
  FHubContext.Clients.User(ATargetUserId).SendAsync(ClientMessageMethod, Json);
end;

procedure TMessengerHubRealtimePush.PushPresence(const ATargetUserId,
  AEventJson: string);
begin
  if ATargetUserId = '' then raise EArgumentException.Create('target_user_id must not be empty');
  FHubContext.Clients.User(ATargetUserId).SendAsync(ClientPresenceMethod, AEventJson);
end;

procedure TMessengerHubRealtimePush.PushTyping(const ATargetUserId,
  AEventJson: string);
begin
  if ATargetUserId = '' then raise EArgumentException.Create('target_user_id must not be empty');
  FHubContext.Clients.User(ATargetUserId).SendAsync(ClientTypingMethod, AEventJson);
end;

procedure TMessengerHubRealtimePush.PushReceipt(const ATargetUserId,
  AReceiptJson: string);
begin
  if ATargetUserId = '' then raise EArgumentException.Create('target_user_id must not be empty');
  FHubContext.Clients.User(ATargetUserId).SendAsync(ClientReceiptMethod, AReceiptJson);
end;

end.
