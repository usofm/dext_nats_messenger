unit Dext.Messenger.Receipts;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models,
  Dext.Messenger.Gateway.Core,
  Dext.Messenger.Realtime;

type
  TMessengerReceiptCommand = record
  public
    MessageId: string;
    ConversationId: string;
    Sequence: Int64;
    State: TMessengerReceiptState;
  end;

  IMessengerReceiptStore = interface
    ['{5F6F2E9E-F3D8-4D60-B482-A93460524B46}']
    procedure RecordReceipt(const AReceipt: TMessengerReceipt;
      ASequence: Int64);
  end;

  IMessengerReceiptMessageGuard = interface
    ['{006F7EF4-9B73-4F03-BD5B-C12A2ED63B8F}']
    function CanReceipt(const AUserId, AMessageId,
      AConversationId: string; ASequence: Int64): Boolean;
  end;

  TMessengerReceiptService = class
  private
    FStore: IMessengerReceiptStore;
    FGuard: IMessengerReceiptMessageGuard;
    FRealtime: TMessengerRealtimeService;
    FClock: Dext.Messenger.Acceptance.IMessengerClock;
  public
    constructor Create(const AStore: IMessengerReceiptStore;
      const AGuard: IMessengerReceiptMessageGuard;
      ARealtime: TMessengerRealtimeService;
      const AClock: Dext.Messenger.Acceptance.IMessengerClock);
    procedure RecordFromSession(const ASession: TMessengerSession;
      const ACommand: TMessengerReceiptCommand);
  end;

implementation

uses
  Dext.Messenger.Acceptance;

constructor TMessengerReceiptService.Create(const AStore: IMessengerReceiptStore;
  const AGuard: IMessengerReceiptMessageGuard;
  ARealtime: TMessengerRealtimeService; const AClock: IMessengerClock);
begin
  inherited Create;
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  if AGuard = nil then raise EArgumentNilException.Create('AGuard');
  if not Assigned(ARealtime) then raise EArgumentNilException.Create('ARealtime');
  if AClock = nil then raise EArgumentNilException.Create('AClock');
  FStore := AStore;
  FGuard := AGuard;
  FRealtime := ARealtime;
  FClock := AClock;
end;

procedure TMessengerReceiptService.RecordFromSession(
  const ASession: TMessengerSession;
  const ACommand: TMessengerReceiptCommand);
var
  Receipt: TMessengerReceipt;
begin
  if not ASession.Authenticated then
    raise EMessengerSessionRejected.Create('Authenticated session required');
  if ASession.UserId = '' then raise EArgumentException.Create('user_id is required');
  if ASession.DeviceId = '' then raise EArgumentException.Create('device_id is required');
  if ACommand.MessageId = '' then raise EArgumentException.Create('message_id is required');
  if ACommand.ConversationId = '' then raise EArgumentException.Create('conversation_id is required');
  if ACommand.Sequence <= 0 then raise EArgumentOutOfRangeException.Create('Sequence');

  if not FGuard.CanReceipt(ASession.UserId, ACommand.MessageId,
    ACommand.ConversationId, ACommand.Sequence) then
    raise EMessengerSessionRejected.Create('Receipt target is not visible to this user');

  Receipt := TMessengerReceipt.CreateV1(
    ACommand.MessageId,
    ACommand.ConversationId,
    ASession.UserId,
    ASession.DeviceId,
    ACommand.State,
    FClock.UnixTimeMilliseconds);

  { Durable state first. Realtime notification may be retried/reconstructed from
    cursors and receipt history; it must never be the source of truth. }
  FStore.RecordReceipt(Receipt, ACommand.Sequence);
  FRealtime.PublishReceipt(Receipt);
end;

end.
