unit Dext.Messenger.ConversationQueries;

interface

uses
  System.SysUtils,
  Dext.Messenger.Conversations;

type
  TMessengerConversationSummary = record
  public
    ConversationId: string;
    Kind: TMessengerConversationKind;
    GroupId: string;
    Title: string;
    LastSequence: Int64;
    LastMessageAtUnixMs: Int64;
    ReadSequence: Int64;
    DeliveredSequence: Int64;
  end;

  IMessengerConversationQueryStore = interface
    ['{A4E8326D-9D04-45DA-B16F-445F6E3B59F2}']
    function ListForUser(const AUserId: string; AOffset,
      ALimit: Integer): TArray<TMessengerConversationSummary>;
  end;

  TMessengerConversationQueryService = class
  public const
    DefaultPageSize = 50;
    MaxPageSize = 200;
  private
    FStore: IMessengerConversationQueryStore;
  public
    constructor Create(const AStore: IMessengerConversationQueryStore);
    function ListForUser(const AUserId: string; AOffset: Integer = 0;
      ALimit: Integer = DefaultPageSize): TArray<TMessengerConversationSummary>;
  end;

implementation

constructor TMessengerConversationQueryService.Create(
  const AStore: IMessengerConversationQueryStore);
begin
  inherited Create;
  if AStore = nil then raise EArgumentNilException.Create('AStore');
  FStore := AStore;
end;

function TMessengerConversationQueryService.ListForUser(const AUserId: string;
  AOffset, ALimit: Integer): TArray<TMessengerConversationSummary>;
begin
  if Trim(AUserId) = '' then raise EArgumentException.Create('user_id is required');
  if AOffset < 0 then raise EArgumentOutOfRangeException.Create('AOffset');
  if ALimit <= 0 then ALimit := DefaultPageSize;
  if ALimit > MaxPageSize then ALimit := MaxPageSize;
  Result := FStore.ListForUser(AUserId, AOffset, ALimit);
end;

end.
