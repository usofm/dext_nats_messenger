unit Dext.Messenger.Sync;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models;

type
  TMessengerStoredMessage = record
  public
    Sequence: Int64;
    Message: TMessengerMessage;
    class function Create(ASequence: Int64;
      const AMessage: TMessengerMessage): TMessengerStoredMessage; static;
  end;

  TMessengerSyncResult = record
  public
    ConversationId: string;
    FromSequence: Int64;
    NextSequence: Int64;
    HasMore: Boolean;
    Messages: TArray<TMessengerStoredMessage>;
  end;

  IMessengerHistoryStore = interface
    ['{BD321DD8-19F3-4B7E-A196-727E380C72F7}']
    function ReadAfter(const AUserId, AConversationId: string;
      AAfterSequence: Int64; ALimit: Integer): TArray<TMessengerStoredMessage>;
    function HasMessagesAfter(const AUserId, AConversationId: string;
      AAfterSequence: Int64): Boolean;
  end;

  IMessengerCursorStore = interface
    ['{3E14781F-D6A2-4020-B156-B9008DD7341D}']
    function GetReadCursor(const AUserId, AConversationId: string): Int64;
    procedure AdvanceReadCursor(const AUserId, AConversationId: string;
      ASequence: Int64);
    function GetDeliveredCursor(const AUserId, AConversationId: string): Int64;
    procedure AdvanceDeliveredCursor(const AUserId, AConversationId: string;
      ASequence: Int64);
  end;

  TMessengerSyncService = class
  public const
    DefaultPageSize = 100;
    MaxPageSize = 500;
  private
    FHistory: IMessengerHistoryStore;
    FCursors: IMessengerCursorStore;
    class procedure ValidateIdentity(const AName, AValue: string); static;
    class function NormalizeLimit(ALimit: Integer): Integer; static;
  public
    constructor Create(const AHistory: IMessengerHistoryStore;
      const ACursors: IMessengerCursorStore);

    function SyncConversation(const AUserId, AConversationId: string;
      AAfterSequence: Int64; ALimit: Integer = DefaultPageSize): TMessengerSyncResult;

    procedure MarkDeliveredThrough(const AUserId, AConversationId: string;
      ASequence: Int64);
    procedure MarkReadThrough(const AUserId, AConversationId: string;
      ASequence: Int64);

    function ReadCursor(const AUserId, AConversationId: string): Int64;
    function DeliveredCursor(const AUserId, AConversationId: string): Int64;
  end;

implementation

class function TMessengerStoredMessage.Create(ASequence: Int64;
  const AMessage: TMessengerMessage): TMessengerStoredMessage;
begin
  if ASequence <= 0 then
    raise EArgumentOutOfRangeException.Create('ASequence');
  Result := Default(TMessengerStoredMessage);
  Result.Sequence := ASequence;
  Result.Message := AMessage;
end;

constructor TMessengerSyncService.Create(const AHistory: IMessengerHistoryStore;
  const ACursors: IMessengerCursorStore);
begin
  inherited Create;
  if AHistory = nil then raise EArgumentNilException.Create('AHistory');
  if ACursors = nil then raise EArgumentNilException.Create('ACursors');
  FHistory := AHistory;
  FCursors := ACursors;
end;

class procedure TMessengerSyncService.ValidateIdentity(const AName, AValue: string);
begin
  if AValue = '' then
    raise EArgumentException.CreateFmt('%s must not be empty', [AName]);
end;

class function TMessengerSyncService.NormalizeLimit(ALimit: Integer): Integer;
begin
  if ALimit <= 0 then Exit(DefaultPageSize);
  if ALimit > MaxPageSize then Exit(MaxPageSize);
  Result := ALimit;
end;

function TMessengerSyncService.SyncConversation(const AUserId,
  AConversationId: string; AAfterSequence: Int64;
  ALimit: Integer): TMessengerSyncResult;
var
  Items: TArray<TMessengerStoredMessage>;
  NextSeq: Int64;
begin
  ValidateIdentity('user_id', AUserId);
  ValidateIdentity('conversation_id', AConversationId);
  if AAfterSequence < 0 then
    raise EArgumentOutOfRangeException.Create('AAfterSequence');

  Items := FHistory.ReadAfter(AUserId, AConversationId, AAfterSequence,
    NormalizeLimit(ALimit));

  NextSeq := AAfterSequence;
  if Length(Items) > 0 then
    NextSeq := Items[High(Items)].Sequence;

  Result := Default(TMessengerSyncResult);
  Result.ConversationId := AConversationId;
  Result.FromSequence := AAfterSequence;
  Result.NextSequence := NextSeq;
  Result.Messages := Items;
  Result.HasMore := FHistory.HasMessagesAfter(AUserId, AConversationId, NextSeq);
end;

procedure TMessengerSyncService.MarkDeliveredThrough(const AUserId,
  AConversationId: string; ASequence: Int64);
begin
  ValidateIdentity('user_id', AUserId);
  ValidateIdentity('conversation_id', AConversationId);
  if ASequence <= 0 then raise EArgumentOutOfRangeException.Create('ASequence');
  { Concrete cursor store MUST use monotonic max semantics. Delayed/out-of-order
    device receipts are never allowed to move a cursor backwards. }
  FCursors.AdvanceDeliveredCursor(AUserId, AConversationId, ASequence);
end;

procedure TMessengerSyncService.MarkReadThrough(const AUserId,
  AConversationId: string; ASequence: Int64);
begin
  ValidateIdentity('user_id', AUserId);
  ValidateIdentity('conversation_id', AConversationId);
  if ASequence <= 0 then raise EArgumentOutOfRangeException.Create('ASequence');
  FCursors.AdvanceReadCursor(AUserId, AConversationId, ASequence);
  { Read implies delivered for user-level cursor semantics. }
  FCursors.AdvanceDeliveredCursor(AUserId, AConversationId, ASequence);
end;

function TMessengerSyncService.ReadCursor(const AUserId,
  AConversationId: string): Int64;
begin
  ValidateIdentity('user_id', AUserId);
  ValidateIdentity('conversation_id', AConversationId);
  Result := FCursors.GetReadCursor(AUserId, AConversationId);
end;

function TMessengerSyncService.DeliveredCursor(const AUserId,
  AConversationId: string): Int64;
begin
  ValidateIdentity('user_id', AUserId);
  ValidateIdentity('conversation_id', AConversationId);
  Result := FCursors.GetDeliveredCursor(AUserId, AConversationId);
end;

end.
