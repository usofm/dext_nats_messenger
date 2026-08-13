unit Dext.Messenger.Persistence.DbContext;

interface

uses
  Dext.Entity,
  Dext.Entity.Core,
  Dext.Messenger.Persistence.Entities;

type
  TMessengerDbContext = class(TDbContext)
  private
    function GetConversations: IDbSet<TMessengerConversationEntity>;
    function GetMessages: IDbSet<TMessengerMessageEntity>;
    function GetCursors: IDbSet<TMessengerCursorEntity>;
    function GetDevices: IDbSet<TMessengerDeviceEntity>;
  public
    property Conversations: IDbSet<TMessengerConversationEntity> read GetConversations;
    property Messages: IDbSet<TMessengerMessageEntity> read GetMessages;
    property Cursors: IDbSet<TMessengerCursorEntity> read GetCursors;
    property Devices: IDbSet<TMessengerDeviceEntity> read GetDevices;
  end;

implementation

function TMessengerDbContext.GetConversations: IDbSet<TMessengerConversationEntity>;
begin
  Result := Entities<TMessengerConversationEntity>;
end;

function TMessengerDbContext.GetMessages: IDbSet<TMessengerMessageEntity>;
begin
  Result := Entities<TMessengerMessageEntity>;
end;

function TMessengerDbContext.GetCursors: IDbSet<TMessengerCursorEntity>;
begin
  Result := Entities<TMessengerCursorEntity>;
end;

function TMessengerDbContext.GetDevices: IDbSet<TMessengerDeviceEntity>;
begin
  Result := Entities<TMessengerDeviceEntity>;
end;

end.
