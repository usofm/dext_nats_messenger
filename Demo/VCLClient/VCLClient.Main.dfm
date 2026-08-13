object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'Dext NATS Messenger - VCL Client'
  ClientHeight = 620
  ClientWidth = 980
  Position = poScreenCenter
  OnDestroy = FormDestroy
  object pnlTop: TPanel
    Align = alTop
    Height = 88
    TabOrder = 0
    object lblHost: TLabel
      Left = 16
      Top = 12
      Caption = 'NATS Host'
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
    object btnConnect: TButton
      Left = 504
      Top = 28
      Width = 100
      Height = 27
      Caption = 'Connect'
      TabOrder = 3
      OnClick = btnConnectClick
    end
    object btnDisconnect: TButton
      Left = 616
      Top = 28
      Width = 100
      Height = 27
      Caption = 'Disconnect'
      Enabled = False
      TabOrder = 4
      OnClick = btnDisconnectClick
    end
    object lblStatus: TLabel
      Left = 16
      Top = 64
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
      Width = 620
      TabOrder = 1
    end
    object btnSend: TButton
      Left = 852
      Top = 28
      Width = 100
      Height = 27
      Caption = 'Send'
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
end
