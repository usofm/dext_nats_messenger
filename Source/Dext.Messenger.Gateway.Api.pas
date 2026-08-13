unit Dext.Messenger.Gateway.Api;

interface

uses
  System.SysUtils,
  Dext.Web,
  Dext.Web.Interfaces,
  Dext.Messenger.Commands,
  Dext.Messenger.Models,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Gateway.Core;

type
  TMessengerSendRequest = record
  public
    ClientMessageId: string;
    ConversationId: string;
    DestinationType: string; // user | group
    DestinationId: string;
    Kind: string;
    PayloadJson: string;
  end;

  TMessengerSendResponse = record
  public
    MessageId: string;
    ConversationId: string;
    Sequence: Int64;
    Duplicate: Boolean;
  end;

  IMessengerGatewaySessionResolver = interface
    ['{701DB0D7-CFC3-4E50-9A6C-F0CB5F003190}']
    function Resolve(const AContext: IHttpContext): TMessengerSession;
  end;

  IMessengerGatewayEndpointService = interface
    ['{0C658B82-7D96-4447-8A1B-D832CA9BA815}']
    function Send(const AContext: IHttpContext;
      const ARequest: TMessengerSendRequest): TMessengerSendResponse;
  end;

  TDextJwtMessengerSessionResolver = class(TInterfacedObject,
    IMessengerGatewaySessionResolver)
  private
    FGatewayId: string;
  public
    constructor Create(const AGatewayId: string);
    function Resolve(const AContext: IHttpContext): TMessengerSession;
  end;

  TMessengerGatewayEndpointService = class(TInterfacedObject,
    IMessengerGatewayEndpointService)
  private
    FSessions: IMessengerGatewaySessionResolver;
    FCommands: TMessengerGatewayCommandFactory;
    FAcceptance: TMessengerAcceptanceService;
    class function ParseDestination(const AValue: string): TMessengerDestinationKind; static;
    class function ParseMessageKind(const AValue: string): TMessengerMessageKind; static;
  public
    constructor Create(const ASessions: IMessengerGatewaySessionResolver;
      ACommands: TMessengerGatewayCommandFactory;
      AAcceptance: TMessengerAcceptanceService);
    function Send(const AContext: IHttpContext;
      const ARequest: TMessengerSendRequest): TMessengerSendResponse;
  end;

  TMessengerGatewayEndpoints = class
  public
    class procedure Map(const Builder: TAppBuilder); static;
  end;

implementation

uses
  Dext.Auth.Identity;

const
  CLAIM_DEVICE_ID = 'device_id';
  CLAIM_SESSION_ID = 'session_id';

constructor TDextJwtMessengerSessionResolver.Create(const AGatewayId: string);
begin
  inherited Create;
  if AGatewayId = '' then raise EArgumentException.Create('gateway_id is required');
  FGatewayId := AGatewayId;
end;

function TDextJwtMessengerSessionResolver.Resolve(
  const AContext: IHttpContext): TMessengerSession;
var
  UserId, DeviceId, SessionId: string;
begin
  if (AContext = nil) or (AContext.User = nil) or
     (AContext.User.Identity = nil) or
     (not AContext.User.Identity.IsAuthenticated) then
    raise EMessengerSessionRejected.Create('Authenticated JWT identity is required');

  UserId := AContext.User.FindClaim(TClaimTypes.NameIdentifier).Value;
  DeviceId := AContext.User.FindClaim(CLAIM_DEVICE_ID).Value;
  SessionId := AContext.User.FindClaim(CLAIM_SESSION_ID).Value;
  if UserId = '' then raise EMessengerSessionRejected.Create('JWT missing name-identifier claim');
  if DeviceId = '' then raise EMessengerSessionRejected.Create('JWT missing device_id claim');
  if SessionId = '' then raise EMessengerSessionRejected.Create('JWT missing session_id claim');

  Result := TMessengerSession.AuthenticatedSession(
    UserId, DeviceId, SessionId, FGatewayId);
end;

constructor TMessengerGatewayEndpointService.Create(
  const ASessions: IMessengerGatewaySessionResolver;
  ACommands: TMessengerGatewayCommandFactory;
  AAcceptance: TMessengerAcceptanceService);
begin
  inherited Create;
  if ASessions = nil then raise EArgumentNilException.Create('ASessions');
  if not Assigned(ACommands) then raise EArgumentNilException.Create('ACommands');
  if not Assigned(AAcceptance) then raise EArgumentNilException.Create('AAcceptance');
  FSessions := ASessions;
  FCommands := ACommands;
  FAcceptance := AAcceptance;
end;

class function TMessengerGatewayEndpointService.ParseDestination(
  const AValue: string): TMessengerDestinationKind;
begin
  if SameText(AValue, 'user') then Exit(mdkUser);
  if SameText(AValue, 'group') then Exit(mdkGroup);
  raise EMessengerGatewayError.Create('destination_type must be user or group');
end;

class function TMessengerGatewayEndpointService.ParseMessageKind(
  const AValue: string): TMessengerMessageKind;
begin
  if SameText(AValue, 'text') then Exit(mmkText);
  if SameText(AValue, 'image') then Exit(mmkImage);
  if SameText(AValue, 'audio') then Exit(mmkAudio);
  if SameText(AValue, 'video') then Exit(mmkVideo);
  if SameText(AValue, 'file') then Exit(mmkFile);
  raise EMessengerGatewayError.Create('Unsupported client message kind');
end;

function TMessengerGatewayEndpointService.Send(const AContext: IHttpContext;
  const ARequest: TMessengerSendRequest): TMessengerSendResponse;
var
  Session: TMessengerSession;
  ClientSend: TMessengerClientSend;
  Command: TMessengerAcceptMessageCommand;
  Accepted: TMessengerAcceptanceResult;
begin
  Session := FSessions.Resolve(AContext);
  ClientSend := Default(TMessengerClientSend);
  ClientSend.ClientMessageId := ARequest.ClientMessageId;
  ClientSend.ConversationId := ARequest.ConversationId;
  ClientSend.DestinationKind := ParseDestination(ARequest.DestinationType);
  ClientSend.DestinationId := ARequest.DestinationId;
  ClientSend.Kind := ParseMessageKind(ARequest.Kind);
  ClientSend.PayloadJson := ARequest.PayloadJson;

  Command := FCommands.CreateAcceptCommand(Session, ClientSend);
  Accepted := FAcceptance.Accept(Command);

  Result := Default(TMessengerSendResponse);
  Result.MessageId := Accepted.Accepted.Message.MessageId;
  Result.ConversationId := Accepted.Accepted.Message.ConversationId;
  Result.Sequence := Accepted.Accepted.Sequence;
  Result.Duplicate := Accepted.Status = masDuplicate;
end;

class procedure TMessengerGatewayEndpoints.Map(const Builder: TAppBuilder);
begin
  Builder.MapPost<TMessengerSendRequest, IMessengerGatewayEndpointService,
    IHttpContext, IResult>('/api/messenger/messages',
    function(Req: TMessengerSendRequest; Svc: IMessengerGatewayEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.Send(Ctx, Req));
    end)
    .RequireAuthorization;
end;

end.
