program VCLMessengerClient;

uses
  Vcl.Forms,
  VCLClient.Main in 'VCLClient.Main.pas' {MainForm};

{$IF FileExists('VCLMessengerClient.res')}
{$R 'VCLMessengerClient.res'}
{$IFEND}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'Dext NATS Messenger - VCL Client';
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
