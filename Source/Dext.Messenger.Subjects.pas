unit Dext.Messenger.Subjects;

interface

uses
  System.SysUtils;

type
  EMessengerSubjectError = class(Exception);

  TMessengerSubjects = record
  strict private
    class procedure ValidateToken(const AName, AValue: string); static;
  public
    class function UserMessage(const AUserId: string): string; static;
    class function GroupMessage(const AGroupId: string): string; static;
    class function ConversationMessage(const AConversationId: string): string; static;

    class function UserPresence(const AUserId: string): string; static;
    class function UserTyping(const AUserId: string): string; static;
    class function GroupTyping(const AGroupId: string): string; static;

    class function DeliveredReceipt(const AConversationId: string): string; static;
    class function ReadReceipt(const AConversationId: string): string; static;

    class function MessageCreatedEvent: string; static;
    class function GroupMemberAddedEvent: string; static;
    class function GroupMemberRemovedEvent: string; static;
  end;

implementation

class procedure TMessengerSubjects.ValidateToken(const AName, AValue: string);
var
  I: Integer;
  C: Char;
begin
  if AValue = '' then
    raise EMessengerSubjectError.CreateFmt('%s must not be empty', [AName]);

  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    if (C <= ' ') or (C = '.') or (C = '*') or (C = '>') then
      raise EMessengerSubjectError.CreateFmt(
        '%s contains an invalid NATS subject token character at position %d',
        [AName, I]
      );
  end;
end;

class function TMessengerSubjects.UserMessage(const AUserId: string): string;
begin
  ValidateToken('user_id', AUserId);
  Result := 'msg.v1.user.' + AUserId;
end;

class function TMessengerSubjects.GroupMessage(const AGroupId: string): string;
begin
  ValidateToken('group_id', AGroupId);
  Result := 'msg.v1.group.' + AGroupId;
end;

class function TMessengerSubjects.ConversationMessage(const AConversationId: string): string;
begin
  ValidateToken('conversation_id', AConversationId);
  Result := 'msg.v1.conv.' + AConversationId;
end;

class function TMessengerSubjects.UserPresence(const AUserId: string): string;
begin
  ValidateToken('user_id', AUserId);
  Result := 'presence.v1.user.' + AUserId;
end;

class function TMessengerSubjects.UserTyping(const AUserId: string): string;
begin
  ValidateToken('user_id', AUserId);
  Result := 'typing.v1.user.' + AUserId;
end;

class function TMessengerSubjects.GroupTyping(const AGroupId: string): string;
begin
  ValidateToken('group_id', AGroupId);
  Result := 'typing.v1.group.' + AGroupId;
end;

class function TMessengerSubjects.DeliveredReceipt(const AConversationId: string): string;
begin
  ValidateToken('conversation_id', AConversationId);
  Result := 'receipt.v1.delivered.' + AConversationId;
end;

class function TMessengerSubjects.ReadReceipt(const AConversationId: string): string;
begin
  ValidateToken('conversation_id', AConversationId);
  Result := 'receipt.v1.read.' + AConversationId;
end;

class function TMessengerSubjects.MessageCreatedEvent: string;
begin
  Result := 'event.v1.message.created';
end;

class function TMessengerSubjects.GroupMemberAddedEvent: string;
begin
  Result := 'event.v1.group.member_added';
end;

class function TMessengerSubjects.GroupMemberRemovedEvent: string;
begin
  Result := 'event.v1.group.member_removed';
end;

end.
