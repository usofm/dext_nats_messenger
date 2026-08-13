unit Dext.Messenger.Gateway.ReceiptApi;

interface

uses
  System.SysUtils,
  Dext.Web,
  Dext.Web.Interfaces,
  Dext.Messenger.Gateway.Api,
  Dext.Messenger.Gateway.Core,
  Dext.Messenger.Models,
  Dext.Messenger.Receipts;

type
  TMessengerReceiptRequest = record
  public
    MessageId: string;
    ConversationId: string;
    Sequence: Int64;
    State: string; // delivered | read
  end;

  IMessengerGatewayReceiptEndpointService = interface
    ['{9F4B54AB-79EA-4278-AE23-4A2C53D60CDA}']
    procedure RecordReceipt(const AContext: IHttpContext;
      const ARequest: TMessengerReceiptRequest);
  end;

  TMessengerGatewayReceiptEndpointService = class(TInterfacedObject,
    IMessengerGatewayReceiptEndpointService)
  private
    FSessions: IMessengerGatewaySessionResolver;
    FReceipts: TMessengerReceiptService;
    class function ParseState(const AValue: string): TMessengerReceiptState; static;
  public
    constructor Create(const ASessions: IMessengerGatewaySessionResolver;
      AReceipts: TMessengerReceiptService);
    procedure RecordReceipt(const AContext: IHttpContext;
      const ARequest: TMessengerReceiptRequest);
  end;

  TMessengerGatewayReceiptEndpoints = class
  public
    class procedure Map(const Builder: TAppBuilder); static;
  end;

implementation

constructor TMessengerGatewayReceiptEndpointService.Create(
  const ASessions: IMessengerGatewaySessionResolver;
  AReceipts: TMessengerReceiptService);
begin
  inherited Create;
  if ASessions = nil then raise EArgumentNilException.Create('ASessions');
  if not Assigned(AReceipts) then raise EArgumentNilException.Create('AReceipts');
  FSessions := ASessions;
  FReceipts := AReceipts;
end;

class function TMessengerGatewayReceiptEndpointService.ParseState(
  const AValue: string): TMessengerReceiptState;
begin
  if SameText(AValue, 'delivered') then Exit(mrsDelivered);
  if SameText(AValue, 'read') then Exit(mrsRead);
  raise EArgumentException.Create('receipt state must be delivered or read');
end;

procedure TMessengerGatewayReceiptEndpointService.RecordReceipt(
  const AContext: IHttpContext; const ARequest: TMessengerReceiptRequest);
var
  Session: TMessengerSession;
  Command: TMessengerReceiptCommand;
begin
  Session := FSessions.Resolve(AContext);
  Command := Default(TMessengerReceiptCommand);
  Command.MessageId := ARequest.MessageId;
  Command.ConversationId := ARequest.ConversationId;
  Command.Sequence := ARequest.Sequence;
  Command.State := ParseState(ARequest.State);
  FReceipts.RecordFromSession(Session, Command);
end;

class procedure TMessengerGatewayReceiptEndpoints.Map(const Builder: TAppBuilder);
begin
  Builder.MapPost<TMessengerReceiptRequest, IMessengerGatewayReceiptEndpointService,
    IHttpContext, IResult>('/api/messenger/receipts',
    function(Req: TMessengerReceiptRequest;
      Svc: IMessengerGatewayReceiptEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Svc.RecordReceipt(Ctx, Req);
      Result := Results.NoContent;
    end)
    .RequireAuthorization;
end;

end.
