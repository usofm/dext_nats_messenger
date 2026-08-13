unit Dext.Messenger.Gateway.ConversationApi;

interface

uses
  System.SysUtils,
  Dext.Web,
  Dext.Web.Interfaces,
  Dext.Messenger.Gateway.Api,
  Dext.Messenger.Gateway.Core,
  Dext.Messenger.Conversations,
  Dext.Messenger.ConversationLifecycle;

type
  TMessengerCreateDirectRequest = record
  public
    OtherUserId: string;
  end;

  TMessengerCreateGroupRequest = record
  public
    Title: string;
  end;

  TMessengerMemberRequest = record
  public
    ConversationId: string;
    UserId: string;
    Role: string; // member | moderator | admin
  end;

  TMessengerRemoveMemberRequest = record
  public
    ConversationId: string;
    UserId: string;
  end;

  TMessengerConversationResponse = record
  public
    ConversationId: string;
    Kind: string;
    GroupId: string;
    Existing: Boolean;
  end;

  IMessengerGatewayConversationEndpointService = interface
    ['{57A91511-AE65-4D1D-A39B-B85A36D57EE8}']
    function CreateDirect(const AContext: IHttpContext;
      const ARequest: TMessengerCreateDirectRequest): TMessengerConversationResponse;
    function CreateGroup(const AContext: IHttpContext;
      const ARequest: TMessengerCreateGroupRequest): TMessengerConversationResponse;
    procedure AddMember(const AContext: IHttpContext;
      const ARequest: TMessengerMemberRequest);
    procedure RemoveMember(const AContext: IHttpContext;
      const ARequest: TMessengerRemoveMemberRequest);
  end;

  TMessengerGatewayConversationEndpointService = class(TInterfacedObject,
    IMessengerGatewayConversationEndpointService)
  private
    FSessions: IMessengerGatewaySessionResolver;
    FLifecycle: TMessengerConversationLifecycleService;
    FGroups: TMessengerGroupService;
    class function RoleFromText(const AValue: string): TMessengerMemberRole; static;
    class function ResponseOf(const AInfo: TMessengerConversationInfo;
      AExisting: Boolean): TMessengerConversationResponse; static;
  public
    constructor Create(const ASessions: IMessengerGatewaySessionResolver;
      ALifecycle: TMessengerConversationLifecycleService;
      AGroups: TMessengerGroupService);
    function CreateDirect(const AContext: IHttpContext;
      const ARequest: TMessengerCreateDirectRequest): TMessengerConversationResponse;
    function CreateGroup(const AContext: IHttpContext;
      const ARequest: TMessengerCreateGroupRequest): TMessengerConversationResponse;
    procedure AddMember(const AContext: IHttpContext;
      const ARequest: TMessengerMemberRequest);
    procedure RemoveMember(const AContext: IHttpContext;
      const ARequest: TMessengerRemoveMemberRequest);
  end;

  TMessengerGatewayConversationEndpoints = class
  public
    class procedure Map(const Builder: TAppBuilder); static;
  end;

implementation

constructor TMessengerGatewayConversationEndpointService.Create(
  const ASessions: IMessengerGatewaySessionResolver;
  ALifecycle: TMessengerConversationLifecycleService;
  AGroups: TMessengerGroupService);
begin
  inherited Create;
  if ASessions = nil then raise EArgumentNilException.Create('ASessions');
  if not Assigned(ALifecycle) then raise EArgumentNilException.Create('ALifecycle');
  if not Assigned(AGroups) then raise EArgumentNilException.Create('AGroups');
  FSessions := ASessions;
  FLifecycle := ALifecycle;
  FGroups := AGroups;
end;

class function TMessengerGatewayConversationEndpointService.RoleFromText(
  const AValue: string): TMessengerMemberRole;
begin
  if (AValue = '') or SameText(AValue, 'member') then Exit(mmrMember);
  if SameText(AValue, 'moderator') then Exit(mmrModerator);
  if SameText(AValue, 'admin') then Exit(mmrAdmin);
  raise EArgumentException.Create('role must be member, moderator or admin');
