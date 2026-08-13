unit Dext.Messenger.Gateway.Hosting;

interface

uses
  Dext.Web.Interfaces;

type
  TMessengerGatewayHosting = record
  public const
    HubPath = '/hubs/messenger';
    DefaultMaxHubMessageBytes = Int64(128) * 1024;
  public
    class procedure MapRealtime(const App: IApplicationBuilder;
      AMaximumReceiveMessageSize: Int64 = DefaultMaxHubMessageBytes); static;
    class procedure Shutdown; static;
  end;

implementation

uses
  System.SysUtils,
  Dext.Web.Hubs.Types,
  Dext.Web.Hubs.Extensions,
  Dext.Messenger.Gateway.Hubs;

class procedure TMessengerGatewayHosting.MapRealtime(
  const App: IApplicationBuilder; AMaximumReceiveMessageSize: Int64);
var
  Options: THubOptions;
begin
  if App = nil then raise EArgumentNilException.Create('App');
  if AMaximumReceiveMessageSize <= 0 then
    raise EArgumentOutOfRangeException.Create('AMaximumReceiveMessageSize');

  Options := THubOptions.Default;
  Options.EnableDetailedErrors := False;
  Options.ClientTimeoutInterval := 60;
  Options.KeepAliveInterval := 15;
  Options.MaximumReceiveMessageSize := AMaximumReceiveMessageSize;
  Options.RequireHubMethodAttribute := True;
  { Messenger requires bidirectional realtime. Keep the production transport
    surface small and predictable; HTTPS APIs remain available for commands,
    sync/history and media flows. }
  Options.EnabledTransports := ['WebSockets'];

  THubExtensions.UseHubs(App, Options);
  THubExtensions.MapHub(App, HubPath, TMessengerHub);
end;

class procedure TMessengerGatewayHosting.Shutdown;
begin
  THubExtensions.ShutdownHubs;
end;

end.
