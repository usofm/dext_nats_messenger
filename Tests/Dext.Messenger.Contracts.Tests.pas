unit Dext.Messenger.Contracts.Tests;

interface

uses
  System.SysUtils,
  System.Classes,
  Dext.Testing,
  Dext.Testing.Attributes,
  Dext.Testing.Fluent,
  Dext.Messenger.Commands,
  Dext.Messenger.Models,
  Dext.Messenger.Delivery,
  Dext.Messenger.Gateway.Backpressure,
  Dext.Messenger.Media;

type
  [TestFixture('Dext Messenger Contracts')]
  TMessengerContractTests = class
  public
    [Test, Category('Unit'), Category('Domain')]
    procedure AcceptedMessage_ShouldPreserveTypedDestinationAndSequence;
    [Test, Category('Unit'), Category('Protocol')]
    procedure DeliveryEnvelope_ShouldRoundTripCanonicalMessage;
    [Test, Category('Unit'), Category('Backpressure')]
    procedure Backpressure_ShouldRejectBeforeHardLimitAndDisconnectBeyondLimit;
    [Test, Category('Unit'), Category('Media')]
    procedure MediaPolicy_ShouldRejectUncommittedReference;
  end;

implementation

procedure TMessengerContractTests.AcceptedMessage_ShouldPreserveTypedDestinationAndSequence;
var
  M: TMessengerMessage;
  A: TMessengerAcceptedMessage;
begin
  M := TMessengerMessage.CreateV1('m-1', 'c-1', 'conv-1', 'u-1', mmkText,
    1786590000000, '{"text":"hello"}');
  A := TMessengerAcceptedMessage.Create(M, mdkGroup, 'group-9', 7, 42);

  Should(A.IsGroup).BeTrue;
  Should(A.IsDirect).BeFalse;
  Should(A.DestinationId).Be('group-9');
  Should(A.Partition).Be(7);
  Should(A.Sequence).Be(Int64(42));
  Should(A.IsCanonical).BeTrue;
end;

procedure TMessengerContractTests.DeliveryEnvelope_ShouldRoundTripCanonicalMessage;
var
  M: TMessengerMessage;
  Input, Output: TMessengerAcceptedMessage;
  Data: TBytes;
begin
  M := TMessengerMessage.CreateV1('m-2', 'c-2', 'conv-2', 'u-2', mmkText,
    1786590000100, '{"text":"world","nested":{"n":2}}');
  Input := TMessengerAcceptedMessage.Create(M, mdkUser, 'u-3', 3, 99);
  Data := TMessengerDeliveryCodec.Encode(Input);
  Output := TMessengerDeliveryCodec.Decode(Data);

  Should(Output.Message.MessageId).Be('m-2');
  Should(Output.DestinationId).Be('u-3');
  Should(Ord(Output.DestinationKind)).Be(Ord(mdkUser));
  Should(Output.Sequence).Be(Int64(99));
  Should(Output.Partition).Be(3);
end;

procedure TMessengerContractTests.Backpressure_ShouldRejectBeforeHardLimitAndDisconnectBeyondLimit;
var
  Limits: TMessengerOutboundQueueLimits;
  Guard: TMessengerOutboundQueueGuard;
begin
  Limits.MaxMessages := 10;
  Limits.MaxBytes := 1000;
  Limits.DisconnectAtPercent := 80;
  Guard := TMessengerOutboundQueueGuard.Create(Limits);
  try
    Should(Ord(Guard.Reserve(100))).Be(Ord(mbdAccept));
    Should(Ord(Guard.Reserve(700))).Be(Ord(mbdRejectTransient));
    Should(Ord(Guard.Reserve(1000))).Be(Ord(mbdDisconnectSlowConsumer));
    Should(Guard.MessageCount).Be(1);
    Should(Guard.ByteCount).Be(Int64(100));
  finally
    Guard.Free;
  end;
end;

procedure TMessengerContractTests.MediaPolicy_ShouldRejectUncommittedReference;
var
  Media: TMessengerMediaRef;
  Raised: Boolean;
begin
  Media := Default(TMessengerMediaRef);
  Media.MediaId := 'media-1';
  Media.OwnerUserId := 'u-1';
  Media.ObjectKey := 'users/u-1/media-1';
  Media.ContentType := 'image/jpeg';
  Media.SizeBytes := 100;
  Media.Sha256Hex := 'abcdef';
  Media.State := mmsPendingUpload;

  Raised := False;
  try
    TMessengerMediaPolicy.ValidateReadyReference(Media);
  except
    on EInvalidOperation do Raised := True;
  end;
  Should(Raised).BeTrue;
end;

end.
