unit Dext.Messenger.Gateway;

interface

uses
  Dext.Web,
  Dext.Web.Interfaces;

type
  TMessengerGateway = record
  public
    class procedure Map(const App: IWebApplication); static;
    class procedure Shutdown; static;
  end;

implementation

uses
  System.SysUtils,
  Dext.Messenger.Gateway.Api,
  Dext.Messenger.Gateway.ConversationApi,
  Dext.Messenger.Gateway.SyncApi,
  Dext.Messenger.Gateway.ReceiptApi,
  Dext.Messenger.Gateway.MediaApi,
  Dext.Messenger.Gateway.Hosting;

class procedure TMessengerGateway.Map(const App: IWebApplication);
var
  Builder: TAppBuilder;
begin
  if App = nil then
    raise EArgumentNilException.Create('App');

  Builder := App.GetBuilder;
  TMessengerGatewayEndpoints.Map(Builder);
  TMessengerGatewayConversationEndpoints.Map(Builder);
  TMessengerGatewaySyncEndpoints.Map(Builder);
  TMessengerGatewayReceiptEndpoints.Map(Builder);
  TMessengerGatewayMediaEndpoints.Map(Builder);
  TMessengerGatewayHosting.MapRealtime(App.GetApplicationBuilder);
end;

class procedure TMessengerGateway.Shutdown;
begin
  TMessengerGatewayHosting.Shutdown;
end;

end.
