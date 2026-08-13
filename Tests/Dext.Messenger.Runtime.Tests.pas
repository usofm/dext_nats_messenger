unit Dext.Messenger.Runtime.Tests;

interface

uses
  System.SysUtils,
  Dext.Testing,
  Dext.Testing.Attributes,
  Dext.Testing.Fluent,
  Dext.Messenger.Connections,
  Dext.Messenger.Gateway.Core;

type
  [TestFixture('Dext Messenger Runtime')]
  TMessengerRuntimeTests = class
  public
    [Test, Category('Unit'), Category('Connections')]
    procedure ConnectionRegistry_ShouldSupportMultipleDevicesPerUser;
    [Test, Category('Unit'), Category('RateLimit')]
    procedure RateLimiter_ShouldIsolateUsersAndOperations;
  end;

implementation

procedure TMessengerRuntimeTests.ConnectionRegistry_ShouldSupportMultipleDevicesPerUser;
var
  Registry: IMessengerConnectionRegistry;
begin
  Registry := TMessengerMemoryConnectionRegistry.Create;
  Registry.RegisterConnection(TMessengerConnectionInfo.Create(
    'u-1', 'd-1', 's-1', 'gw-1', 'c-1', 1000));
  Registry.RegisterConnection(TMessengerConnectionInfo.Create(
    'u-1', 'd-2', 's-2', 'gw-1', 'c-2', 1001));
  Registry.RegisterConnection(TMessengerConnectionInfo.Create(
    'u-2', 'd-3', 's-3', 'gw-1', 'c-3', 1002));

  Should(Registry.ConnectionCountForUser('u-1')).Be(2);
  Should(Registry.ConnectionCountForUser('u-2')).Be(1);
  Should(Registry.TotalConnectionCount).Be(3);

  Registry.UnregisterConnection('c-1');
  Should(Registry.ConnectionCountForUser('u-1')).Be(1);
  Should(Registry.TotalConnectionCount).Be(2);
end;

procedure TMessengerRuntimeTests.RateLimiter_ShouldIsolateUsersAndOperations;
var
  Limiter: IMessengerGatewayRateLimiter;
begin
  Limiter := TMessengerFixedWindowRateLimiter.Create(1, 60000, 8);
  Should(Limiter.TryAcquire('u-1', 'message.send')).BeTrue;
  Should(Limiter.TryAcquire('u-1', 'message.send')).BeFalse;
  Should(Limiter.TryAcquire('u-2', 'message.send')).BeTrue;
  Should(Limiter.TryAcquire('u-1', 'receipt.write')).BeTrue;
end;

end.
