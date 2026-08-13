object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'Dext NATS Messenger - VCL Client'
  ClientHeight = 720
  ClientWidth = 1080
  Position = poScreenCenter
  OnDestroy = FormDestroy
  object pnlTop: TPanel
    Align = alTop
    Height = 168
    TabOrder = 0
    object lblHost: TLabel
      Left = 16
      Top = 12
      Caption = 'NATS Host (Developer)'
    end
    object edtHost: TEdit
      Left = 16
      Top = 30
      Width = 180
      Text = '127.0.0.1'
      TabOrder = 0
    end
    object lblPort: TLabel
      Left = 208
      Top = 12
      Caption = 'Port'
    end
    object edtPort: TEdit
      Left = 208
      Top = 30
      Width = 72
      Text = '4222'
      TabOrder = 1
    end
    object lblUser: TLabel
      Left = 296
      Top = 12
      Caption = 'User ID'
    end
    object edtUserId: TEdit
      Left = 296
      Top = 30
      Width = 190
      Text = 'user-a'
      TabOrder = 2
    end
    object chkProduction: TCheckBox
      Left = 504
      Top = 31
      Width = 170
      Height = 17
      Caption = 'Production Gateway mode'
      Checked = True
      State = cbChecked
      TabOrder = 3
      OnClick = chkProductionClick
    end
    object btnConnect: TButton
      Left = 696
      Top = 26
      Width = 100
      Height = 27
      Caption = 'Connect'
      TabOrder = 4
      OnClick = btnConnectClick
    end
    object btnDisconnect: TButton
      Left = 808
      Top = 26
      Width = 100
      Height = 27
      Caption = 'Disconnect'
      Enabled = False
      TabOrder = 5
      OnClick = btnDisconnectClick
    end
    object lblApiUrl: TLabel
      Left = 16
      Top = 64
      Caption = 'Gateway API URL'
    end
    object edtApiUrl: TEdit
      Left = 16
      Top = 82
      Width = 280
      Text = 'http://127.0.0.1:8080'
      TabOrder = 6
    end
    object lblJwt: TLabel
      Left = 312
      Top = 64
      Caption = 'JWT Access Token'
    end
    object edtJwt: TEdit
      Left = 312
      Top = 82
      Width = 596
      PasswordChar = '*'
      TabOrder = 7
    end
    object lblConversation: TLabel
      Left = 16
      Top = 116
      Caption = 'Conversation ID'
    end
    object edtConversationId: TEdit
      Left = 16
      Top = 134
      Width = 280
      Text = 'conv-demo-1'
      TabOrder = 8
    end
    object lblStatus: TLabel
      Left = 312
      Top = 138
      Caption = 'Disconnected'
    end
  end
  object pnlSend: TPanel
    Align = alBottom
    Height = 92
    TabOrder = 1
    object lblTarget: TLabel
      Left = 16
      Top = 10
      Caption = 'Target User ID'
    end
    object edtTargetUserId: TEdit
      Left = 16
      Top = 30
      Width = 190
      Text = 'user-b'
      TabOrder = 0
    end
    object edtMessage: TEdit
      Left = 220
      Top = 30
      Width = 700
      TabOrder = 1
    end
    object btnSend: TButton
      Left = 936
      Top = 28
      Width = 120
      Height = 27
      Caption = 'Send Message'
      Enabled = False
      TabOrder = 2
      OnClick = btnSendClick
    end
  end
  object memChat: TMemo
    Align = alClient
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 2
  end
  object tmrSync: TTimer
    Enabled = False
    Interval = 1000
    OnTimer = tmrSyncTimer
    Left = 1000
    Top = 112
  end
end
