unit Dext.Messenger.Media;

interface

uses
  System.SysUtils,
  System.Classes;

type
  TMessengerMediaState = (mmsPendingUpload, mmsReady, mmsQuarantined, mmsDeleted);

  TMessengerMediaRef = record
  public
    MediaId: string;
    OwnerUserId: string;
    ObjectKey: string;
    ContentType: string;
    FileName: string;
    SizeBytes: Int64;
    Sha256Hex: string;
    Width: Integer;
    Height: Integer;
    DurationMs: Int64;
    State: TMessengerMediaState;
  end;

  TMessengerUploadGrant = record
  public
    MediaId: string;
    UploadUrl: string;
    ExpiresAtUnixMs: Int64;
    RequiredContentType: string;
    MaxBytes: Int64;
  end;

  IMessengerMediaStore = interface
    ['{0D27F188-4B13-4627-89F1-A0A1CE6E3881}']
    function CreateUploadGrant(const AUserId, AFileName, AContentType: string;
      ADeclaredSizeBytes: Int64): TMessengerUploadGrant;
    function CommitUpload(const AUserId, AMediaId, ASha256Hex: string;
      AActualSizeBytes: Int64): TMessengerMediaRef;
    function Resolve(const AUserId, AMediaId: string): TMessengerMediaRef;
    procedure Delete(const AUserId, AMediaId: string);
  end;

  TMessengerMediaPolicy = record
  public const
    DefaultMaxImageBytes = Int64(25) * 1024 * 1024;
    DefaultMaxAudioBytes = Int64(100) * 1024 * 1024;
    DefaultMaxVideoBytes = Int64(1024) * 1024 * 1024;
    DefaultMaxFileBytes = Int64(512) * 1024 * 1024;
  public
    class procedure ValidateDeclaredUpload(const AFileName, AContentType: string;
      ASizeBytes, AMaxBytes: Int64); static;
    class procedure ValidateReadyReference(const AMedia: TMessengerMediaRef); static;
  end;

implementation

class procedure TMessengerMediaPolicy.ValidateDeclaredUpload(const AFileName,
  AContentType: string; ASizeBytes, AMaxBytes: Int64);
begin
  if Trim(AFileName) = '' then raise EArgumentException.Create('file_name is required');
  if Trim(AContentType) = '' then raise EArgumentException.Create('content_type is required');
  if ASizeBytes <= 0 then raise EArgumentOutOfRangeException.Create('ASizeBytes');
  if AMaxBytes <= 0 then raise EArgumentOutOfRangeException.Create('AMaxBytes');
  if ASizeBytes > AMaxBytes then
    raise EArgumentOutOfRangeException.CreateFmt(
      'Declared upload exceeds maximum size (%d > %d)', [ASizeBytes, AMaxBytes]);
  { Storage adapters must independently verify actual bytes, MIME policy,
    authorization, object key ownership and malware/content scanning policy. }
end;

class procedure TMessengerMediaPolicy.ValidateReadyReference(
  const AMedia: TMessengerMediaRef);
begin
  if AMedia.MediaId = '' then raise EArgumentException.Create('media_id is required');
  if AMedia.OwnerUserId = '' then raise EArgumentException.Create('owner_user_id is required');
  if AMedia.ObjectKey = '' then raise EArgumentException.Create('object_key is required');
  if AMedia.ContentType = '' then raise EArgumentException.Create('content_type is required');
  if AMedia.SizeBytes <= 0 then raise EArgumentOutOfRangeException.Create('SizeBytes');
  if AMedia.Sha256Hex = '' then raise EArgumentException.Create('sha256 is required');
  if AMedia.State <> mmsReady then
    raise EInvalidOperation.Create('Media reference is not ready for messaging');
end;

end.
