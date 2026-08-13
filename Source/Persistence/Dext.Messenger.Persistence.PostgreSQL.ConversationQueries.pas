unit Dext.Messenger.Persistence.PostgreSQL.ConversationQueries;

interface

uses
  System.SysUtils,
  Dext.Entity.Drivers.Interfaces,
  Dext.Messenger.ConversationQueries,
  Dext.Messenger.Persistence.DbContext;

type
  TMessengerPostgreSQLConversationQueryStore = class(TInterfacedObject,
    IMessengerConversationQueryStore)
  private
    FContext: TMessengerDbContext;
  public
    constructor Create(AContext: TMessengerDbContext);
    function ListForUser(const AUserId: string; AOffset,
      ALimit: Integer): TArray<TMessengerConversationSummary>;
  end;

implementation

uses
  System.Rtti,
  System.DateUtils,
  System.Generics.Collections,
  Dext.Messenger.Conversations;

const
  SQL_LIST =
    'select c.id,c.kind,coalesce(c.group_id,''''),coalesce(c.title,''''),' +
    'c.last_sequence,c.last_message_at,' +
    'coalesce(uc.read_sequence,0),coalesce(uc.delivered_sequence,0) ' +
    'from messenger_conversations c ' +
    'join messenger_members m on m.conversation_id=c.id ' +
    'and m.user_id=:user_id and m.left_at is null ' +
    'left join messenger_user_cursors uc on uc.conversation_id=c.id ' +
    'and uc.user_id=:cursor_user ' +
    'order by c.last_message_at desc nulls last,c.created_at desc ' +
    'offset :offset_n limit :limit_n';

constructor TMessengerPostgreSQLConversationQueryStore.Create(
  AContext: TMessengerDbContext);
begin
  inherited Create;
  if not Assigned(AContext) then raise EArgumentNilException.Create('AContext');
  FContext := AContext;
end;

function TMessengerPostgreSQLConversationQueryStore.ListForUser(
  const AUserId: string; AOffset, ALimit: Integer): TArray<TMessengerConversationSummary>;
var
  Cmd: IDbCommand;
  R: IDbReader;
  L: TList<TMessengerConversationSummary>;
  Item: TMessengerConversationSummary;
  KindValue: Integer;
  LastAt: TDateTime;
begin
  Cmd := FContext.Connection.CreateCommand(SQL_LIST);
  Cmd.AddParam('user_id', TValue.From<string>(AUserId));
  Cmd.AddParam('cursor_user', TValue.From<string>(AUserId));
  Cmd.AddParam('offset_n', TValue.From<Integer>(AOffset));
  Cmd.AddParam('limit_n', TValue.From<Integer>(ALimit));
  R := Cmd.ExecuteQuery;
  L := TList<TMessengerConversationSummary>.Create;
  try
    while R.Next do
    begin
      Item := Default(TMessengerConversationSummary);
      Item.ConversationId := R.GetString(0);
      KindValue := R.GetInt32(1);
      case KindValue of
        1: Item.Kind := mckDirect;
        2: Item.Kind := mckGroup;
      else
        raise EInvalidOperation.CreateFmt('Invalid conversation kind %d', [KindValue]);
      end;
      Item.GroupId := R.GetString(2);
      Item.Title := R.GetString(3);
      Item.LastSequence := R.GetInt64(4);
      if not R.IsNull(5) then
      begin
        LastAt := R.GetDateTime(5);
        Item.LastMessageAtUnixMs := DateTimeToUnix(LastAt, True) * Int64(1000) +
          MilliSecondOf(LastAt);
      end;
      Item.ReadSequence := R.GetInt64(6);
      Item.DeliveredSequence := R.GetInt64(7);
      L.Add(Item);
    end;
    Result := L.ToArray;
  finally
    R.Close;
    L.Free;
  end;
end;

end.
