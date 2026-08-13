unit Dext.Messenger.Commands;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models;

type
  TMessengerAcceptMessageCommand = record
  public
    ClientMessageId: string;
    ConversationId: string;
    SenderUserId: string;
    TargetUserId: string;
    Kind: TMessengerMessageKind;
    PayloadJson: string;

    class function Create(
      const AClientMessageId,
      AConversationId,
      ASenderUserId,
      ATargetUserId: string;
      AKind: TMessengerMessageKind;
      const APayloadJson: string
    ): TMessengerAcceptMessageCommand; static;
  end;

  TMessengerAcceptedMessage = record
  public
    Message: TMessengerMessage;
    TargetUserId: string;
    Partition: Integer;

    class function Create(
      const AMessage: TMessengerMessage;
      const ATargetUserId: string;
      APartition: Integer
    ): TMessengerAcceptedMessage; static;
  end;

implementation

class function TMessengerAcceptMessageCommand.Create(
  const AClientMessageId,
  AConversationId,
  ASenderUserId,
  ATargetUserId: string;
  AKind: TMessengerMessageKind;
  const APayloadJson: string
): TMessengerAcceptMessageCommand;
begin
  Result := Default(TMessengerAcceptMessageCommand);
  Result.ClientMessageId := AClientMessageId;
  Result.ConversationId := AConversationId;
  Result.SenderUserId := ASenderUserId;
  Result.TargetUserId := ATargetUserId;
  Result.Kind := AKind;
  Result.PayloadJson := APayloadJson;
end;

class function TMessengerAcceptedMessage.Create(
  const AMessage: TMessengerMessage;
  const ATargetUserId: string;
  APartition: Integer
): TMessengerAcceptedMessage;
begin
  Result := Default(TMessengerAcceptedMessage);
  Result.Message := AMessage;
  Result.TargetUserId := ATargetUserId;
  Result.Partition := APartition;
end;

end.