end;

class function TMessengerGatewayConversationEndpointService.ResponseOf(
  const AInfo: TMessengerConversationInfo;
  AExisting: Boolean): TMessengerConversationResponse;
begin
  Result := Default(TMessengerConversationResponse);
  Result.ConversationId := AInfo.ConversationId;
  if AInfo.Kind = mckDirect then Result.Kind := 'direct' else Result.Kind := 'group';
  Result.GroupId := AInfo.GroupId;
  Result.Existing := AExisting;
end;

function TMessengerGatewayConversationEndpointService.CreateDirect(
  const AContext: IHttpContext;
  const ARequest: TMessengerCreateDirectRequest): TMessengerConversationResponse;
var
  Session: TMessengerSession;
  Created: TMessengerCreateConversationResult;
begin
  Session := FSessions.Resolve(AContext);
  Created := FLifecycle.CreateOrGetDirect(Session.UserId, ARequest.OtherUserId);
  Result := ResponseOf(Created.Conversation, Created.WasExisting);
end;

function TMessengerGatewayConversationEndpointService.CreateGroup(
  const AContext: IHttpContext;
  const ARequest: TMessengerCreateGroupRequest): TMessengerConversationResponse;
var
  Session: TMessengerSession;
  Info: TMessengerConversationInfo;
begin
  Session := FSessions.Resolve(AContext);
  Info := FLifecycle.CreateGroup(Session.UserId, ARequest.Title);
  Result := ResponseOf(Info, False);
end;

procedure TMessengerGatewayConversationEndpointService.AddMember(
  const AContext: IHttpContext; const ARequest: TMessengerMemberRequest);
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  FGroups.AddMember(ARequest.ConversationId, Session.UserId,
    ARequest.UserId, RoleFromText(ARequest.Role));
end;

procedure TMessengerGatewayConversationEndpointService.RemoveMember(
  const AContext: IHttpContext; const ARequest: TMessengerRemoveMemberRequest);
var
  Session: TMessengerSession;
begin
  Session := FSessions.Resolve(AContext);
  FGroups.RemoveMember(ARequest.ConversationId, Session.UserId, ARequest.UserId);
end;

class procedure TMessengerGatewayConversationEndpoints.Map(const Builder: TAppBuilder);
begin
  Builder.MapPost<TMessengerCreateDirectRequest,
    IMessengerGatewayConversationEndpointService, IHttpContext, IResult>(
    '/api/messenger/conversations/direct',
    function(Req: TMessengerCreateDirectRequest;
      Svc: IMessengerGatewayConversationEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.CreateDirect(Ctx, Req));
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerCreateGroupRequest,
    IMessengerGatewayConversationEndpointService, IHttpContext, IResult>(
    '/api/messenger/conversations/group',
    function(Req: TMessengerCreateGroupRequest;
      Svc: IMessengerGatewayConversationEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Result := Results.Ok(Svc.CreateGroup(Ctx, Req));
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerMemberRequest,
    IMessengerGatewayConversationEndpointService, IHttpContext, IResult>(
    '/api/messenger/groups/members',
    function(Req: TMessengerMemberRequest;
      Svc: IMessengerGatewayConversationEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Svc.AddMember(Ctx, Req);
      Result := Results.NoContent;
    end)
    .RequireAuthorization;

  Builder.MapPost<TMessengerRemoveMemberRequest,
    IMessengerGatewayConversationEndpointService, IHttpContext, IResult>(
    '/api/messenger/groups/members/remove',
    function(Req: TMessengerRemoveMemberRequest;
      Svc: IMessengerGatewayConversationEndpointService;
      Ctx: IHttpContext): IResult
    begin
      Svc.RemoveMember(Ctx, Req);
      Result := Results.NoContent;
    end)
    .RequireAuthorization;
end;

end.
