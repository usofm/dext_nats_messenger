unit Dext.Messenger.Validation;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models;

type
  EMessengerValidationError = class(Exception);

  TMessengerValidator = record
  public const
    CurrentProtocolVersion = 1;
  public
    class procedure ValidateMessage(const AMessage: TMessengerMessage); static;
    class procedure ValidatePresence(const AEvent: TMessengerPresenceEvent); static;
    class procedure ValidateTyping(const AEvent: TMessengerTypingEvent); static;
    class procedure ValidateReceipt(const AReceipt: TMessengerReceipt); static;
  end;

implementation

procedure RequireValue(const AName, AValue: string);
begin
  if AValue = '' then
    raise EMessengerValidationError.CreateFmt('%s must not be empty', [AName]);
end;

procedure RequireVersion(AVersion: Integer);
begin
  if AVersion <> TMessengerValidator.CurrentProtocolVersion then
    raise EMessengerValidationError.CreateFmt(
      'Unsupported messenger protocol version %d',
      [AVersion]
    );
end;

procedure RequireTimestamp(const AName: string; AValue: Int64);
begin
  if AValue <= 0 then
    raise EMessengerValidationError.CreateFmt('%s must be greater than zero', [AName]);
end;

class procedure TMessengerValidator.ValidateMessage(const AMessage: TMessengerMessage);
begin
  RequireVersion(AMessage.Version);
  RequireValue('message_id', AMessage.MessageId);
  RequireValue('client_message_id', AMessage.ClientMessageId);
  RequireValue('conversation_id', AMessage.ConversationId);
  RequireValue('sender_user_id', AMessage.SenderUserId);
  RequireTimestamp('created_at_unix_ms', AMessage.CreatedAtUnixMs);

  if (AMessage.Kind <> mmkSystem) and (AMessage.PayloadJson = '') then
    raise EMessengerValidationError.Create('payload_json must not be empty');
end;

class procedure TMessengerValidator.ValidatePresence(const AEvent: TMessengerPresenceEvent);
begin
  RequireVersion(AEvent.Version);
  RequireValue('user_id', AEvent.UserId);
  RequireValue('device_id', AEvent.DeviceId);
  RequireValue('gateway_id', AEvent.GatewayId);
  RequireTimestamp('at_unix_ms', AEvent.AtUnixMs);
end;

class procedure TMessengerValidator.ValidateTyping(const AEvent: TMessengerTypingEvent);
begin
  RequireVersion(AEvent.Version);
  RequireValue('conversation_id', AEvent.ConversationId);
  RequireValue('user_id', AEvent.UserId);
  RequireTimestamp('at_unix_ms', AEvent.AtUnixMs);
end;

class procedure TMessengerValidator.ValidateReceipt(const AReceipt: TMessengerReceipt);
begin
  RequireVersion(AReceipt.Version);
  RequireValue('message_id', AReceipt.MessageId);
  RequireValue('conversation_id', AReceipt.ConversationId);
  RequireValue('user_id', AReceipt.UserId);
  RequireValue('device_id', AReceipt.DeviceId);
  RequireTimestamp('at_unix_ms', AReceipt.AtUnixMs);
end;

end.
