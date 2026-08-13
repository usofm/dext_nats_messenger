unit Dext.Messenger.Partitioning;

interface

uses
  System.SysUtils;

type
  EMessengerPartitionError = class(Exception);

  TMessengerPartitioner = record
  public
    class function StableHash32(const AValue: string): UInt32; static;
    class function PartitionFor(const AConversationId: string; APartitionCount: Integer): Integer; static;
  end;

implementation

class function TMessengerPartitioner.StableHash32(const AValue: string): UInt32;
const
  FNV_OFFSET_BASIS: UInt32 = $811C9DC5;
  FNV_PRIME: UInt32 = 16777619;
var
  Bytes: TBytes;
  I: Integer;
  H: UInt32;
begin
  Bytes := TEncoding.UTF8.GetBytes(AValue);
  H := FNV_OFFSET_BASIS;
  for I := 0 to High(Bytes) do
  begin
    H := H xor Bytes[I];
    H := H * FNV_PRIME;
  end;
  Result := H;
end;

class function TMessengerPartitioner.PartitionFor(
  const AConversationId: string;
  APartitionCount: Integer
): Integer;
begin
  if AConversationId = '' then
    raise EMessengerPartitionError.Create('conversation_id must not be empty');
  if APartitionCount <= 0 then
    raise EMessengerPartitionError.Create('partition_count must be greater than zero');

  Result := Integer(StableHash32(AConversationId) mod UInt32(APartitionCount));
end;

end.
