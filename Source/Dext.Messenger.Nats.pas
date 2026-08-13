unit Dext.Messenger.Nats;

interface

uses
  System.SysUtils,
  Dext.Net.Nats,
  Dext.Messenger.Transport;

type
  TDextMessengerNatsTransport = class;

  TDextMessengerNatsSubscription = class(TInterfacedObject, IMessengerSubscription)
  private
    FOwner: TDextMessengerNatsTransport;
    FOwnerRef: IMessengerTransport;
    FSid: Integer;
    FActive: Boolean;
  public
    constructor Create(AOwner: TDextMessengerNatsTransport; ASid: Integer);
    destructor Destroy; override;
    procedure Unsubscribe;
  end;

  TDextMessengerNatsTransport = class(TInterfacedObject, IMessengerTransport)
  private
    FNats: TDextNatsClient;
    FOwnsClient: Boolean;
  public
    constructor Create(ANats: TDextNatsClient; AOwnsClient: Boolean = False);
    destructor Destroy; override;

    procedure Publish(const ASubject: string; const APayload: TBytes);
    function Subscribe(
      const ASubject: string;
      const AHandler: TMessengerTransportHandler;
      const AQueueGroup: string = ''
    ): IMessengerSubscription;
    function IsConnected: Boolean;

    property NatsClient: TDextNatsClient read FNats;
  end;

implementation

{ TDextMessengerNatsSubscription }

constructor TDextMessengerNatsSubscription.Create(
  AOwner: TDextMessengerNatsTransport;
  ASid: Integer
);
begin
  inherited Create;
  FOwner := AOwner;
  FOwnerRef := AOwner;
  FSid := ASid;
  FActive := True;
end;

destructor TDextMessengerNatsSubscription.Destroy;
begin
  Unsubscribe;
  FOwner := nil;
  FOwnerRef := nil;
  inherited;
end;

procedure TDextMessengerNatsSubscription.Unsubscribe;
begin
  if not FActive then
    Exit;

  FActive := False;
  if Assigned(FOwner) and Assigned(FOwner.FNats) then
    FOwner.FNats.Unsubscribe(FSid);
end;

{ TDextMessengerNatsTransport }

constructor TDextMessengerNatsTransport.Create(
  ANats: TDextNatsClient;
  AOwnsClient: Boolean
);
begin
  inherited Create;
  if not Assigned(ANats) then
    raise EArgumentNilException.Create('ANats');

  FNats := ANats;
  FOwnsClient := AOwnsClient;
end;

destructor TDextMessengerNatsTransport.Destroy;
begin
  if FOwnsClient then
    FNats.Free;
  FNats := nil;
  inherited;
end;

function TDextMessengerNatsTransport.IsConnected: Boolean;
begin
  Result := Assigned(FNats) and FNats.Connected;
end;

procedure TDextMessengerNatsTransport.Publish(
  const ASubject: string;
  const APayload: TBytes
);
begin
  if not Assigned(FNats) then
    raise Exception.Create('NATS transport is not initialized');

  FNats.Publish(ASubject, APayload);
end;

function TDextMessengerNatsTransport.Subscribe(
  const ASubject: string;
  const AHandler: TMessengerTransportHandler;
  const AQueueGroup: string
): IMessengerSubscription;
var
  Sid: Integer;
begin
  if not Assigned(FNats) then
    raise Exception.Create('NATS transport is not initialized');

  if not Assigned(AHandler) then
    raise EArgumentNilException.Create('AHandler');

  Sid := FNats.Subscribe(
    ASubject,
    procedure(const AMsg: TNatsMsg)
    begin
      AHandler(AMsg.Subject, AMsg.Payload);
    end,
    AQueueGroup
  );

  Result := TDextMessengerNatsSubscription.Create(Self, Sid);
end;

end.
