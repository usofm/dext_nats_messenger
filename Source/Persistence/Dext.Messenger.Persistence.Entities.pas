unit Dext.Messenger.Persistence.Entities;

interface

uses
  System.SysUtils,
  Dext.Entity,
  Dext.Core.SmartTypes;

type
  [Table('messenger_conversations')]
  TMessengerConversationEntity = class
  private
    FId: StringType;
    FKind: IntegerType;
    FTitle: StringType;
    FCreatedBy: StringType;
    FCreatedAt: TDateTime;
    FLastSequence: Int64Type;
    FLastMessageAt: TDateTime;
  public
    [PK, MaxLength(64)]
    property Id: StringType read FId write FId;
    [Required]
    property Kind: IntegerType read FKind write FKind;
    [MaxLength(200)]
    property Title: StringType read FTitle write FTitle;
    [Required, MaxLength(128)]
    property CreatedBy: StringType read FCreatedBy write FCreatedBy;
    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;
    [Required]
    property LastSequence: Int64Type read FLastSequence write FLastSequence;
    property LastMessageAt: TDateTime read FLastMessageAt write FLastMessageAt;
  end;

  [Table('messenger_messages')]
  TMessengerMessageEntity = class
  private
    FMessageId: StringType;
    FClientMessageId: StringType;
    FConversationId: StringType;
    FSenderUserId: StringType;
    FDestinationKind: IntegerType;
    FDestinationId: StringType;
    FSequenceNo: Int64Type;
    FPartitionNo: IntegerType;
    FMessageKind: IntegerType;
    FPayloadJson: StringType;
    FCreatedAt: TDateTime;
    FPersistedAt: TDateTime;
  public
    [PK, MaxLength(64)]
    property MessageId: StringType read FMessageId write FMessageId;
    [Required, MaxLength(128)]
    property ClientMessageId: StringType read FClientMessageId write FClientMessageId;
    [Required, MaxLength(64)]
    property ConversationId: StringType read FConversationId write FConversationId;
    [Required, MaxLength(128)]
    property SenderUserId: StringType read FSenderUserId write FSenderUserId;
    [Required]
    property DestinationKind: IntegerType read FDestinationKind write FDestinationKind;
    [Required, MaxLength(128)]
    property DestinationId: StringType read FDestinationId write FDestinationId;
    [Required]
    property SequenceNo: Int64Type read FSequenceNo write FSequenceNo;
    [Required]
    property PartitionNo: IntegerType read FPartitionNo write FPartitionNo;
    [Required]
    property MessageKind: IntegerType read FMessageKind write FMessageKind;
    [Required]
    property PayloadJson: StringType read FPayloadJson write FPayloadJson;
    property CreatedAt: TDateTime read FCreatedAt write FCreatedAt;
    property PersistedAt: TDateTime read FPersistedAt write FPersistedAt;
  end;

  [Table('messenger_user_cursors')]
  TMessengerCursorEntity = class
  private
    FUserId: StringType;
    FConversationId: StringType;
    FDeliveredSequence: Int64Type;
    FReadSequence: Int64Type;
    FUpdatedAt: TDateTime;
  public
    [PK, MaxLength(128)]
    property UserId: StringType read FUserId write FUserId;
    [PK, MaxLength(64)]
    property ConversationId: StringType read FConversationId write FConversationId;
    [Required]
    property DeliveredSequence: Int64Type read FDeliveredSequence write FDeliveredSequence;
    [Required]
    property ReadSequence: Int64Type read FReadSequence write FReadSequence;
    property UpdatedAt: TDateTime read FUpdatedAt write FUpdatedAt;
  end;

  [Table('messenger_devices')]
  TMessengerDeviceEntity = class
  private
    FUserId: StringType;
    FDeviceId: StringType;
    FPlatform: StringType;
    FPushToken: StringType;
    FPushProvider: StringType;
    FLastSeenAt: TDateTime;
  public
    [PK, MaxLength(128)]
    property UserId: StringType read FUserId write FUserId;
    [PK, MaxLength(128)]
    property DeviceId: StringType read FDeviceId write FDeviceId;
    [MaxLength(32)]
    property Platform: StringType read FPlatform write FPlatform;
    property PushToken: StringType read FPushToken write FPushToken;
    [MaxLength(32)]
    property PushProvider: StringType read FPushProvider write FPushProvider;
    property LastSeenAt: TDateTime read FLastSeenAt write FLastSeenAt;
  end;

implementation

end.
