unit Dext.Messenger.Persistence;

interface

uses
  System.SysUtils,
  Dext.Net.Nats.JetStream,
  Dext.Messenger.Models;

type
  EMessengerPersistenceError = class(Exception);
  EMessengerPersistenceTransient = class(EMessengerPersistenceError);
  EMessengerPersistenceFatal = class(EMessengerPersistenceError);

  IMessengerMessageRepository = interface
    ['{4085ECFC-819B-43BE-B673-B603502AC67E}']
    procedure PersistMessage(const AMessage: TMessengerMessage;
      const ATargetUserId: string; APartition: Integer);
  end;

  TMessengerPersistenceProcessor = class
  private
    FJetStream: TDextNatsJetStreamContext;
    FRepository: IMessengerMessageRepository;
    FRetryDelayMs: Integer;
  public
    constructor Create(AJetStream: TDextNatsJetStreamContext;
      const ARepository: IMessengerMessageRepository; ARetryDelayMs: Integer = 1000);
    procedure Process(const AMsg: TNatsJsMsg);
  end;

implementation

uses
  Dext.Net.Nats.Protocol,
  Dext.Messenger.Codec.Json;

const
  HDR_TARGET_USER = 'X-Messenger-Target-User';
  HDR_PARTITION = 'X-Messenger-Partition';

constructor TMessengerPersistenceProcessor.Create(
  AJetStream: TDextNatsJetStreamContext;
  const ARepository: IMessengerMessageRepository;
  ARetryDelayMs: Integer);
begin
  inherited Create;
  if not Assigned(AJetStream) then raise EArgumentNilException.Create('AJetStream');
  if ARepository = nil then raise EArgumentNilException.Create('ARepository');
  if ARetryDelayMs < 0 then raise EArgumentOutOfRangeException.Create('ARetryDelayMs');
  FJetStream := AJetStream;
  FRepository := ARepository;
  FRetryDelayMs := ARetryDelayMs;
end;

procedure TMessengerPersistenceProcessor.Process(const AMsg: TNatsJsMsg);
var
  Message: TMessengerMessage;
  TargetUserId: string;
  PartitionText: string;
  Partition: Integer;
begin
  try
    TargetUserId := AMsg.Headers.GetValue(HDR_TARGET_USER);
    PartitionText := AMsg.Headers.GetValue(HDR_PARTITION);
    if TargetUserId = '' then
      raise EMessengerPersistenceFatal.Create('Missing target-user header');
    if (PartitionText = '') or (not TryStrToInt(PartitionText, Partition)) or
      (Partition < 0) then
      raise EMessengerPersistenceFatal.Create('Invalid partition header');

    Message := TMessengerJsonCodec.DecodeMessage(AMsg.Payload);
    FRepository.PersistMessage(Message, TargetUserId, Partition);

    { Persistence is the acknowledgement boundary. A worker crash before this
      ACK causes JetStream redelivery; repository writes therefore MUST be
      idempotent on message_id and sender/client_message_id. }
    FJetStream.Ack(AMsg);
  except
    on E: EMessengerPersistenceTransient do
    begin
      FJetStream.Nak(AMsg, FRetryDelayMs);
    end;
    on E: EMessengerPersistenceFatal do
    begin
      FJetStream.Term(AMsg);
    end;
    on E: Exception do
    begin
      { Unknown infrastructure exceptions are treated as transient. Poison-data
        validation must be raised explicitly as EMessengerPersistenceFatal. }
      FJetStream.Nak(AMsg, FRetryDelayMs);
    end;
  end;
end;

end.
