unit Dext.Messenger.Gateway.ConversationQueryApi;

interface

uses
  System.SysUtils,
  Dext.Web,
  Dext.Web.Interfaces,
  Dext.Messenger.Gateway.Api,
  Dext.Messenger.Gateway.Core,
  Dext.Messenger.ConversationQueries;

type
  TMessengerConversationListRequest = record
  public
    Offset: Integer;
    Limit: Integer;
  end;

  IMessengerGatewayConversationQueryEndpointService = interface
    ['{CC9EE9EB-63D7-49D5-A04B-0E77D9ED518B}']
    function ListForUser(const AContext: IHttpContext;
      const ARequest: TMessengerConversationListRequest):
      TArray<TMessengerConversationSummary>;
  end;

  TMessengerGatewayConversationQueryEndpointService = class(TInterfacedObject,
    IMessengerGatewayConversationQueryEndpointService)
  private
    FSessions: IMessengerGatewaySessionResolver;
    FQueries: TMessengerConversationQueryService;
  public
    constructor Create(const ASessions: IMessengerGatewaySessionResolver;
      AQueries: TMessengerConversationQueryService);
    function ListForUser(const AContext: IHttpContext;
      const ARequest: TMessengerConversationListRequest):
      TArray<TMessengerConversationSummary>;
  end;

  TMessengerGatewayConversationQueryEndpoints = class
  public
    class procedure Map(const Builder: TAppBuilder); static;
  end;

implementation

constructor TMessengerGatewayConversationQueryEndpointService.Create(
  const ASessions: IMessengerGatewaySessionResolver;
  AQueries: TMessengerConversationQueryService);
begin
  inherited Create;
  if ASessions = nil then raise EArgumentNilException.Create('ASessions');
  if not Assigned(AQueries) then raise EArgumentNilException.Create('AQueries');
  FSessions := ASessions;
  FQueries := AQueries;
end;

function TMessengerGatewayConversationQueryEndpointService.ListForUser(
  const AContext: IHttpContext;
  const ARequest: TMessengerConversationListRequest):
  TArray<TMessengerConversationSummary>;
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  Result := FQueries.ListForUser(Session.UserId, ARequest.Offset, ARequest.Limit);
end;

class procedure TMessengerGatewayConversationQueryEndpoints.Map(
  const Builder: TAppBuilder);
begin
  Builder.MapPost<TMessengerConversationListRequest,
    IMessengerGatewayConversationQueryEndpointService, IHttpContext, IResult>(
    '/api/messenger/conversations/list',
    function(Req: TMessengerConversationListRequest;
      Svc: IMessengerGatewayConversationQueryEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.ListForUser(Ctx, Req));
    end)
    .RequireAuthorization;
end;

end.
