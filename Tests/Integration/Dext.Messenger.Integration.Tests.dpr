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
  Dext.Messenger.DeadLetter,
  Dext.Messenger.Delivery,
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

  TIntegrationClock = class(TInterfacedObject, IMessengerClock)
  private
    FUnixMs: Int64;
  public
    constructor Create(AUnixMs: Int64);
    function UnixTimeMilliseconds: Int64;
  end;

  TRaisingDeadLetterSink = class(TInterfacedObject, IMessengerDeadLetterSink)
  public
    procedure Write(const ADeadLetter: TMessengerDeadLetter);
  end;

var
  Passed: Integer;

constructor TIntegrationClock.Create(AUnixMs: Int64);
begin
  inherited Create;
  FUnixMs := AUnixMs;
end;

function TIntegrationClock.UnixTimeMilliseconds: Int64;
begin
  Result := FUnixMs;
end;

procedure TRaisingDeadLetterSink.Write(
  const ADeadLetter: TMessengerDeadLetter);
begin
  raise Exception.Create('Injected DLQ outage');
end;

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

function QueryInt64(const AContext: TMessengerDbContext; const ASql,
  AParamName, AParamValue: string): Int64;
var
  Cmd: IDbCommand;
  Reader: IDbReader;
begin
  Cmd := AContext.Connection.CreateCommand(ASql);
  AddStringParam(Cmd, AParamName, AParamValue);
  Reader := Cmd.ExecuteQuery;
  try
    if not Reader.Next then
      raise EIntegrationTestFailure.Create('Expected scalar query result');
    Result := Reader.GetInt64(0);
  finally
    Reader.Close;
  end;
end;

procedure TestPostgreSQL(const ARunId, AConnectionString: string);
var
  Options: TDbContextOptions;
  Context: TMessengerDbContext;
  StoreObject: TMessengerPostgreSQLStore;
  AcceptanceStore: IMessengerAcceptanceStore;
  OutboxStore: IMessengerOutboxStore;
  ConversationId, SenderId, TargetId: string;
  Command1, Command2, Command3, ConflictCommand,
    RollbackCommand: TMessengerAcceptMessageCommand;
  Proposal1, Proposal2, Proposal3: TMessengerAcceptedMessage;
  Stored1, Duplicate1, Stored2, Stored3: TMessengerAcceptanceStoreResult;
  Items, RetryItems, CrashItems, ReclaimedItems: TArray<TMessengerOutboxItem>;
  NowMs: Int64;
  ConflictRaised, RollbackRaised: Boolean;
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

    RollbackCommand := TMessengerAcceptMessageCommand.CreateDirect(
      'client-rollback-' + ARunId, ConversationId, SenderId, TargetId,
      mmkText, '{"text":"must-rollback"}');
    RollbackRaised := False;
    try
      AcceptanceStore.AcceptOrGet(
        RollbackCommand,
        NewProposal(Stored1.Accepted.Message.MessageId,
          RollbackCommand, NowMs + 3, 7));
    except
      on Exception do
        RollbackRaised := True;
    end;
    Check(RollbackRaised, 'message insert failure was surfaced to the caller');
    Check(QueryInt64(Context,
      'select last_sequence from messenger_conversations where id = :id',
      'id', ConversationId) = 2,
      'failed message insert rolled back the allocated conversation sequence');
    Check(QueryInt64(Context,
      'select count(*) from messenger_messages where client_message_id = :client_id',
      'client_id', RollbackCommand.ClientMessageId) = 0,
      'failed acceptance left no partial message row');

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

    Command3 := TMessengerAcceptMessageCommand.CreateDirect(
      'client-3-' + ARunId, ConversationId, SenderId, TargetId,
      mmkText, '{"text":"worker-crash"}');
    Proposal3 := NewProposal('message-3-' + ARunId, Command3, NowMs + 4, 7);
    Stored3 := AcceptanceStore.AcceptOrGet(Command3, Proposal3);
    Check(Stored3.Accepted.Sequence = 3,
      'sequence allocation continued from the last committed value after rollback');

    CrashItems := OutboxStore.ClaimBatch(
      'worker-crashed-' + ARunId, NowMs + 12000, 1000, 10);
    Check(Length(CrashItems) = 1, 'crashed worker simulation acquired one outbox lease');
    ReclaimedItems := OutboxStore.ClaimBatch(
      'worker-recovery-' + ARunId, NowMs + 12500, 30000, 10);
    Check(Length(ReclaimedItems) = 0,
      'another worker could not steal an unexpired outbox lease');
    ReclaimedItems := OutboxStore.ClaimBatch(
      'worker-recovery-' + ARunId, NowMs + 14000, 30000, 10);
    Check(Length(ReclaimedItems) = 1,
      'another worker reclaimed the outbox item after lease expiry');
    Check(ReclaimedItems[0].OutboxId = CrashItems[0].OutboxId,
      'lease recovery reclaimed the exact abandoned outbox item');
    OutboxStore.MarkPublished(
      ReclaimedItems[0].OutboxId, ReclaimedItems[0].LeaseOwner);
  finally
    OutboxStore := nil;
    AcceptanceStore := nil;
    Context.Free;
    Options.Free;
  end;
