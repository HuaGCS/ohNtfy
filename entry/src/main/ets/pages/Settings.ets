import { globalStorageManager, globalWebSocketService } from '../entryability/EntryAbility';
import { Constants } from '../common/Constants';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';

@Entry
@Component
struct Settings {
  @State defaultServer: string = Constants.DEFAULT_SERVER;
  @State pollingInterval: string = String(Constants.POLL_INTERVAL_MS / 1000);
  @State notificationsEnabled: boolean = true;
  @State wsConnectedCount: number = 0;
  @State wsStatusText: string = '';
  @State useWebSocket: boolean = true;

  aboutToAppear(): void {
    this.loadSettings();
  }

  onPageShow(): void {
    this.wsConnectedCount = globalWebSocketService?.getConnectedCount() ?? 0;
    this.updateWsStatusText();
  }

  updateWsStatusText(): void {
    if (this.wsConnectedCount > 0) {
      this.wsStatusText = `${this.wsConnectedCount} 已连接`;
    } else {
      this.wsStatusText = '未连接';
    }
  }

  async loadSettings(): Promise<void> {
    const server = await globalStorageManager?.loadSetting('default_server', Constants.DEFAULT_SERVER)
      ?? Constants.DEFAULT_SERVER;
    this.defaultServer = server;

    const interval = await globalStorageManager?.loadSetting('polling_interval',
      String(Constants.POLL_INTERVAL_MS / 1000))
      ?? String(Constants.POLL_INTERVAL_MS / 1000);
    this.pollingInterval = interval;

    const notifEnabled = await globalStorageManager?.loadSetting('notifications_enabled', 'true') ?? 'true';
    this.notificationsEnabled = notifEnabled === 'true';

    const useWs = await globalStorageManager?.loadSetting('use_websocket', 'true') ?? 'true';
    this.useWebSocket = useWs === 'true';
  }

  async saveDefaultServer(): Promise<void> {
    await globalStorageManager?.saveSetting('default_server', this.defaultServer);
    this.showToast($r('app.string.server_saved'));
  }

  async savePollingInterval(): Promise<void> {
    await globalStorageManager?.saveSetting('polling_interval', this.pollingInterval);
    this.showToast($r('app.string.interval_saved'));
  }

  async saveNotificationsEnabled(): Promise<void> {
    await globalStorageManager?.saveSetting('notifications_enabled', String(this.notificationsEnabled));
    this.showToast(this.notificationsEnabled
      ? $r('app.string.notifications_enabled_toast')
      : $r('app.string.notifications_disabled_toast'));
  }

  async saveUseWebSocket(): Promise<void> {
    await globalStorageManager?.saveSetting('use_websocket', String(this.useWebSocket));
    AppStorage.setOrCreate<boolean>('settingsChanged', true);
    this.showToast($r('app.string.protocol_saved'));
  }

  showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  openNotificationSettings(): void {
    try {
      let context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.startAbility({
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'systemui_notification_settings',
        parameters: {
          pushParams: context.abilityInfo.bundleName
        }
      });
    } catch (e) {
      console.error('Failed to open notification settings:', JSON.stringify(e));
    }
  }

