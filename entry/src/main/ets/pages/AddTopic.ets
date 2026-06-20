import { globalStorageManager, globalSubscriptionManager, globalWebSocketService } from '../entryability/EntryAbility';
import { TopicSubscription, NtfyMessage } from '../model/TopicModel';
import { NtfyService } from '../model/NtfyService';
import { Constants } from '../common/Constants';
import { router } from '@kit.ArkUI';

interface ParsedUrl {
  server: string;
  topic: string;
}

@Entry
@Component
struct AddTopic {
  @State urlInput: string = '';
  @State displayNameInput: string = '';
  @State isLoading: boolean = false;
  @State errorMessage: string = '';
  @State showAdvanced: boolean = false;
  @State serverInput: string = '';
  @State topicInput: string = '';
  @State defaultServer: string = Constants.DEFAULT_SERVER;

  aboutToAppear(): void {
    this.loadDefaultServer();
  }

  private async loadDefaultServer(): Promise<void> {
    this.defaultServer = await globalStorageManager?.loadSetting('default_server', Constants.DEFAULT_SERVER)
      ?? Constants.DEFAULT_SERVER;
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

        Text($r('app.string.add_topic'))
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
          // URL input (simple mode)
          Text($r('app.string.topic_url'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 24, bottom: 8, left: 16, right: 16 });

          TextInput({ placeholder: `${this.defaultServer}/mytopic`, text: this.urlInput })
            .width('100%')
            .height(48)
            .backgroundColor($r('app.color.input_background'))
            .borderRadius(12)
            .padding({ left: 16, right: 16 })
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.urlInput = value;
              this.errorMessage = '';
            });

          // Toggle advanced mode
          Text(this.showAdvanced ? '使用简单模式' : '使用高级模式（手动输入服务器和主题）')
            .fontSize(12)
            .fontColor($r('app.color.accent_color'))
            .margin({ top: 8, left: 16, right: 16 })
            .onClick(() => {
              this.showAdvanced = !this.showAdvanced;
            });

          // Advanced server/topic inputs
          if (this.showAdvanced) {
            Text('服务器地址')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ top: 16, bottom: 8, left: 16, right: 16 });

            TextInput({ placeholder: this.defaultServer, text: this.serverInput })
              .width('100%')
              .height(48)
              .backgroundColor($r('app.color.input_background'))
              .borderRadius(12)
              .padding({ left: 16, right: 16 })
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.serverInput = value;
                this.errorMessage = '';
              });

            Text('主题名称')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .width('100%')
              .margin({ top: 16, bottom: 8, left: 16, right: 16 });

            TextInput({ placeholder: 'mytopic', text: this.topicInput })
              .width('100%')
              .height(48)
              .backgroundColor($r('app.color.input_background'))
              .borderRadius(12)
              .padding({ left: 16, right: 16 })
              .placeholderColor($r('app.color.text_tertiary'))
              .onChange((value: string) => {
                this.topicInput = value;
                this.errorMessage = '';
              });
          }

          // Display name
          Text($r('app.string.display_name_optional'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .width('100%')
            .margin({ top: 16, bottom: 8, left: 16, right: 16 });

          TextInput({ placeholder: $r('app.string.my_topic_hint'), text: this.displayNameInput })
            .width('100%')
            .height(48)
            .backgroundColor($r('app.color.input_background'))
            .borderRadius(12)
            .padding({ left: 16, right: 16 })
            .placeholderColor($r('app.color.text_tertiary'))
            .onChange((value: string) => {
              this.displayNameInput = value;
            });

          // Parse URL info
          if (!this.showAdvanced && this.urlInput.length > 0) {
            Text(this.parsePreviewText())
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 8, left: 16, right: 16 });
          }

          if (this.showAdvanced && this.topicInput.length > 0) {
            Text(`服务器：${this.getPreviewServer()}  主题：${this.topicInput}`)
              .fontSize(12)
              .fontColor($r('app.color.text_hint'))
              .width('100%')
              .margin({ top: 8, left: 16, right: 16 });
          }

          // Error message
          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(13)
              .fontColor($r('app.color.error_color'))
              .width('100%')
              .margin({ top: 8, left: 16, right: 16 });
          }

          // Subscribe button
          Button() {
            if (this.isLoading) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(Color.White);
            } else {
              Text($r('app.string.subscribe'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White);
            }
          }
          .width('100%')
          .height(50)
          .backgroundColor($r('app.color.accent_color'))
          .borderRadius(25)
          .margin({ top: 32, left: 16, right: 16 })
          .enabled(!this.isLoading && this.isInputValid())
          .onClick(() => this.doSubscribe());
        }
        .width('100%')
        .padding({ bottom: 40 });
      }
      .layoutWeight(1);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.background'));
  }

  isInputValid(): boolean {
    if (this.showAdvanced) {
      return this.topicInput.trim().length > 0;
    }
    return this.urlInput.trim().length > 0;
  }

  parsePreviewText(): string {
    const parsed = this.parseUrl(this.urlInput);
    if (parsed) {
      return `服务器：${parsed.server}  主题：${parsed.topic}`;
    }
    const topic = this.urlInput.trim();
    if (topic.length > 0) {
      return `服务器：${this.defaultServer}  主题：${topic}`;
    }
    return '';
  }

  getPreviewServer(): string {
    return this.serverInput.trim() || this.defaultServer;
  }

  parseUrl(input: string): ParsedUrl | null {
    let urlStr = input.trim();
    urlStr = urlStr.replace(/\/+$/, '');
    if (!urlStr.startsWith('http://') && !urlStr.startsWith('https://')) {
      const isIP = /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/.test(urlStr);
      urlStr = (isIP ? 'http://' : 'https://') + urlStr;
    }
    try {
      const match = urlStr.match(/^(https?):\/\/([^\/:]+)(?::(\d+))?(\/.*)?$/);
      if (!match) {
        return null;
      }
      const scheme = match[1];
      const host = match[2];
      const port = match[3];
      const fullPath = match[4] ?? '';
      let server = `${scheme}://${host}`;
      if (port) {
        server += `:${port}`;
      }
      const topic = fullPath.replace(/^\//, '').split('/')[0];
      if (!topic) {
        return null;
      }
      return { server, topic } as ParsedUrl;
    } catch (e) {
      return null;
    }
  }

  async doSubscribe(): Promise<void> {
    let server: string = this.defaultServer;
    let topic: string;

    if (this.showAdvanced) {
      topic = this.topicInput.trim();
      if (!topic) {
        this.errorMessage = '请输入主题名称';
        return;
      }
      const rawServer = this.serverInput.trim();
      if (rawServer.length > 0) {
        server = rawServer.replace(/\/+$/, '');
        if (!server.startsWith('http://') && !server.startsWith('https://')) {
          server = 'https://' + server;
        }
      }
    } else {
      const parsed = this.parseUrl(this.urlInput);
      if (parsed) {
        server = parsed.server;
        topic = parsed.topic;
      } else {
        topic = this.urlInput.trim();
        if (!topic) {
          this.errorMessage = '请输入主题名称';
          return;
        }
      }
    }

    this.isLoading = true;
    this.errorMessage = '';

    try {
      const service = new NtfyService(server);
      let result: NtfyMessage[] = [];
      try {
        result = await service.fetchMessages(topic);
      } catch (e) {
        service.destroy();
        this.errorMessage = '连接失败，请检查地址后重试';
        this.isLoading = false;
        return;
      }
      service.destroy();

      const sub: TopicSubscription = {
        id: `${server}_${topic}`,
        server: server,
        topic: topic,
        displayName: this.displayNameInput || topic,
        subscribedAt: Math.floor(Date.now() / 1000),
        lastMessage: result.length > 0 ? result[result.length - 1] : undefined
      };

      globalSubscriptionManager?.addSubscription(sub);
      await globalStorageManager?.saveSubscriptions(
        globalSubscriptionManager?.toJSON() ?? '[]'
      );

      globalWebSocketService?.connect(server, topic);

      router.back();
    } catch (e) {
      this.errorMessage = '连接失败，请检查地址后重试';
      this.isLoading = false;
    }
  }
}