end;

procedure TestPostgreSQLOutage(const AConnectionString: string);
var
  Options: TDbContextOptions;
  Context: TMessengerDbContext;
  Cmd: IDbCommand;
  Reader: IDbReader;
  FailedClosed: Boolean;
begin
  Writeln('--- PostgreSQL outage integration ---');
  Options := TDbContextOptions.Create;
  Context := nil;
  FailedClosed := False;
  try
    Options.UsePostgreSQL(AConnectionString);
    try
      Context := TMessengerDbContext.Create(Options);
      Cmd := Context.Connection.CreateCommand('select 1');
      Reader := Cmd.ExecuteQuery;
      try
        Reader.Next;
      finally
        Reader.Close;
      end;
    except
      on Exception do
        FailedClosed := True;
    end;
    Check(FailedClosed,
      'unavailable PostgreSQL failed closed instead of returning false success');
  finally
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

function WaitForStreamInfo(const AJetStream: TDextNatsJetStreamContext;
  const AStreamName: string; ATimeoutMs: Cardinal;
  out AInfo: TNatsStreamInfo): Boolean;
var
  Started: UInt64;
begin
  Started := GetTickCount64;
  repeat
    try
      AInfo := AJetStream.GetStreamInfo(AStreamName);
      Exit(True);
    except
      on EDextNatsException do
        TThread.Sleep(250);
    end;
  until GetTickCount64 - Started >= ATimeoutMs;
  Result := False;
end;

procedure CreatePullConsumer(const AJetStream: TDextNatsJetStreamContext;
  const AStreamName, AConsumerName, AFilterSubject: string;
  ADeliverPolicy: TNatsDeliverPolicy);
var
  Config: TNatsConsumerConfig;
begin
  Config := TNatsConsumerConfig.CreateDefault(AConsumerName, AFilterSubject);
  Config.DeliverPolicy := ADeliverPolicy;
  Config.AckPolicy := apExplicit;
  Config.AckWait := Int64(5000) * 1000000;
  AJetStream.CreateConsumer(AStreamName, Config);
end;

procedure PublishPoison(const AJetStream: TDextNatsJetStreamContext;
  const ARunId: string; APartition: Integer);
var
  Options: TNatsJetStreamPublishOptions;
begin
  Options := TNatsJetStreamPublishOptions.CreateDefault;
  Options.ExpectedStream := TMessengerJetStreamTopology.AcceptedMessagesStream;
  Options.MsgId := 'poison:' + ARunId + ':' + IntToStr(APartition);
  Options.ExtraHeaders := nil;
  Options.ExtraHeaders.Add('X-Messenger-Event-Type', 'unsupported.event.v9');
  Options.ExtraHeaders.Add('X-Messenger-Partition', IntToStr(APartition));
  AJetStream.Publish(
    TMessengerSubjects.AcceptedMessagePartition(APartition),
    TEncoding.UTF8.GetBytes('{"poison":true}'),
    Options);
