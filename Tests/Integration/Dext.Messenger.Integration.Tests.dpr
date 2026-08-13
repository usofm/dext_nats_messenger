program Dext.Messenger.Integration.Tests;

{$APPTYPE CONSOLE}

uses
  Dext.MM,
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.DateUtils,
  System.Rtti,
  FireDAC.Phys.PG,
  Dext.Collections,
  Dext.Entity,
  Dext.Entity.Setup,
  Dext.Entity.Drivers.Interfaces,
  Dext.Net.Nats,
  Dext.Net.Nats.Protocol,
  Dext.Net.Nats.JetStream,
  Dext.Messenger.Models,
  Dext.Messenger.Commands,
  Dext.Messenger.Acceptance,
  Dext.Messenger.Outbox,
  Dext.Messenger.Workers,
  Dext.Messenger.Transport,
  Dext.Messenger.Nats,
  Dext.Messenger.Subjects,
  Dext.Messenger.Codec.Json,
  Dext.Messenger.JetStream.Topology,
  Dext.Messenger.JetStream.AcceptedSink,
  Dext.Messenger.Persistence.DbContext,
  Dext.Messenger.Persistence.PostgreSQL;

type
  EIntegrationTestFailure = class(Exception);

var
  Passed: Integer;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise EIntegrationTestFailure.Create(AMessage);
  Inc(Passed);
  Writeln('[PASS] ', AMessage);
end;

