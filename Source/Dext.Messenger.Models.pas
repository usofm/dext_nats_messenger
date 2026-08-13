unit Dext.Messenger.Models;

interface

uses
  System.SysUtils;

type
  TMessengerMessageKind = (
    mmkText,
    mmkImage,
    mmkAudio,
    mmkVideo,
    mmkFile,
    mmkSystem
  );

  TMessengerPresenceState = (
    mpsOnline,
    mpsOffline,
    mpsHeartbeat
  );

  TMessengerReceiptState = (
    mrsDelivered,
    mrsRead
  );

  TMessengerMessage = record
  public
    Version: Integer;
    MessageId: string;
    ClientMessageId: string;
    ConversationId: string;
    SenderUserId: string;
    Kind: TMessengerMessageKind;
    CreatedAtUnixMs: Int64;
    PayloadJson: string;

    class function CreateV1(
      const AMessageId,
      AClientMessageId,
      AConversationId,
      ASenderUserId: string;
      AKind: TMessengerMessageKind;
      ACreatedAtUnixMs: Int64;
      const APayloadJson: string
    ): TMessengerMessage; static;
  end;

  TMessengerPresenceEvent = record
  public
    Version: Integer;
    UserId: string;
    DeviceId: string;
    GatewayId: string;
    State: TMessengerPresenceState;
    AtUnixMs: Int64;

    class function CreateV1(
      const AUserId, ADeviceId, AGatewayId: string;
      AState: TMessengerPresenceState;
      AAtUnixMs: Int64
    ): TMessengerPresenceEvent; static;
  end;

  TMessengerTypingEvent = record
  public
    Version: Integer;
    ConversationId: string;
    UserId: string;
    IsTyping: Boolean;
    AtUnixMs: Int64;

    class function CreateV1(
      const AConversationId, AUserId: string;
      AIsTyping: Boolean;
      AAtUnixMs: Int64
    ): TMessengerTypingEvent; static;
  end;

  TMessengerReceipt = record
  public
    Version: Integer;
    MessageId: string;
    ConversationId: string;
    UserId: string;
    DeviceId: string;
    State: TMessengerReceiptState;
    AtUnixMs: Int64;

    class function CreateV1(
      const AMessageId,
      AConversationId,
      AUserId,
      ADeviceId: string;
      AState: TMessengerReceiptState;
      AAtUnixMs: Int64
    ): TMessengerReceipt; static;
  end;

implementation

{ TMessengerMessage }

class function TMessengerMessage.CreateV1(
  const AMessageId,
  AClientMessageId,
  AConversationId,
  ASenderUserId: string;
  AKind: TMessengerMessageKind;
  ACreatedAtUnixMs: Int64;
  const APayloadJson: string
): TMessengerMessage;
begin
  Result.Version := 1;
  Result.MessageId := AMessageId;
  Result.ClientMessageId := AClientMessageId;
  Result.ConversationId := AConversationId;
  Result.SenderUserId := ASenderUserId;
  Result.Kind := AKind;
  Result.CreatedAtUnixMs := ACreatedAtUnixMs;
  Result.PayloadJson := APayloadJson;
end;

{ TMessengerPresenceEvent }

class function TMessengerPresenceEvent.CreateV1(
  const AUserId, ADeviceId, AGatewayId: string;
  AState: TMessengerPresenceState;
  AAtUnixMs: Int64
): TMessengerPresenceEvent;
begin
  Result.Version := 1;
  Result.UserId := AUserId;
  Result.DeviceId := ADeviceId;
  Result.GatewayId := AGatewayId;
  Result.State := AState;
  Result.AtUnixMs := AAtUnixMs;
end;

{ TMessengerTypingEvent }

class function TMessengerTypingEvent.CreateV1(
  const AConversationId, AUserId: string;
  AIsTyping: Boolean;
  AAtUnixMs: Int64
): TMessengerTypingEvent;
begin
  Result.Version := 1;
  Result.ConversationId := AConversationId;
  Result.UserId := AUserId;
  Result.IsTyping := AIsTyping;
  Result.AtUnixMs := AAtUnixMs;
end;

{ TMessengerReceipt }

class function TMessengerReceipt.CreateV1(
  const AMessageId,
  AConversationId,
  AUserId,
  ADeviceId: string;
  AState: TMessengerReceiptState;
  AAtUnixMs: Int64
): TMessengerReceipt;
begin
  Result.Version := 1;
  Result.MessageId := AMessageId;
  Result.ConversationId := AConversationId;
  Result.UserId := AUserId;
  Result.DeviceId := ADeviceId;
  Result.State := AState;
  Result.AtUnixMs := AAtUnixMs;
end;

end.