end;

procedure TestJetStreamReplay(const AJetStream: TDextNatsJetStreamContext;
  const ARunId: string; APartition: Integer;
  const AExpectedMessageId: string);
var
  ConsumerName: string;
  Messages: IList<TNatsJsMsg>;
  Decoded: TMessengerMessage;
begin
  ConsumerName := 'replay_' + ARunId;
  CreatePullConsumer(
    AJetStream,
    TMessengerJetStreamTopology.AcceptedMessagesStream,
    ConsumerName,
    TMessengerSubjects.AcceptedMessagePartition(APartition),
    dpAll);
  try
    Messages := AJetStream.Fetch(
      TMessengerJetStreamTopology.AcceptedMessagesStream,
      ConsumerName, 1, 5000);
    Check(Messages.Count = 1,
      'consumer created after publication replayed the stored accepted event');
    Decoded := TMessengerJsonCodec.DecodeMessage(Messages[0].Payload);
    Check(Decoded.MessageId = AExpectedMessageId,
      'replayed event preserved the original message identity');
    AJetStream.Ack(Messages[0]);
  finally
    AJetStream.DeleteConsumer(
      TMessengerJetStreamTopology.AcceptedMessagesStream, ConsumerName);
  end;
end;

procedure TestDeadLetterPaths(const AJetStream: TDextNatsJetStreamContext;
  const AClient: TDextNatsClient; const ATransport: IMessengerTransport;
  const ARunId: string;
  APartition: Integer);
var
  SourceConsumer, DlqConsumer, RetryConsumer: string;
  SourceMessages, DlqMessages, Redelivered: IList<TNatsJsMsg>;
  Clock: IMessengerClock;
  DeadLetterSink: IMessengerDeadLetterSink;
  Processor: TMessengerJetStreamDeliveryProcessor;
  OriginalSequence: UInt64;
