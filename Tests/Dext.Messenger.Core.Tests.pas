unit Dext.Messenger.Core.Tests;

interface

uses
  System.SysUtils,
  Dext.Testing,
  Dext.Testing.Attributes,
  Dext.Testing.Fluent,
  Dext.Messenger.Models,
  Dext.Messenger.Subjects,
  Dext.Messenger.Codec.Json;

type
  [TestFixture('Dext Messenger Core')]
  TMessengerCoreTests = class
  public
    [Test, Category('Unit'), Category('Protocol')]
    procedure Subjects_ShouldBuildVersionedUserSubject;

    [Test, Category('Unit'), Category('Security')]
    procedure Subjects_ShouldRejectWildcardInjection;

    [Test, Category('Unit'), Category('Protocol')]
    procedure JsonCodec_ShouldRoundTripTextMessage;
  end;

implementation

procedure TMessengerCoreTests.Subjects_ShouldBuildVersionedUserSubject;
begin
  Should(TMessengerSubjects.UserMessage('user-42')).Be('msg.v1.user.user-42');
end;

procedure TMessengerCoreTests.Subjects_ShouldRejectWildcardInjection;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    TMessengerSubjects.UserMessage('user.*');
  except
    on EMessengerSubjectError do
      Raised := True;
  end;
  Should(Raised).BeTrue;
end;

procedure TMessengerCoreTests.JsonCodec_ShouldRoundTripTextMessage;
var
  Input: TMessengerMessage;
  Output: TMessengerMessage;
  Data: TBytes;
begin
  Input := TMessengerMessage.CreateV1(
    'msg-100',
    'client-100',
    'conv-10',
    'user-1',
    mmkText,
    1786590000000,
    '{"text":"hello","n":1}'
  );

  Data := TMessengerJsonCodec.EncodeMessage(Input);
  Output := TMessengerJsonCodec.DecodeMessage(Data);

  Should(Output.Version).Be(1);
  Should(Output.MessageId).Be(Input.MessageId);
  Should(Output.ClientMessageId).Be(Input.ClientMessageId);
  Should(Output.ConversationId).Be(Input.ConversationId);
  Should(Output.SenderUserId).Be(Input.SenderUserId);
  Should(Ord(Output.Kind)).Be(Ord(mmkText));
  Should(Output.CreatedAtUnixMs).Be(Input.CreatedAtUnixMs);
  Should(Output.PayloadJson).Be('{"text":"hello","n":1}');
end;

end.
