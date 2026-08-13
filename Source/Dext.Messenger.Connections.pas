unit Dext.Messenger.Connections;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

type
  TMessengerConnectionInfo = record
  public
    UserId: string;
    DeviceId: string;
    SessionId: string;
    GatewayId: string;
    ConnectionId: string;
    ConnectedAtUnixMs: Int64;
    class function Create(const AUserId, ADeviceId, ASessionId, AGatewayId,
      AConnectionId: string; AConnectedAtUnixMs: Int64): TMessengerConnectionInfo; static;
  end;

  IMessengerConnectionRegistry = interface
    ['{E8B8D227-4B5B-43A4-A9A4-6B40B0C5E685}']
    procedure RegisterConnection(const AInfo: TMessengerConnectionInfo);
    procedure UnregisterConnection(const AConnectionId: string);
    function ConnectionsForUser(const AUserId: string): TArray<TMessengerConnectionInfo>;
    function ConnectionCountForUser(const AUserId: string): Integer;
    function TotalConnectionCount: Integer;
  end;

  TMessengerMemoryConnectionRegistry = class(TInterfacedObject, IMessengerConnectionRegistry)
  private
    FLock: TMultiReadExclusiveWriteSynchronizer;
    FByConnection: TDictionary<string, TMessengerConnectionInfo>;
    FByUser: TObjectDictionary<string, TList<string>>;
    class procedure ValidateInfo(const AInfo: TMessengerConnectionInfo); static;
    procedure RemoveFromUserIndex(const AInfo: TMessengerConnectionInfo);
  public
    constructor Create;
    destructor Destroy; override;
    procedure RegisterConnection(const AInfo: TMessengerConnectionInfo);
    procedure UnregisterConnection(const AConnectionId: string);
    function ConnectionsForUser(const AUserId: string): TArray<TMessengerConnectionInfo>;
    function ConnectionCountForUser(const AUserId: string): Integer;
    function TotalConnectionCount: Integer;
  end;

implementation

class function TMessengerConnectionInfo.Create(const AUserId, ADeviceId,
  ASessionId, AGatewayId, AConnectionId: string;
  AConnectedAtUnixMs: Int64): TMessengerConnectionInfo;
begin
  Result := Default(TMessengerConnectionInfo);
  Result.UserId := AUserId;
  Result.DeviceId := ADeviceId;
  Result.SessionId := ASessionId;
  Result.GatewayId := AGatewayId;
  Result.ConnectionId := AConnectionId;
  Result.ConnectedAtUnixMs := AConnectedAtUnixMs;
end;

constructor TMessengerMemoryConnectionRegistry.Create;
begin
  inherited Create;
  FLock := TMultiReadExclusiveWriteSynchronizer.Create;
  FByConnection := TDictionary<string, TMessengerConnectionInfo>.Create;
  FByUser := TObjectDictionary<string, TList<string>>.Create([doOwnsValues]);
end;

destructor TMessengerMemoryConnectionRegistry.Destroy;
begin
  FByUser.Free;
  FByConnection.Free;
  FLock.Free;
  inherited;
end;

class procedure TMessengerMemoryConnectionRegistry.ValidateInfo(
  const AInfo: TMessengerConnectionInfo);
begin
  if AInfo.UserId = '' then raise EArgumentException.Create('user_id must not be empty');
  if AInfo.DeviceId = '' then raise EArgumentException.Create('device_id must not be empty');
  if AInfo.SessionId = '' then raise EArgumentException.Create('session_id must not be empty');
  if AInfo.GatewayId = '' then raise EArgumentException.Create('gateway_id must not be empty');
  if AInfo.ConnectionId = '' then raise EArgumentException.Create('connection_id must not be empty');
  if AInfo.ConnectedAtUnixMs <= 0 then raise EArgumentOutOfRangeException.Create('ConnectedAtUnixMs');
end;

procedure TMessengerMemoryConnectionRegistry.RemoveFromUserIndex(
  const AInfo: TMessengerConnectionInfo);
var
  List: TList<string>;
  I: Integer;
begin
  if not FByUser.TryGetValue(AInfo.UserId, List) then
    Exit;
  for I := List.Count - 1 downto 0 do
    if SameText(List[I], AInfo.ConnectionId) then
      List.Delete(I);
  if List.Count = 0 then
    FByUser.Remove(AInfo.UserId);
end;

procedure TMessengerMemoryConnectionRegistry.RegisterConnection(
  const AInfo: TMessengerConnectionInfo);
var
  Previous: TMessengerConnectionInfo;
  List: TList<string>;
begin
  ValidateInfo(AInfo);
  FLock.BeginWrite;
  try
    if FByConnection.TryGetValue(AInfo.ConnectionId, Previous) then
      RemoveFromUserIndex(Previous);

    FByConnection.AddOrSetValue(AInfo.ConnectionId, AInfo);
    if not FByUser.TryGetValue(AInfo.UserId, List) then
    begin
      List := TList<string>.Create;
      FByUser.Add(AInfo.UserId, List);
    end;
    if List.IndexOf(AInfo.ConnectionId) < 0 then
      List.Add(AInfo.ConnectionId);
  finally
    FLock.EndWrite;
  end;
end;

procedure TMessengerMemoryConnectionRegistry.UnregisterConnection(
  const AConnectionId: string);
var
  Existing: TMessengerConnectionInfo;
begin
  if AConnectionId = '' then Exit;
  FLock.BeginWrite;
  try
    if not FByConnection.TryGetValue(AConnectionId, Existing) then
      Exit;
    RemoveFromUserIndex(Existing);
    FByConnection.Remove(AConnectionId);
  finally
    FLock.EndWrite;
  end;
end;

function TMessengerMemoryConnectionRegistry.ConnectionsForUser(
  const AUserId: string): TArray<TMessengerConnectionInfo>;
var
  Ids: TList<string>;
  I, N: Integer;
  Info: TMessengerConnectionInfo;
begin
  Result := nil;
  if AUserId = '' then Exit;
  FLock.BeginRead;
  try
    if not FByUser.TryGetValue(AUserId, Ids) then Exit;
    SetLength(Result, Ids.Count);
    N := 0;
    for I := 0 to Ids.Count - 1 do
      if FByConnection.TryGetValue(Ids[I], Info) then
      begin
        Result[N] := Info;
        Inc(N);
      end;
    SetLength(Result, N);
  finally
    FLock.EndRead;
  end;
end;

function TMessengerMemoryConnectionRegistry.ConnectionCountForUser(
  const AUserId: string): Integer;
var
  Ids: TList<string>;
begin
  Result := 0;
  FLock.BeginRead;
  try
    if FByUser.TryGetValue(AUserId, Ids) then
      Result := Ids.Count;
  finally
    FLock.EndRead;
  end;
end;

function TMessengerMemoryConnectionRegistry.TotalConnectionCount: Integer;
begin
  FLock.BeginRead;
  try
    Result := FByConnection.Count;
  finally
    FLock.EndRead;
  end;
end;

end.
