unit Dext.Messenger.Gateway.MediaApi;

interface

uses
  System.SysUtils,
  Dext.Web,
  Dext.Web.Interfaces,
  Dext.Messenger.Gateway.Api,
  Dext.Messenger.Gateway.Core,
  Dext.Messenger.Media;

type
  TMessengerCreateUploadRequest = record
  public
    FileName: string;
    ContentType: string;
    SizeBytes: Int64;
  end;

  TMessengerCommitUploadRequest = record
  public
    MediaId: string;
    Sha256Hex: string;
    ActualSizeBytes: Int64;
  end;

  TMessengerResolveMediaRequest = record
  public
    MediaId: string;
  end;

  IMessengerGatewayMediaEndpointService = interface
    ['{76A07D2F-0CB4-490F-BDF7-D7BC48800DDD}']
    function CreateUpload(const AContext: IHttpContext;
      const ARequest: TMessengerCreateUploadRequest): TMessengerUploadGrant;
    function CommitUpload(const AContext: IHttpContext;
      const ARequest: TMessengerCommitUploadRequest): TMessengerMediaRef;
    function Resolve(const AContext: IHttpContext;
      const ARequest: TMessengerResolveMediaRequest): TMessengerMediaRef;
  end;

  TMessengerGatewayMediaEndpointService = class(TInterfacedObject,
    IMessengerGatewayMediaEndpointService)
  private
    FSessions: IMessengerGatewaySessionResolver;
    FMedia: IMessengerMediaStore;
    FMaxUploadBytes: Int64;
  public
    constructor Create(const ASessions: IMessengerGatewaySessionResolver;
      const AMedia: IMessengerMediaStore;
      AMaxUploadBytes: Int64 = TMessengerMediaPolicy.DefaultMaxVideoBytes);
    function CreateUpload(const AContext: IHttpContext;
      const ARequest: TMessengerCreateUploadRequest): TMessengerUploadGrant;
    function CommitUpload(const AContext: IHttpContext;
      const ARequest: TMessengerCommitUploadRequest): TMessengerMediaRef;
    function Resolve(const AContext: IHttpContext;
      const ARequest: TMessengerResolveMediaRequest): TMessengerMediaRef;
  end;

  TMessengerGatewayMediaEndpoints = class
  public
    class procedure Map(const Builder: TAppBuilder); static;
  end;

implementation

constructor TMessengerGatewayMediaEndpointService.Create(
  const ASessions: IMessengerGatewaySessionResolver;
  const AMedia: IMessengerMediaStore; AMaxUploadBytes: Int64);
begin
  inherited Create;
  if ASessions = nil then raise EArgumentNilException.Create('ASessions');
  if AMedia = nil then raise EArgumentNilException.Create('AMedia');
  if AMaxUploadBytes <= 0 then raise EArgumentOutOfRangeException.Create('AMaxUploadBytes');
  FSessions := ASessions;
  FMedia := AMedia;
  FMaxUploadBytes := AMaxUploadBytes;
end;

function TMessengerGatewayMediaEndpointService.CreateUpload(
  const AContext: IHttpContext;
  const ARequest: TMessengerCreateUploadRequest): TMessengerUploadGrant;
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  TMessengerMediaPolicy.ValidateDeclaredUpload(ARequest.FileName,
    ARequest.ContentType, ARequest.SizeBytes, FMaxUploadBytes);
  Result := FMedia.CreateUploadGrant(Session.UserId, ARequest.FileName,
    ARequest.ContentType, ARequest.SizeBytes);
end;

function TMessengerGatewayMediaEndpointService.CommitUpload(
  const AContext: IHttpContext;
  const ARequest: TMessengerCommitUploadRequest): TMessengerMediaRef;
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  Result := FMedia.CommitUpload(Session.UserId, ARequest.MediaId,
    ARequest.Sha256Hex, ARequest.ActualSizeBytes);
  TMessengerMediaPolicy.ValidateReadyReference(Result);
end;

function TMessengerGatewayMediaEndpointService.Resolve(
  const AContext: IHttpContext;
  const ARequest: TMessengerResolveMediaRequest): TMessengerMediaRef;
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  Result := FMedia.Resolve(Session.UserId, ARequest.MediaId);
  TMessengerMediaPolicy.ValidateReadyReference(Result);
end;

class procedure TMessengerGatewayMediaEndpoints.Map(const Builder: TAppBuilder);
begin
  Builder.MapPost<TMessengerCreateUploadRequest, IMessengerGatewayMediaEndpointService,
    IHttpContext, IResult>('/api/messenger/media/uploads',
    function(Req: TMessengerCreateUploadRequest;
      Svc: IMessengerGatewayMediaEndpointService; Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.CreateUpload(Ctx, Req));
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerCommitUploadRequest, IMessengerGatewayMediaEndpointService,
    IHttpContext, IResult>('/api/messenger/media/commit',
    function(Req: TMessengerCommitUploadRequest;
      Svc: IMessengerGatewayMediaEndpointService; Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.CommitUpload(Ctx, Req));
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerResolveMediaRequest, IMessengerGatewayMediaEndpointService,
    IHttpContext, IResult>('/api/messenger/media/resolve',
    function(Req: TMessengerResolveMediaRequest;
      Svc: IMessengerGatewayMediaEndpointService; Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.Resolve(Ctx, Req));
    end)
    .RequireAuthorization;
end;

end.
