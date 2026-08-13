unit Dext.Messenger.Persistence.PostgreSQL.Receipts;

interface

uses
  System.SysUtils,
  Dext.Entity.Drivers.Interfaces,
  Dext.Messenger.Models,
  Dext.Messenger.Receipts,
  Dext.Messenger.Persistence.DbContext;

type
  TMessengerPostgreSQLReceiptStore = class(TInterfacedObject,
    IMessengerReceiptStore, IMessengerReceiptMessageGuard)
  private
    FContext: TMessengerDbContext;
    class function ReceiptStateDb(AState: TMessengerReceiptState): Integer; static;
    class function UnixMsToUtc(AValue: Int64): TDateTime; static;
    procedure InsertReceipt(const AReceipt: TMessengerReceipt;
      AState: TMessengerReceiptState);
  public
    constructor Create(AContext: TMessengerDbContext);
    procedure RecordReceipt(const AReceipt: TMessengerReceipt;
      ASequence: Int64);
    function CanReceipt(const AUserId, AMessageId,
      AConversationId: string; ASequence: Int64): Boolean;
  end;

implementation

uses
  System.Rtti,
  System.DateUtils;

const
  SQL_CAN_RECEIPT =
    'select exists(select 1 from messenger_messages m ' +
    'join messenger_members mb on mb.conversation_id=m.conversation_id ' +
    'and mb.user_id=:user_id and mb.left_at is null ' +
    'where m.message_id=:message_id and m.conversation_id=:conversation_id ' +
    'and m.sequence_no=:sequence_no and m.deleted_at is null)';

  SQL_INSERT_RECEIPT =
    'insert into messenger_message_receipts(' +
    'message_id,user_id,device_id,receipt_state,at_time) ' +
    'values(:message_id,:user_id,:device_id,:receipt_state,:at_time) ' +
    'on conflict(message_id,user_id,device_id,receipt_state) do nothing';

  SQL_ADVANCE_DELIVERED =
    'insert into messenger_user_cursors(user_id,conversation_id,delivered_sequence,read_sequence) ' +
    'values(:user_id,:conversation_id,:seq,0) ' +
    'on conflict(user_id,conversation_id) do update set ' +
    'delivered_sequence=greatest(messenger_user_cursors.delivered_sequence,excluded.delivered_sequence), ' +
    'updated_at=now()';

  SQL_ADVANCE_READ =
    'insert into messenger_user_cursors(user_id,conversation_id,delivered_sequence,read_sequence) ' +
    'values(:user_id,:conversation_id,:seq,:seq2) ' +
    'on conflict(user_id,conversation_id) do update set ' +
    'delivered_sequence=greatest(messenger_user_cursors.delivered_sequence,excluded.delivered_sequence), ' +
    'read_sequence=greatest(messenger_user_cursors.read_sequence,excluded.read_sequence), ' +
    'updated_at=now()';

constructor TMessengerPostgreSQLReceiptStore.Create(AContext: TMessengerDbContext);
begin
  inherited Create;
  if not Assigned(AContext) then raise EArgumentNilException.Create('AContext');
  FContext := AContext;
end;

class function TMessengerPostgreSQLReceiptStore.ReceiptStateDb(
  AState: TMessengerReceiptState): Integer;
begin
  case AState of
    mrsDelivered: Result := 1;
    mrsRead: Result := 2;
  else
    raise EArgumentOutOfRangeException.Create('receipt state');
  end;
end;

class function TMessengerPostgreSQLReceiptStore.UnixMsToUtc(
  AValue: Int64): TDateTime;
begin
  Result := UnixToDateTime(AValue div 1000, True) +
    (AValue mod 1000) / MSecsPerDay;
end;

function TMessengerPostgreSQLReceiptStore.CanReceipt(const AUserId,
  AMessageId, AConversationId: string; ASequence: Int64): Boolean;
var
  Cmd: IDbCommand;
  R: IDbReader;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_CAN_RECEIPT);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('message_id', TValue.From<string>(AMessageId));
  Cmd.AddParam('conversation_id', TValue.From<string>(AConversationId));
  Cmd.AddParam('sequence_no', TValue.From<Int64>(ASequence));
  R := Cmd.ExecuteQuery;
  try
    Result := R.Next and R.GetBoolean(0);
  finally
    R.Close;
  end;
end;

procedure TMessengerPostgreSQLReceiptStore.InsertReceipt(
  const AReceipt: TMessengerReceipt; AState: TMessengerReceiptState);
var
  Cmd: IDbCommand;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_INSERT_RECEIPT);
  Cmd.AddParam('message_id', TValue.From<string>(AReceipt.MessageId));
  Cmd.AddParam('user_id', TValue.From<string>(AReceipt.UserId));
  Cmd.AddParam('device_id', TValue.From<string>(AReceipt.DeviceId));
  Cmd.AddParam('receipt_state', TValue.From<Integer>(ReceiptStateDb(AState)));
  Cmd.AddParam('at_time', TValue.From<TDateTime>(UnixMsToUtc(AReceipt.AtUnixMs)));
  Cmd.ExecuteNonQuery;
end;

procedure TMessengerPostgreSQLReceiptStore.RecordReceipt(
  const AReceipt: TMessengerReceipt; ASequence: Int64);
var
  Cmd: IDbCommand;
begin
  if ASequence <= 0 then raise EArgumentOutOfRangeException.Create('ASequence');
  FContext.BeginTransaction;
  try
    if AReceipt.State = mrsRead then
      InsertReceipt(AReceipt, mrsDelivered);
    InsertReceipt(AReceipt, AReceipt.State);

    if AReceipt.State = mrsRead then
    begin
      Cmd := FContext.Connection.CreateCommand(SQL_ADVANCE_READ);
      Cmd.AddParam('user_id', TValue.From<string>(AReceipt.UserId));
      Cmd.AddParam('conversation_id', TValue.From<string>(AReceipt.ConversationId));
      Cmd.AddParam('seq', TValue.From<Int64>(ASequence));
      Cmd.AddParam('seq2', TValue.From<Int64>(ASequence));
    end
    else
    begin
      Cmd := FContext.Connection.CreateCommand(SQL_ADVANCE_DELIVERED);
      Cmd.AddParam('user_id', TValue.From<string>(AReceipt.UserId));
      Cmd.AddParam('conversation_id', TValue.From<string>(AReceipt.ConversationId));
      Cmd.AddParam('seq', TValue.From<Int64>(ASequence));
    end;
    Cmd.ExecuteNonQuery;
    FContext.Commit;
  except
    FContext.Rollback;
    raise;
  end;
end;

end.