function RequiredEnv(const AName: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    raise EIntegrationTestFailure.CreateFmt('Missing required environment variable %s', [AName]);
end;

function CurrentUnixMs: Int64;
begin
  Result := DateTimeToUnix(Now, True) * Int64(1000) + MilliSecondOf(Now);
end;

procedure AddStringParam(const ACmd: IDbCommand; const AName, AValue: string);
begin
  ACmd.AddParam(AName, TValue.From<string>(AValue));
end;

procedure SeedConversation(const AContext: TMessengerDbContext;
  const AConversationId, AUserId: string);
var
  Cmd: IDbCommand;
begin
  Cmd := AContext.Connection.CreateCommand(
    'insert into messenger_conversations (id, kind, created_by) ' +
    'values (:id, 1, :created_by)');
  AddStringParam(Cmd, 'id', AConversationId);
  AddStringParam(Cmd, 'created_by', AUserId);
  Check(Cmd.ExecuteNonQuery = 1, 'PostgreSQL seeded an isolated conversation');
end;

function NewProposal(const AMessageId: string;
  const ACommand: TMessengerAcceptMessageCommand; ACreatedAtUnixMs: Int64;
  APartition: Integer): TMessengerAcceptedMessage;
var
  Message: TMessengerMessage;
begin
  Message := TMessengerMessage.CreateV1(
    AMessageId,
    ACommand.ClientMessageId,
    ACommand.ConversationId,
    ACommand.SenderUserId,
    ACommand.Kind,
    ACreatedAtUnixMs,
    ACommand.PayloadJson);
  Result := TMessengerAcceptedMessage.Create(
    Message,
    ACommand.DestinationKind,
    ACommand.DestinationId,
    APartition,
    0);
end;

procedure TestPostgreSQL(const ARunId, AConnectionString: string);
var
  Options: TDbContextOptions;
  Context: TMessengerDbContext;
  StoreObject: TMessengerPostgreSQLStore;
  AcceptanceStore: IMessengerAcceptanceStore;
  OutboxStore: IMessengerOutboxStore;
  ConversationId, SenderId, TargetId: string;
  Command1, Command2, ConflictCommand: TMessengerAcceptMessageCommand;
  Proposal1, Proposal2: TMessengerAcceptedMessage;
  Stored1, Duplicate1, Stored2: TMessengerAcceptanceStoreResult;
  Items, RetryItems: TArray<TMessengerOutboxItem>;
  NowMs: Int64;
  ConflictRaised: Boolean;
begin
  Writeln('--- PostgreSQL acceptance/outbox integration ---');
  Options := TDbContextOptions.Create;
  Context := nil;
  AcceptanceStore := nil;
  OutboxStore := nil;
  try
    Options.UsePostgreSQL(AConnectionString);
    Context := TMessengerDbContext.Create(Options);
    StoreObject := TMessengerPostgreSQLStore.Create(Context);
    AcceptanceStore := StoreObject;
    OutboxStore := StoreObject;

    ConversationId := 'it-conv-' + ARunId;
    SenderId := 'it-sender-' + ARunId;
    TargetId := 'it-target-' + ARunId;
    SeedConversation(Context, ConversationId, SenderId);

    NowMs := CurrentUnixMs;
    Command1 := TMessengerAcceptMessageCommand.CreateDirect(
      'client-1-' + ARunId, ConversationId, SenderId, TargetId,
      mmkText, '{"text":"first"}');
    Proposal1 := NewProposal('message-1-' + ARunId, Command1, NowMs, 7);

    Stored1 := AcceptanceStore.AcceptOrGet(Command1, Proposal1);
    Check(not Stored1.WasDuplicate, 'first command was committed as a new message');
    Check(Stored1.Accepted.Sequence = 1, 'first message received conversation sequence 1');

    Duplicate1 := AcceptanceStore.AcceptOrGet(Command1, Proposal1);
    Check(Duplicate1.WasDuplicate, 'same client message id was detected as a duplicate');
    Check(Duplicate1.Accepted.Message.MessageId = Stored1.Accepted.Message.MessageId,
      'duplicate returned the canonical committed message');
    Check(Duplicate1.Accepted.Sequence = Stored1.Accepted.Sequence,
      'duplicate preserved the canonical conversation sequence');

    ConflictCommand := TMessengerAcceptMessageCommand.CreateDirect(
      Command1.ClientMessageId, ConversationId, SenderId, TargetId,
      mmkText, '{"text":"changed"}');
    ConflictRaised := False;
    try
      AcceptanceStore.AcceptOrGet(
        ConflictCommand,
        NewProposal('message-conflict-' + ARunId, ConflictCommand, NowMs + 1, 7));
    except
      on EMessengerIdempotencyConflict do
        ConflictRaised := True;
    end;
    Check(ConflictRaised, 'changed payload with the same client id raised an idempotency conflict');

    Command2 := TMessengerAcceptMessageCommand.CreateDirect(
      'client-2-' + ARunId, ConversationId, SenderId, TargetId,
      mmkText, '{"text":"second"}');
    Proposal2 := NewProposal('message-2-' + ARunId, Command2, NowMs + 2, 7);
    Stored2 := AcceptanceStore.AcceptOrGet(Command2, Proposal2);
    Check(Stored2.Accepted.Sequence = 2, 'second message received conversation sequence 2');

    Items := OutboxStore.ClaimBatch('worker-a-' + ARunId, NowMs + 5000, 30000, 10);
    Check(Length(Items) = 2, 'outbox claim leased both pending events');
    Check(Items[0].LeaseOwner = 'worker-a-' + ARunId, 'claimed outbox item recorded its lease owner');

    OutboxStore.MarkPublished(Items[0].OutboxId, Items[0].LeaseOwner);
    OutboxStore.ReleaseForRetry(
      Items[1].OutboxId, Items[1].LeaseOwner, NowMs + 10000, 'integration retry');

    RetryItems := OutboxStore.ClaimBatch('worker-b-' + ARunId, NowMs + 9000, 30000, 10);
    Check(Length(RetryItems) = 0, 'released outbox item stayed unavailable before retry time');
    RetryItems := OutboxStore.ClaimBatch('worker-b-' + ARunId, NowMs + 11000, 30000, 10);
    Check(Length(RetryItems) = 1, 'released outbox item became claimable at retry time');
    Check(RetryItems[0].AttemptCount = 1, 'outbox retry incremented attempt count');
    OutboxStore.MarkPublished(RetryItems[0].OutboxId, RetryItems[0].LeaseOwner);
  finally
    OutboxStore := nil;
    AcceptanceStore := nil;
    Context.Free;
    Options.Free;
  end;
end;

procedure KillExactProcess(APid: Cardinal);
var
  ProcessHandle: THandle;
begin
  ProcessHandle := OpenProcess(PROCESS_TERMINATE or SYNCHRONIZE, False, APid);
  if ProcessHandle = 0 then
    RaiseLastOSError;
  try
    if not TerminateProcess(ProcessHandle, 77) then
      RaiseLastOSError;
    WaitForSingleObject(ProcessHandle, 5000);
  finally
    CloseHandle(ProcessHandle);
  end;
end;

function WaitForReconnect(const AClient: TDextNatsClient; ATimeoutMs: Cardinal): Boolean;
var
  Started: UInt64;
begin
  Started := GetTickCount64;
  repeat
    if AClient.Connected and (AClient.Metrics.Reconnects > 0) then
      Exit(True);
    TThread.Sleep(50);
  until GetTickCount64 - Started >= ATimeoutMs;
  Result := False;
end;

procedure TestNats(const ARunId, AHost: string; APort: Word; AKillPid: Cardinal);
var
  Options: TDextNatsOptions;
  Client: TDextNatsClient;
  Transport: IMessengerTransport;
  Subscription: IMessengerSubscription;
  ReceivedEvent: TEvent;
  ReceivedPayload, Subject, ConsumerName: string;
  JetStream: TDextNatsJetStreamContext;
  AcceptedInfo, DlqInfo, BeforeInfo, AfterInfo: TNatsStreamInfo;
  ConsumerConfig: TNatsConsumerConfig;
  Messages: IList<TNatsJsMsg>;
  Accepted: TMessengerAcceptedMessage;
  Decoded: TMessengerMessage;
  Publisher: IMessengerAcceptedPublisher;
  Partition: Integer;
begin
  Writeln('--- NATS Core/JetStream/reconnect integration ---');
  Options := TDextNatsOptions.CreateDefault;
  Options.Name := 'dext-messenger-it-' + ARunId;
  Options.ReconnectWaitMs := 100;
  Options.ConnectTimeoutMs := 2000;
  Options.RequestTimeoutMs := 10000;
  Client := TDextNatsClient.Create(Options);
  Transport := nil;
  Subscription := nil;
  JetStream := nil;
  Publisher := nil;
  ReceivedEvent := TEvent.Create(nil, True, False, '');
  try
    Client.Connect(AHost, APort);
    Check(Client.Connected, 'NATS client connected to the isolated cluster');

    Transport := TDextMessengerNatsTransport.Create(Client, False);
    Subject := 'it.core.' + ARunId;
    Subscription := Transport.Subscribe(Subject,
      procedure(const ASubject: string; const APayload: TBytes)
      begin
        ReceivedPayload := TEncoding.UTF8.GetString(APayload);
        ReceivedEvent.SetEvent;
      end);
    Transport.Publish(Subject, TEncoding.UTF8.GetBytes('before-failover'));
    Check(ReceivedEvent.WaitFor(5000) = wrSignaled, 'Core NATS delivered before failover');
    Check(ReceivedPayload = 'before-failover', 'Core NATS preserved the published payload');

    JetStream := TDextNatsJetStreamContext.Create(Client);
    AcceptedInfo := TMessengerJetStreamTopology.EnsureAcceptedMessagesStream(JetStream, 3);
    DlqInfo := TMessengerJetStreamTopology.EnsureDeliveryDeadLetterStream(JetStream, 3);
    Check(AcceptedInfo.Config.NumReplicas = 3, 'accepted-message stream has three replicas');
    Check(DlqInfo.Config.NumReplicas = 3, 'dead-letter stream has three replicas');

    Partition := StrToIntDef(Copy(ARunId, Length(ARunId), 1), 0) + 20;
    ConsumerName := 'it_' + ARunId;
    ConsumerConfig := TNatsConsumerConfig.CreateDefault(
      ConsumerName, TMessengerSubjects.AcceptedMessagePartition(Partition));
    ConsumerConfig.DeliverPolicy := dpNew;
    ConsumerConfig.AckPolicy := apExplicit;
    JetStream.CreateConsumer(TMessengerJetStreamTopology.AcceptedMessagesStream, ConsumerConfig);

    BeforeInfo := JetStream.GetStreamInfo(TMessengerJetStreamTopology.AcceptedMessagesStream);
    Accepted := TMessengerAcceptedMessage.Create(
      TMessengerMessage.CreateV1(
        'nats-message-' + ARunId,
        'nats-client-' + ARunId,
        'nats-conversation-' + ARunId,
        'nats-sender-' + ARunId,
        mmkText,
        CurrentUnixMs,
        '{"text":"jetstream"}'),
      mdkUser,
      'nats-target-' + ARunId,
      Partition,
      1);
    Publisher := TMessengerJetStreamAcceptedSink.Create(JetStream);
    Publisher.PublishAccepted(Accepted);
    Publisher.PublishAccepted(Accepted);
    AfterInfo := JetStream.GetStreamInfo(TMessengerJetStreamTopology.AcceptedMessagesStream);
    Check(AfterInfo.Messages = BeforeInfo.Messages + 1,
      'JetStream Nats-Msg-Id deduplicated the retry publish');

    Messages := JetStream.Fetch(
      TMessengerJetStreamTopology.AcceptedMessagesStream, ConsumerName, 1, 5000);
    Check(Messages.Count = 1, 'pull consumer fetched the accepted message');
    Check(Messages[0].Headers.GetValue('X-Messenger-Event-Type') = 'message.accepted.v1',
      'accepted event carried the versioned event-type header');
    Check(Messages[0].Headers.GetValue('X-Messenger-Sequence') = '1',
      'accepted event carried its conversation sequence header');
    Decoded := TMessengerJsonCodec.DecodeMessage(Messages[0].Payload);
    Check(Decoded.MessageId = Accepted.Message.MessageId,
      'accepted event payload decoded to the original message');
    JetStream.Ack(Messages[0]);
    JetStream.DeleteConsumer(TMessengerJetStreamTopology.AcceptedMessagesStream, ConsumerName);

    if AKillPid <> 0 then
    begin
      ReceivedEvent.ResetEvent;
      ReceivedPayload := '';
      KillExactProcess(AKillPid);
      Check(WaitForReconnect(Client, 15000), 'NATS client reconnected after its server process stopped');
      Transport.Publish(Subject, TEncoding.UTF8.GetBytes('after-failover'));
      Check(ReceivedEvent.WaitFor(5000) = wrSignaled,
        'Core NATS subscription resumed after reconnect');
      Check(ReceivedPayload = 'after-failover',
        'Core NATS delivered the post-failover payload');
      AfterInfo := JetStream.GetStreamInfo(TMessengerJetStreamTopology.AcceptedMessagesStream);
      Check(AfterInfo.Config.NumReplicas = 3,
        'JetStream remained available with one cluster node down');
    end;
  finally
    Publisher := nil;
    JetStream.Free;
    Subscription := nil;
    Transport := nil;
    Client.Free;
    ReceivedEvent.Free;
  end;
end;

var
  RunId, ConnectionString, NatsHost: string;
  NatsPort: Integer;
  KillPid: Cardinal;
begin
  Passed := 0;
  try
    RunId := RequiredEnv('MESSENGER_TEST_RUN_ID');
    ConnectionString := RequiredEnv('MESSENGER_TEST_PG');
    NatsHost := RequiredEnv('MESSENGER_TEST_NATS_HOST');
    NatsPort := StrToInt(RequiredEnv('MESSENGER_TEST_NATS_PORT'));
    KillPid := StrToIntDef(GetEnvironmentVariable('MESSENGER_TEST_NATS_KILL_PID'), 0);

    TestPostgreSQL(RunId, ConnectionString);
    TestNats(RunId, NatsHost, NatsPort, KillPid);
    Writeln('Integration tests passed: ', Passed);
    ExitCode := 0;
  except
    on E: Exception do
    begin
      Writeln('[FAIL] ', E.ClassName, ': ', E.Message);
      Writeln('Integration assertions passed before failure: ', Passed);
      ExitCode := 1;
    end;
  end;
end.
