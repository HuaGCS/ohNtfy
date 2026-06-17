import { NtfyMessage } from '../model/TopicModel';
import { NtfyService } from '../model/NtfyService';
import { router } from '@kit.ArkUI';
import { globalMessageCacheService, globalSubscriptionManager, globalStorageManager, globalNotificationService } from '../entryability/EntryAbility';

@Entry
@Component
struct TopicDetail {
  @State messages: NtfyMessage[] = [];
  @State isLoading: boolean = false;
  @State isCacheLoading: boolean = true;
  @State errorMessage: string = '';
  @State showPublishDialog: boolean = false;
  @State publishTitleInput: string = '';
  @State publishMessageInput: string = '';
  @State isPublishing: boolean = false;

  private server: string = '';
  private topic: string = '';
  private displayName: string = '';
  private service: NtfyService = new NtfyService();
  private loadingMessages: boolean = false;
  private lastReadIndex: number = -1;
  /** 进入页面时拍摄的 lastReadId 快照：markRead 后会覆盖订阅中的值，绿点依赖此快照 */
  private lastReadIdSnapshot: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    this.server = params?.['server'] ?? '';
    this.topic = params?.['topic'] ?? '';
    this.displayName = params?.['displayName'] ?? this.topic;
    this.service = new NtfyService(this.server);

    // 拍摄进入时的未读基线快照（markRead 会覆盖订阅中的 lastReadId）
    const sub = globalSubscriptionManager?.getSubscription(this.server, this.topic);
    this.lastReadIdSnapshot = sub?.lastReadId ?? '';
    // 进入即标记已读 → Index 消除未读标识
    if (sub) {
      globalSubscriptionManager?.markRead(this.server, this.topic);
      // 清除系统通知栏中该 topic 的所有通知
      globalNotificationService?.cancelTopicNotifications(this.server, this.topic);
      globalStorageManager?.saveSubscriptions(
        globalSubscriptionManager?.toJSON() ?? '[]'
      );
    }

