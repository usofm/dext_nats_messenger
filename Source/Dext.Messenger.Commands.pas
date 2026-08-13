unit Dext.Messenger.Commands;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models;

type
  TMessengerDestinationKind = (
    mdkUser,
    mdkGroup
  );

  TMessengerAcceptMessageCommand = record
  public
    ClientMessageId: string;
    ConversationId: string;
    SenderUserId: string;
    DestinationKind: TMessengerDestinationKind;
    DestinationId: string;
    Kind: TMessengerMessageKind;
    PayloadJson: string;

    class function CreateDirect(
      const AClientMessageId,
      AConversationId,
      ASenderUserId,
      ATargetUserId: string;
      AKind: TMessengerMessageKind;
      const APayloadJson: string
    ): TMessengerAcceptMessageCommand; static;

    class function CreateGroup(
      const AClientMessageId,
      AConversationId,
      ASenderUserId,
      AGroupId: string;
      AKind: TMessengerMessageKind;
      const APayloadJson: string
    ): TMessengerAcceptMessageCommand; static;
  end;

  TMessengerAcceptedMessage = record
  public
    Message: TMessengerMessage;
    DestinationKind: TMessengerDestinationKind;
    DestinationId: string;
    Partition: Integer;
    { Canonical monotonic sequence within ConversationId. A value of 0 is
      permitted only for a proposal before the transactional store commits. }
    Sequence: Int64;

    class function Create(
      const AMessage: TMessengerMessage;
      ADestinationKind: TMessengerDestinationKind;
      const ADestinationId: string;
      APartition: Integer;
      ASequence: Int64 = 0
    ): TMessengerAcceptedMessage; static;

    function IsDirect: Boolean;
    function IsGroup: Boolean;
    function IsCanonical: Boolean;
  end;

implementation

class function TMessengerAcceptMessageCommand.CreateDirect(
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
  Result.DestinationKind := mdkUser;
  Result.DestinationId := ATargetUserId;
  Result.Kind := AKind;
  Result.PayloadJson := APayloadJson;
end;

class function TMessengerAcceptMessageCommand.CreateGroup(
  const AClientMessageId,
  AConversationId,
  ASenderUserId,
  AGroupId: string;
  AKind: TMessengerMessageKind;
  const APayloadJson: string
): TMessengerAcceptMessageCommand;
begin
  Result := Default(TMessengerAcceptMessageCommand);
  Result.ClientMessageId := AClientMessageId;
  Result.ConversationId := AConversationId;
  Result.SenderUserId := ASenderUserId;
  Result.DestinationKind := mdkGroup;
  Result.DestinationId := AGroupId;
  Result.Kind := AKind;
  Result.PayloadJson := APayloadJson;
end;

class function TMessengerAcceptedMessage.Create(
  const AMessage: TMessengerMessage;
  ADestinationKind: TMessengerDestinationKind;
  const ADestinationId: string;
  APartition: Integer;
  ASequence: Int64
): TMessengerAcceptedMessage;
begin
  if ADestinationId = '' then
    raise EArgumentException.Create('destination_id must not be empty');
  if APartition < 0 then
    raise EArgumentOutOfRangeException.Create('APartition');
  if ASequence < 0 then
    raise EArgumentOutOfRangeException.Create('ASequence');

  Result := Default(TMessengerAcceptedMessage);
  Result.Message := AMessage;
  Result.DestinationKind := ADestinationKind;
  Result.DestinationId := ADestinationId;
  Result.Partition := APartition;
  Result.Sequence := ASequence;
end;

function TMessengerAcceptedMessage.IsDirect: Boolean;
begin
  Result := DestinationKind = mdkUser;
end;

function TMessengerAcceptedMessage.IsGroup: Boolean;
begin
  Result := DestinationKind = mdkGroup;
end;

function TMessengerAcceptedMessage.IsCanonical: Boolean;
begin
  Result := Sequence > 0;
end;

end.