  build() {
    Column() {
      // Header
      Row() {
        Button({ type: ButtonType.Normal }) {
          Image($r('app.media.ic_back'))
            .width(20)
            .height(20);
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .margin({ left: 4 })
        .onClick(() => router.back());

        Text($r('app.string.settings'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 8 });

        Blank();
      }
      .width('100%')
      .height(56)
      .padding({ right: 16 });

      Scroll() {
        Column() {
          // ── Connection Status ──
          SectionHeader({ title: $r('app.string.connection_status') });

          Row() {
            Column()
              .width(8)
              .height(8)
              .borderRadius(4)
              .backgroundColor(this.wsConnectedCount > 0 ? '#FF4CAF50' : '#FF9E9E9E')
              .margin({ right: 6 });
            Text(this.wsStatusText)
              .fontSize(14)
              .fontColor(this.wsConnectedCount > 0 ? '#FF4CAF50' : '#FF999999');
          }
          .width('100%')
          .padding({ left: 16, right: 16 });

          // ── Default Server ──
          SectionHeader({ title: $r('app.string.default_server') });

          TextInput({ placeholder: 'https://ntfy.sh', text: this.defaultServer })
            .width('100%')
            .height(44)
            .backgroundColor('#FFF5F5F5')
            .borderRadius(8)
            .padding({ left: 12, right: 12 })
            .margin({ left: 16, right: 16 })
            .onChange((v: string) => {
              this.defaultServer = v;
            });

          Button($r('app.string.save_server'))
            .width('100%')
            .height(40)
            .backgroundColor('#FF0078D4')
            .borderRadius(20)
            .fontColor(Color.White)
            .fontSize(14)
            .margin({ top: 8, left: 16, right: 16 })
            .onClick(() => this.saveDefaultServer());

          // ── Polling ──
          SectionHeader({ title: $r('app.string.polling') });

          Row() {
            Text($r('app.string.polling_interval'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            TextInput({ placeholder: '30', text: this.pollingInterval })
              .width(80)
              .height(36)
              .backgroundColor('#FFF5F5F5')
              .borderRadius(8)
              .textAlign(TextAlign.Center)
              .onChange((v: string) => {
                this.pollingInterval = v;
              });
          }
          .width('100%')
          .padding({ left: 16, right: 16 });

          Button($r('app.string.save_interval'))
            .width('100%')
            .height(40)
            .backgroundColor('#FF0078D4')
            .borderRadius(20)
            .fontColor(Color.White)
            .fontSize(14)
            .margin({ top: 8, left: 16, right: 16 })
            .onClick(() => this.savePollingInterval());

          // ── Connection Protocol ──
          SectionHeader({ title: $r('app.string.connection_protocol') });

          Row() {
            Column() {
              Text(this.useWebSocket ? $r('app.string.protocol_ws') : $r('app.string.protocol_json'))
                .fontSize(14)
                .fontColor('#FF333333');
              Text(this.useWebSocket ? $r('app.string.protocol_ws_desc') : $r('app.string.protocol_json_desc'))
                .fontSize(11)
                .fontColor('#FF999999')
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start);

            Blank();

            Toggle({ type: ToggleType.Switch, isOn: this.useWebSocket })
              .onChange((isOn: boolean) => {
                this.useWebSocket = isOn;
                this.saveUseWebSocket();
              });
          }
          .width('100%')
          .padding({ left: 16, right: 16 });

          // ── Notifications ──
          SectionHeader({ title: $r('app.string.notifications') });

          Row() {
            Text($r('app.string.enable_notifications'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            Toggle({ type: ToggleType.Switch, isOn: this.notificationsEnabled })
              .onChange((isOn: boolean) => {
                this.notificationsEnabled = isOn;
                this.saveNotificationsEnabled();
              });
          }
          .width('100%')
          .padding({ left: 16, right: 16 });

          Row() {
            Text($r('app.string.notification_settings'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            Image($r('app.media.ic_chevron'))
              .width(16)
              .height(16);
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .margin({ top: 4 })
          .onClick(() => this.openNotificationSettings());

          Divider()
            .width('100%')
            .color('#FFF0F0F0')
            .margin({ top: 12, left: 16, right: 16 });

          // ── About ──
          SectionHeader({ title: $r('app.string.about') });

          Row() {
            Text($r('app.string.version'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            Text($r('app.string.version_name'))
              .fontSize(14)
              .fontColor('#FF999999');
          }
          .width('100%')
          .padding({ left: 16, right: 16 });

          Row() {
            Text($r('app.string.sdk'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            Text('HarmonyOS 6.1.0 (API 24)')
              .fontSize(14)
              .fontColor('#FF999999');
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 });

          Row() {
            Text($r('app.string.architecture'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            Text($r('app.string.architecture_value'))
              .fontSize(14)
              .fontColor('#FF999999');
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10 });

          Divider()
            .width('100%')
            .color('#FFF0F0F0')
            .margin({ top: 12, left: 16, right: 16 });

          Row() {
            Text($r('app.string.about_ntfy'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
            Image($r('app.media.ic_chevron'))
              .width(16)
              .height(16);
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/About' });
          });

          Row() {
            Text($r('app.string.source_code'))
              .fontSize(14)
              .fontColor('#FF333333');
            Blank();
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 });

          Column().height(60);
        }
        .width('100%');
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFFFF');
  }
}

@Component
struct SectionHeader {
  @Prop title: ResourceStr = '';

  build() {
    Text(this.title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor('#FF0078D4')
      .width('100%')
      .margin({ top: 24, left: 16, right: 16, bottom: 8 });
  }
}
