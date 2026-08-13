unit Dext.Messenger.Transport;

interface

uses
  System.SysUtils;

type
  TMessengerTransportHandler = reference to procedure(
    const ASubject: string;
    const APayload: TBytes
  );

  IMessengerSubscription = interface
    ['{79A5E786-3306-4E8B-9804-14C89D911591}']
    procedure Unsubscribe;
  end;

  IMessengerTransport = interface
    ['{51C8D5AE-8B6F-4387-B9A5-1D56A21EF234}']
    procedure Publish(const ASubject: string; const APayload: TBytes);
    function Subscribe(
      const ASubject: string;
      const AHandler: TMessengerTransportHandler;
      const AQueueGroup: string = ''
    ): IMessengerSubscription;
    function IsConnected: Boolean;
  end;

implementation

end.