begin
  SourceConsumer := 'poison_' + ARunId;
  DlqConsumer := 'dlq_' + ARunId;
  CreatePullConsumer(
    AJetStream,
    TMessengerJetStreamTopology.AcceptedMessagesStream,
    SourceConsumer,
    TMessengerSubjects.AcceptedMessagePartition(APartition),
    dpNew);
  CreatePullConsumer(
    AJetStream,
    TMessengerJetStreamTopology.DeliveryDeadLetterStream,
    DlqConsumer,
    TMessengerSubjects.DeliveryDeadLetter(APartition),
    dpNew);
  try
    PublishPoison(AJetStream, ARunId, APartition);
    SourceMessages := AJetStream.Fetch(
      TMessengerJetStreamTopology.AcceptedMessagesStream,
      SourceConsumer, 1, 5000);
    Check(SourceMessages.Count = 1, 'delivery consumer fetched the poison event');
    OriginalSequence := SourceMessages[0].StreamSequence;

    Clock := TIntegrationClock.Create(CurrentUnixMs);
    DeadLetterSink := TMessengerJetStreamDeadLetterSink.Create(AJetStream);
    Processor := TMessengerJetStreamDeliveryProcessor.Create(
      AJetStream, ATransport, DeadLetterSink, Clock, 0);
    try
      Processor.Process(SourceMessages[0]);
      AClient.Flush(2000);
    finally
      Processor.Free;
      DeadLetterSink := nil;
      Clock := nil;
    end;

    DlqMessages := AJetStream.Fetch(
      TMessengerJetStreamTopology.DeliveryDeadLetterStream,
      DlqConsumer, 1, 5000);
    Check(DlqMessages.Count = 1, 'poison event was durably copied to the DLQ');
    Check(DlqMessages[0].Headers.GetValue('X-Messenger-DLQ-Error-Class') =
      'EMessengerDeliveryPoison', 'DLQ retained the poison error class');
    Check(DlqMessages[0].Headers.GetValue('X-Messenger-DLQ-Source-Sequence') =
      UIntToStr(OriginalSequence), 'DLQ retained the source stream sequence');
    Check(TEncoding.UTF8.GetString(DlqMessages[0].Payload) = '{"poison":true}',
      'DLQ retained the diagnostic source payload');
    AJetStream.Ack(DlqMessages[0]);

    SourceMessages := AJetStream.Fetch(
      TMessengerJetStreamTopology.AcceptedMessagesStream,
      SourceConsumer, 1, 300);
    Check(SourceMessages.Count = 0,
      'source poison event stopped redelivery only after durable DLQ write');
  finally
    AJetStream.DeleteConsumer(
      TMessengerJetStreamTopology.AcceptedMessagesStream, SourceConsumer);
    AJetStream.DeleteConsumer(
      TMessengerJetStreamTopology.DeliveryDeadLetterStream, DlqConsumer);
  end;

  Inc(APartition);
  RetryConsumer := 'dlqfail_' + ARunId;
  CreatePullConsumer(
    AJetStream,
    TMessengerJetStreamTopology.AcceptedMessagesStream,
    RetryConsumer,
    TMessengerSubjects.AcceptedMessagePartition(APartition),
    dpNew);
  try
    PublishPoison(AJetStream, ARunId, APartition);
    SourceMessages := AJetStream.Fetch(
      TMessengerJetStreamTopology.AcceptedMessagesStream,
      RetryConsumer, 1, 5000);
    Check(SourceMessages.Count = 1,
      'delivery consumer fetched poison event for DLQ outage test');
    OriginalSequence := SourceMessages[0].StreamSequence;

    Clock := TIntegrationClock.Create(CurrentUnixMs);
    DeadLetterSink := TRaisingDeadLetterSink.Create;
    Processor := TMessengerJetStreamDeliveryProcessor.Create(
      AJetStream, ATransport, DeadLetterSink, Clock, 200);
    try
      Processor.Process(SourceMessages[0]);
      AClient.Flush(2000);
    finally
      Processor.Free;
      DeadLetterSink := nil;
      Clock := nil;
    end;

    { NAK controls are asynchronous; wait beyond the requested retry delay. }
    TThread.Sleep(400);
    Redelivered := AJetStream.Fetch(
      TMessengerJetStreamTopology.AcceptedMessagesStream,
      RetryConsumer, 1, 3000);
    Check(Redelivered.Count = 1,
      'DLQ outage NAKed the poison event for redelivery');
    Check(Redelivered[0].StreamSequence = OriginalSequence,
      'DLQ outage redelivered the original source event');
    AJetStream.Term(Redelivered[0]);
  finally
    AJetStream.DeleteConsumer(
      TMessengerJetStreamTopology.AcceptedMessagesStream, RetryConsumer);
  end;
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

    TestJetStreamReplay(
      JetStream, ARunId, Partition, Accepted.Message.MessageId);
    TestDeadLetterPaths(JetStream, Client, Transport, ARunId, Partition + 1);

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
      Check(WaitForStreamInfo(
        JetStream,
        TMessengerJetStreamTopology.AcceptedMessagesStream,
        30000,
        AfterInfo),
        'JetStream API recovered after the stream leader election');
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
  RunId, ConnectionString, OutageConnectionString, NatsHost: string;
  NatsPort: Integer;
  KillPid: Cardinal;
begin
  Passed := 0;
  try
    RunId := RequiredEnv('MESSENGER_TEST_RUN_ID');
    ConnectionString := RequiredEnv('MESSENGER_TEST_PG');
    OutageConnectionString := RequiredEnv('MESSENGER_TEST_PG_OUTAGE');
    NatsHost := RequiredEnv('MESSENGER_TEST_NATS_HOST');
    NatsPort := StrToInt(RequiredEnv('MESSENGER_TEST_NATS_PORT'));
    KillPid := StrToIntDef(GetEnvironmentVariable('MESSENGER_TEST_NATS_KILL_PID'), 0);

    TestPostgreSQL(RunId, ConnectionString);
    TestPostgreSQLOutage(OutageConnectionString);
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
