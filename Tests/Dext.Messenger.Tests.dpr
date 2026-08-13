program Dext.Messenger.Tests;

{$APPTYPE CONSOLE}

uses
  Dext.MM,
  System.SysUtils,
  Dext.Testing,
  Dext.Testing.Fluent,
  Dext.Messenger.Core.Tests in 'Dext.Messenger.Core.Tests.pas',
  Dext.Messenger.Contracts.Tests in 'Dext.Messenger.Contracts.Tests.pas',
  Dext.Messenger.Acceptance.Tests in 'Dext.Messenger.Acceptance.Tests.pas',
  Dext.Messenger.Runtime.Tests in 'Dext.Messenger.Runtime.Tests.pas',
  Dext.Messenger.Conversation.Tests in 'Dext.Messenger.Conversation.Tests.pas';

var
  Summary: TTestSummary;
begin
  try
    RunTests(ConfigureTests
      .Verbose
      .RegisterFixtures([
        TMessengerCoreTests,
        TMessengerContractTests,
        TMessengerAcceptanceTests,
        TMessengerRuntimeTests,
        TMessengerConversationTests
      ]));
    Summary := TTestRunner.Summary;
    if Summary.TotalTests = 0 then
    begin
      Writeln('ERROR: no tests were executed');
      ExitCode := 3;
    end
    else if (Summary.Failed > 0) or (Summary.Errors > 0) then
      ExitCode := 1
    else
      ExitCode := 0;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 2;
    end;
  end;
end.
