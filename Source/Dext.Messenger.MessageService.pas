unit Dext.Messenger.MessageService;

interface

uses
  System.SysUtils,
  Dext.Messenger.Models,
  Dext.Messenger.Transport;

type
  TMessengerMessageHandler = reference to procedure(const AMessage: TMessengerMessage);

  IMessengerMessageService = interface
    ['{A6A8C4B0-89B5-43CA-B350-C8831546E1E8}']
    procedure SendToUser(const ATargetUserId: string; const AMessage: TMessengerMessage);
    function SubscribeUser(
      const AUserId: string;
      const AHandler: TMessengerMessageHandler
    ): IMessengerSubscription;
  end;

  TMessengerMessageService = class(TInterfacedObject, IMessengerMessageService)
  private
    FTransport: IMessengerTransport;
  public
    constructor Create(const ATransport: IMessengerTransport);

    procedure SendToUser(const ATargetUserId: string; const AMessage: TMessengerMessage);
    function SubscribeUser(
      const AUserId: string;
      const AHandler: TMessengerMessageHandler
    ): IMessengerSubscription;
  end;

implementation

uses
  Dext.Messenger.Codec.Json,
  Dext.Messenger.Subjects,
  Dext.Messenger.Validation;

constructor TMessengerMessageService.Create(const ATransport: IMessengerTransport);
begin
  inherited Create;
  if ATransport = nil then
    raise EArgumentNilException.Create('ATransport');
  FTransport := ATransport;
end;

procedure TMessengerMessageService.SendToUser(
  const ATargetUserId: string;
  const AMessage: TMessengerMessage
);
var
  Subject: string;
  Payload: TBytes;
begin
  TMessengerValidator.ValidateMessage(AMessage);
  Subject := TMessengerSubjects.UserMessage(ATargetUserId);
  Payload := TMessengerJsonCodec.EncodeMessage(AMessage);
  FTransport.Publish(Subject, Payload);
end;

function TMessengerMessageService.SubscribeUser(
  const AUserId: string;
  const AHandler: TMessengerMessageHandler
): IMessengerSubscription;
var
  Subject: string;
begin
  if not Assigned(AHandler) then
    raise EArgumentNilException.Create('AHandler');

  Subject := TMessengerSubjects.UserMessage(AUserId);
  Result := FTransport.Subscribe(
    Subject,
    procedure(const ASubject: string; const APayload: TBytes)
    var
      Message: TMessengerMessage;
    begin
      Message := TMessengerJsonCodec.DecodeMessage(APayload);
      AHandler(Message);
    end
  );
end;

end.
