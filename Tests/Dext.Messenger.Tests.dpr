program Dext.Messenger.Tests;

{$APPTYPE CONSOLE}
{$RTTI EXPLICIT METHODS([vcPublic, vcPublished, vcProtected])}

uses
  Dext.MM,
  System.SysUtils,
  Dext.Testing.Runner,
  Dext.Messenger.Core.Tests in 'Dext.Messenger.Core.Tests.pas',
  Dext.Messenger.Contracts.Tests in 'Dext.Messenger.Contracts.Tests.pas',
  Dext.Messenger.Acceptance.Tests in 'Dext.Messenger.Acceptance.Tests.pas',
  Dext.Messenger.Runtime.Tests in 'Dext.Messenger.Runtime.Tests.pas',
  Dext.Messenger.Conversation.Tests in 'Dext.Messenger.Conversation.Tests.pas';

var
  Summary: TTestSummary;
begin
  try
    TTestRunner.SetVerbosity(ovVerbose);
    TTestRunner.Discover;
    TTestRunner.RunAll;
    Summary := TTestRunner.Summary;
    if (Summary.Failed > 0) or (Summary.Errors > 0) then
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
