unit Dext.Messenger.Gateway.SyncApi;

interface

uses
  System.SysUtils,
  Dext.Web,
  Dext.Web.Interfaces,
  Dext.Messenger.Gateway.Api,
  Dext.Messenger.Gateway.Core,
  Dext.Messenger.Sync;

type
  TMessengerSyncRequest = record
  public
    ConversationId: string;
    AfterSequence: Int64;
    Limit: Integer;
  end;

  TMessengerCursorRequest = record
  public
    ConversationId: string;
    Sequence: Int64;
  end;

  IMessengerGatewaySyncEndpointService = interface
    ['{6A112833-0253-4F58-B5EA-9AC793BC7F2A}']
    function Sync(const AContext: IHttpContext;
      const ARequest: TMessengerSyncRequest): TMessengerSyncResult;
    procedure MarkDelivered(const AContext: IHttpContext;
      const ARequest: TMessengerCursorRequest);
    procedure MarkRead(const AContext: IHttpContext;
      const ARequest: TMessengerCursorRequest);
  end;

  TMessengerGatewaySyncEndpointService = class(TInterfacedObject,
    IMessengerGatewaySyncEndpointService)
  private
    FSessions: IMessengerGatewaySessionResolver;
    FSync: TMessengerSyncService;
  public
    constructor Create(const ASessions: IMessengerGatewaySessionResolver;
      ASync: TMessengerSyncService);
    function Sync(const AContext: IHttpContext;
      const ARequest: TMessengerSyncRequest): TMessengerSyncResult;
    procedure MarkDelivered(const AContext: IHttpContext;
      const ARequest: TMessengerCursorRequest);
    procedure MarkRead(const AContext: IHttpContext;
      const ARequest: TMessengerCursorRequest);
  end;

  TMessengerGatewaySyncEndpoints = class
  public
    class procedure Map(const Builder: TAppBuilder); static;
  end;

implementation

constructor TMessengerGatewaySyncEndpointService.Create(
  const ASessions: IMessengerGatewaySessionResolver;
  ASync: TMessengerSyncService);
begin
  inherited Create;
  if ASessions = nil then raise EArgumentNilException.Create('ASessions');
  if not Assigned(ASync) then raise EArgumentNilException.Create('ASync');
  FSessions := ASessions;
  FSync := ASync;
end;

function TMessengerGatewaySyncEndpointService.Sync(const AContext: IHttpContext;
  const ARequest: TMessengerSyncRequest): TMessengerSyncResult;
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  Result := FSync.SyncConversation(Session.UserId, ARequest.ConversationId,
    ARequest.AfterSequence, ARequest.Limit);
end;

procedure TMessengerGatewaySyncEndpointService.MarkDelivered(
  const AContext: IHttpContext; const ARequest: TMessengerCursorRequest);
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  FSync.MarkDeliveredThrough(Session.UserId, ARequest.ConversationId,
    ARequest.Sequence);
end;

procedure TMessengerGatewaySyncEndpointService.MarkRead(
  const AContext: IHttpContext; const ARequest: TMessengerCursorRequest);
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  FSync.MarkReadThrough(Session.UserId, ARequest.ConversationId,
    ARequest.Sequence);
end;

class procedure TMessengerGatewaySyncEndpoints.Map(const Builder: TAppBuilder);
begin
  Builder.MapPost<TMessengerSyncRequest, IMessengerGatewaySyncEndpointService,
    IHttpContext, IResult>('/api/messenger/sync',
    function(Req: TMessengerSyncRequest; Svc: IMessengerGatewaySyncEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.Sync(Ctx, Req));
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerCursorRequest, IMessengerGatewaySyncEndpointService,
    IHttpContext, IResult>('/api/messenger/cursors/delivered',
    function(Req: TMessengerCursorRequest; Svc: IMessengerGatewaySyncEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Svc.MarkDelivered(Ctx, Req);
      Result := Results.NoContent;
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerCursorRequest, IMessengerGatewaySyncEndpointService,
    IHttpContext, IResult>('/api/messenger/cursors/read',
    function(Req: TMessengerCursorRequest; Svc: IMessengerGatewaySyncEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Svc.MarkRead(Ctx, Req);
      Result := Results.NoContent;
    end)
    .RequireAuthorization;
end;

end.