    this.loadFromCacheThenNetwork();
  }

  aboutToDisappear(): void {
    this.service?.destroy();
  }

  /** 更新已读分界索引：基于进入页面时的 lastReadId 快照，不受 markRead 影响 */
  private updateLastReadIndex(fallbackIndex?: number): void {
    const lastReadId = this.lastReadIdSnapshot;
    if (lastReadId) {
      const foundIndex = this.messages.findIndex(m => m.id === lastReadId);
      if (foundIndex >= 0) {
        this.lastReadIndex = foundIndex;
      } else if (fallbackIndex !== undefined && fallbackIndex >= 0) {
        // lastReadId 消息已被删除 → 使用之前的分界值（不超出当前列表）
        this.lastReadIndex = Math.min(fallbackIndex, this.messages.length);
      } else {
        // 首次加载且快照消息不在此列表中 → 全部视为未读
        this.lastReadIndex = this.messages.length;
      }
    } else {
      this.lastReadIndex = this.messages.length;
    }
  }

  /**
   * 先读取缓存即时显示，再拉取网络全量历史
   */
  async loadFromCacheThenNetwork(): Promise<void> {
    this.isCacheLoading = true;

    // 1. 先展示缓存（即时显示，无需网络）
    try {
      const cached = await globalMessageCacheService?.getMessages(this.server, this.topic);
      if (cached && cached.length > 0) {
        this.messages = cached; // 缓存已按 newest-first 排序
        // 立即更新未读分界线，避免缓存渲染时 lastReadIndex 仍是 -1
        this.updateLastReadIndex();
      }
    } catch (e) {
      // 缓存读取失败不影响网络请求
    }
    this.isCacheLoading = false;

    // 2. 再从网络拉取全量历史（since=all）
    await this.loadMessages();
  }

  async loadMessages(): Promise<void> {
    if (this.loadingMessages) return;
    this.loadingMessages = true;
    this.isLoading = true;
    this.errorMessage = '';

    try {
      // since=all 拉取全部缓存历史
      const messages = await this.service.fetchMessages(this.topic, 'all');
      // 服务端返回消息是 oldest-first，转为 newest-first
      let sorted = messages.reverse();
      // 过滤掉已删除的消息
      if (globalMessageCacheService) {
        const deletedIds = await globalMessageCacheService.getDeletedIds(this.server, this.topic);
        sorted = sorted.filter(m => !deletedIds.has(m.id));
      }
      this.messages = sorted;

      // 更新未读分界线
      this.updateLastReadIndex();

      // 同步到缓存
      if (sorted.length > 0 && globalMessageCacheService) {
        await globalMessageCacheService.addMessages(this.server, this.topic, sorted);
      }

      if (sorted.length === 0 && this.messages.length === 0) {
        this.errorMessage = '暂无消息';
      }
    } catch (e) {
      if (this.messages.length === 0) {
        this.errorMessage = '获取失败: ' + ((e as Error)?.message || String(e));
      } else {
        // 网络失败但有缓存数据 → 确保未读分界线已更新
        this.updateLastReadIndex();
      }
    } finally {
      this.isLoading = false;
      this.loadingMessages = false;
    }
  }

  async doPublish(): Promise<void> {
    const msg = this.publishMessageInput.trim();
    if (!msg && !this.publishTitleInput.trim()) return;

    this.isPublishing = true;
    try {
      await this.service.publish({
        topic: this.topic,
        title: this.publishTitleInput.trim() || undefined,
        message: msg || undefined
      });
      this.showPublishDialog = false;
      this.publishTitleInput = '';
      this.publishMessageInput = '';
      // 发布后刷新消息列表
      await this.loadMessages();
    } catch (e) {
      // 错误由 NtfyService.publish 内部处理
    } finally {
      this.isPublishing = false;
    }
  }

  private formatTime(seconds: number): string {
    if (!seconds) return '';
    const d = new Date(seconds * 1000);
    const pad = (n: number) => n.toString().padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ` +
      `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }

  private priorityColor(priority: number | undefined): string {
    if (!priority) return '#FF999999';
    switch (priority) {
      case 5: return '#FFE81123';
      case 4: return '#FFFF8C00';
      case 3: return '#FF0078D4';
      default: return '#FF999999';
    }
  }

  private priorityLabel(priority: number | undefined): string {
    if (!priority) return '•';
    switch (priority) {
      case 5: return '★★★★★';
      case 4: return '★★★★';
      case 3: return '★★★';
      default: return `P${priority}`;
    }
  }

  @Builder
  msgSwipeDeleteBuilder(msg: NtfyMessage) {
    Column() {
      Text('删除')
        .fontSize(13)
        .fontColor(Color.White);
    }
    .width(64)
    .height('100%')
    .backgroundColor('#FFE81123')
    .justifyContent(FlexAlign.Center)
    .borderRadius(8);
  }

  private doDeleteMsg(msg: NtfyMessage): void {
    // 保存删除前的分界值，若删除的正好是 lastReadIdSnapshot 消息时作为回退
    const prevLastReadIndex = this.lastReadIndex;
    this.messages = this.messages.filter(m => m.id !== msg.id);
    globalMessageCacheService?.removeMessage(this.server, this.topic, msg.id);
    // 同步更新 Index 页 lastMessage
    if (this.messages.length > 0) {
      globalSubscriptionManager?.updateLastMessage(this.server, this.topic, this.messages[0]);
    } else {
      globalSubscriptionManager?.clearLastMessage(this.server, this.topic);
    }
    this.updateLastReadIndex(prevLastReadIndex);
  }

  build() {
    Stack() {
    Column() {
      // Header
      Row() {
        Row() {
          Image($r('app.media.ic_back'))
            .width(20)
            .height(20)
            .fillColor('#FF333333');
          Text('返回')
            .fontSize(15)
            .fontColor('#FF333333')
            .margin({ left: 2 });
        }
        .padding({ left: 4, right: 8, top: 6, bottom: 6 })
        .borderRadius(20)
        .onClick(() => router.back());

        Blank();

        Column() {
          Text(this.displayName || this.topic)
            .fontSize(18)
            .fontWeight(FontWeight.Bold);
          Text(`${this.server}/${this.topic}`)
            .fontSize(11)
            .fontColor('#FF999999');
        }
        .alignItems(HorizontalAlign.Center);

        Blank();

        Image($r('app.media.ic_refresh'))
          .width(22)
          .height(22)
          .fillColor('#FF333333')
          .margin({ right: 16 })
          .onClick(() => this.loadMessages());

        Image($r('app.media.ic_send'))
          .width(22)
          .height(22)
          .fillColor('#FF333333')
          .onClick(() => {
            this.showPublishDialog = true;
          });
      }
      .width('100%')
      .height(56)
      .padding({ left: 12, right: 16 });

      Divider();

      // Content
      if (this.isCacheLoading && this.messages.length === 0) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#FF0078D4');
          Text('加载中...')
            .fontSize(14)
            .fontColor('#FF999999')
            .margin({ top: 12 });
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center);
      } else if (this.errorMessage && this.messages.length === 0) {
        Column() {
          Text(this.errorMessage)
            .fontSize(14)
            .fontColor('#FFE81123');
          Button('重试')
            .margin({ top: 12 })
            .onClick(() => this.loadMessages());
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center);
      } else if (this.messages.length === 0) {
        Column() {
          Text('暂无消息，点击上方刷新按钮加载')
            .fontSize(14)
            .fontColor('#FF999999');
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center);
      } else {
        Column() {
          // 网络加载中提示
          if (this.isLoading) {
            Row() {
              LoadingProgress()
                .width(16)
                .height(16)
                .color('#FF0078D4');
              Text(' 正在获取最新消息...')
                .fontSize(12)
                .fontColor('#FF999999');
            }
            .padding({ top: 8, bottom: 4 });
          }

          List() {
            ForEach(this.messages, (msg: NtfyMessage, index: number) => {
              ListItem() {
                Stack({ alignContent: Alignment.TopEnd }) {
                  Column() {
                    // Title row
                    Row() {
                      if (msg.title) {
                        Text(msg.title)
                          .fontSize(16)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#FF333333')
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1);
                      }

                      Text(this.priorityLabel(msg.priority))
                        .fontSize(12)
                        .fontColor(this.priorityColor(msg.priority))
                        .margin({ left: 8 });
                    }
                    .width('100%');

                    // Message body
                    if (msg.message) {
                      Text(msg.message)
                        .fontSize(14)
                        .fontColor('#FF666666')
                        .maxLines(5)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 4 })
                        .width('100%');
                    }

                    // Tags
                    if (msg.tags && msg.tags.length > 0) {
                      Row() {
                        ForEach(msg.tags, (tag: string) => {
                          Text(tag)
                            .fontSize(11)
                            .fontColor('#FF0078D4')
                            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                            .backgroundColor('#FFE6F0FA')
                            .borderRadius(4)
                            .margin({ right: 4 });
                        }, (tag: string) => tag);
                      }
                      .margin({ top: 6 })
                      .width('100%');
                    }

                    // Time
                    Text(this.formatTime(msg.time))
                      .fontSize(11)
                      .fontColor('#FFAAAAAA')
                      .margin({ top: 6 });
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start);

                  // 未读绿色圆点（lastReadId 之后的新消息）
                  if (this.lastReadIndex >= 0 && index < this.lastReadIndex) {
                    Column()
                      .width(10)
                      .height(10)
                      .borderRadius(5)
                      .backgroundColor('#FF4CAF50')
                      .margin({ top: 14, right: 10 });
                  }
                }
                .width('100%');
              }
              .padding(12)
              .backgroundColor(Color.White)
              .borderRadius(8)
              .margin({ top: 8, left: 16, right: 16 })
              .swipeAction({
                end: {
                  builder: () => { this.msgSwipeDeleteBuilder(msg); },
                  onAction: () => {
                    this.doDeleteMsg(msg);
                  },
                  actionAreaDistance: 56
                },
                edgeEffect: SwipeEdgeEffect.Spring
              });
            }, (msg: NtfyMessage) => msg.id);
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ bottom: 8 });
        }
        .width('100%')
        .layoutWeight(1);
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFF5F5F5');

    // Publish dialog
    if (this.showPublishDialog) {
      Column() {
        Column() {
          Text('发送消息')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .margin({ top: 20, bottom: 16 });

          TextInput({ placeholder: '标题（可选）', text: this.publishTitleInput })
            .width('100%')
            .height(44)
            .backgroundColor('#FFF5F5F5')
            .borderRadius(10)
            .padding({ left: 12, right: 12 })
            .margin({ bottom: 10 })
            .onChange((value: string) => { this.publishTitleInput = value; });

          TextInput({ placeholder: '消息内容', text: this.publishMessageInput })
            .width('100%')
            .height(80)
            .backgroundColor('#FFF5F5F5')
            .borderRadius(10)
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .onChange((value: string) => { this.publishMessageInput = value; });

          Row() {
            Button('取消')
              .backgroundColor('#FFF0F0F0')
              .fontColor('#FF333333')
              .borderRadius(20)
              .height(44)
              .layoutWeight(1)
              .margin({ right: 8 })
              .onClick(() => {
                this.showPublishDialog = false;
                this.publishTitleInput = '';
                this.publishMessageInput = '';
              });

            Button('发送')
              .backgroundColor('#FF0078D4')
              .fontColor(Color.White)
              .borderRadius(20)
              .height(44)
              .layoutWeight(1)
              .margin({ left: 8 })
              .enabled(!this.isPublishing)
              .onClick(() => this.doPublish());
          }
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 20, top: 16 });
        }
        .width('85%')
        .backgroundColor('#FFFFFFFF')
        .borderRadius(16)
        .shadow({ radius: 8, color: '#30000000', offsetY: 4 });
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#40000000')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.showPublishDialog = false;
      });
    }
    }
    .width('100%')
    .height('100%');
  }
}
