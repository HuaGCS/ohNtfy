import {
  globalStorageManager, globalSubscriptionManager, globalNotificationService,
  globalWebSocketService, globalMessageCacheService
} from '../entryability/EntryAbility';
import { TopicSubscription, NtfyMessage } from '../model/TopicModel';
import { NtfyService } from '../model/NtfyService';
import { Constants } from '../common/Constants';
import { WebSocketService, ConnectionState, WsStatus } from '../model/WebSocketService';
import { router } from '@kit.ArkUI';

interface PollingState {
  server: string;
  topic: string;
  service: NtfyService;
  timerId: number;
}

@Entry
@Component
struct Index {
  @State subscriptions: TopicSubscription[] = [];
  @State isRefreshing: boolean = false;
  @State showDeleteDialog: boolean = false;
  @State deleteTarget: TopicSubscription | null = null;
  @State connectionStatus: Map<string, ConnectionState> = new Map();
  @State connectedCount: number = 0;
  @State totalCount: number = 0;
  @StorageLink('settingsChanged') settingsChanged: boolean = false;

  private pollingServices: Map<string, PollingState> = new Map();
  private wsService: WebSocketService = globalWebSocketService ?? WebSocketService.getInstance();
  private staggeredTimers: number[] = [];

  aboutToAppear(): void {
    this.loadSubscriptions();

    AppStorage.setOrCreate<string>('navigateToTopic', '');
    AppStorage.setOrCreate<string>('navigateToServer', '');
    AppStorage.setOrCreate<boolean>('settingsChanged', false);

    // 监听 WS 状态变化（连接指示灯）
    this.wsService.setOnStatusChange((status: WsStatus) => {
      const key = `${status.server}_${status.topic}`;
      const newMap = new Map(this.connectionStatus);
      newMap.set(key, status.state);
      this.connectionStatus = newMap;
      this.updateConnectedCount();
    });

    // 监听 WS 消息：刷新 UI 显示
    this.wsService.setOnMessage((msg: NtfyMessage, server: string, topic: string) => {
      console.info(`[Index] WS UI refresh: id=${msg.id}, topic=${topic}`);
      // updateLastMessage 内部已做不可变替换 — getSubscriptions() 返回全新副本
      const subs = globalSubscriptionManager?.getSubscriptions() ?? [];
      this.subscriptions = subs;
      console.info(`[Index] UI updated with ${subs.length} subscriptions`);
    });

    // 初始化连接模式
    this.handleConnectionMode();
  }

  async onPageShow(): Promise<void> {
    this.loadSubscriptions();
    // 始终刷新连接模式：确保新增的订阅也建立 WS/轮询连接
    // WebSocketService.connect() 有幂等守卫，已有的连接不会重复建立
    this.stopAllPolling();
    await this.handleConnectionMode();
    if (this.settingsChanged) {
      AppStorage.setOrCreate<boolean>('settingsChanged', false);
    }
    // 从服务器拉取最新消息（不阻塞 UI，异步刷新）
    this.fetchLatestMessages();
  }

  /**
   * 根据 use_websocket 设置决定连接模式：
   * WS 模式 → 停止轮询，连接 WS（EntryAbility 也会连，这里补齐切换场景）
   * JSON 模式 → 断开 WS，启动定时轮询
   */
  private async handleConnectionMode(): Promise<void> {
    const useWsSetting = await globalStorageManager?.loadSetting('use_websocket', 'true') ?? 'true';
    const useWs = useWsSetting === 'true';
    console.info(`[Index] Connection mode: ${useWs ? 'WebSocket' : 'JSON polling'}`);
    if (useWs) {
      // WS 模式：停止所有轮询，确保 WS 已连接
      this.stopAllPolling();
      this.connectAllWs();
    } else {
      // JSON 轮询模式：断开 WS，启动轮询
      this.wsService.disconnectAll();
      this.setupPolling();
    }
  }

  private stopAllPolling(): void {
    this.pollingServices.forEach((state) => {
      clearTimeout(state.timerId);
    });
    this.pollingServices.clear();
    for (const id of this.staggeredTimers) {
      clearTimeout(id);
    }
    this.staggeredTimers = [];
  }

  aboutToDisappear(): void {
    this.stopAllPolling();
    this.wsService.clearOnStatusChange();
  }

  loadSubscriptions(): void {
    const subs = globalSubscriptionManager?.getSubscriptions() ?? [];
    this.subscriptions = subs;
    this.totalCount = subs.length;
    this.updateConnectedCount();
    // 调试：打印每个订阅是否显示未读
    for (const s of subs) {
      const unread = s.lastMessage && (s.lastReadId === undefined || s.lastMessage.id !== s.lastReadId);
      console.info(`[Index] sub: ${s.topic}, lastMsgId=${s.lastMessage?.id}, lastReadId=${s.lastReadId}, unread=${unread}`);
    }
  }

  connectAllWs(): void {
    const subs = globalSubscriptionManager?.getSubscriptions() ?? [];
    // 分批连接 WS，每 150ms 一个，避免瞬间并发太多连接
    subs.forEach((sub, index) => {
      const id = setTimeout(() => {
        this.wsService.connect(sub.server, sub.topic);
      }, index * 150);
      this.staggeredTimers.push(id);
    });
  }

  setupPolling(): void {
    const subs = globalSubscriptionManager?.getSubscriptions() ?? [];
    // 分批启动轮询，每 300ms 一个
    subs.forEach((sub, index) => {
      const id = setTimeout(() => {
        this.startPolling(sub.server, sub.topic);
      }, index * 300);
      this.staggeredTimers.push(id);
    });
  }

  /**
   * 为指定 topic 启动定时轮询
   */
  startPolling(server: string, topic: string): void {
    const key = `${server}_${topic}`;
    if (this.pollingServices.has(key)) return;

    const service = new NtfyService(server);
    const state: PollingState = { server, topic, service, timerId: -1 };
    this.pollingServices.set(key, state);

    // 递归 setTimeout 链：上一轮完成后再等间隔，避免请求重叠
    const scheduleNext = (): void => {
      const current = this.pollingServices.get(key);
      if (!current) return;
      current.timerId = setTimeout((): void => {
        this.doPoll(server, topic, service).finally(() => scheduleNext());
      }, Constants.POLL_INTERVAL_MS);
    };

    // 首轮立即执行
    this.doPoll(server, topic, service).finally(() => scheduleNext());
  }

  /**
   * 执行一次轮询：拉取新消息 → 更新订阅状态 → 刷新 UI → 发送通知
   * @param server 服务器地址
   * @param topic 主题名
   * @param service NtfyService 实例
   */
  async doPoll(server: string, topic: string, service: NtfyService): Promise<void> {
    // 实时查询订阅对象，避免闭包捕获过期引用
    const sub = globalSubscriptionManager?.getSubscription(server, topic);
    if (!sub) return;

    try {
      const messages = await service.pollMessages(topic);
      console.info(`[Index] Poll result for ${topic}: ${messages.length} messages`);
      // 过滤已本地删除的消息
      const deletedPollIds = await globalMessageCacheService?.getDeletedIds(server, topic) ?? new Set<string>();
      const undeletedPoll = messages.filter(m => !deletedPollIds.has(m.id));
      if (undeletedPoll.length > 0) {
        const latest = undeletedPoll[undeletedPoll.length - 1];
        globalSubscriptionManager?.updateLastMessage(server, topic, latest);

        // 刷新 UI
        const subs = globalSubscriptionManager?.getSubscriptions() ?? [];
        this.subscriptions = [...subs];
        console.info(`[Index] Poll UI updated: ${topic} newest id=${latest.id}`);

        // 写入缓存
        if (globalMessageCacheService) {
          await globalMessageCacheService.addMessages(server, topic, messages);
        }

        // 判断真正的新消息（上次最后一条之后的消息）
        const lastMsgId = sub.lastMessage?.id;
        if (lastMsgId) {
          const lastIdx = messages.findIndex(m => m.id === lastMsgId);
          const reallyNew = lastIdx >= 0 ? messages.slice(lastIdx + 1) : messages;
          for (const msg of reallyNew) {
            if (!globalNotificationService?.isAlreadyNotified(msg.id)) {
              await globalNotificationService?.showNotification(msg, server, topic);
              console.info(`[Index] Poll notification sent: ${topic} msg=${msg.id}`);
            }
          }
        }
      }
    } catch (e) {
      console.error(`Poll failed for ${topic}:`, JSON.stringify(e));
    }
  }

  stopPolling(server: string, topic: string): void {
    const key = `${server}_${topic}`;
    const state = this.pollingServices.get(key);
    if (state) {
      clearTimeout(state.timerId);
      this.pollingServices.delete(key);
    }
  }

  /**
   * 从服务器拉取每个订阅的最新消息，确保 UI 显示的不是过期缓存。
   * Fire-and-forget：不阻塞 UI，先展示已有数据，网络返回后再刷新。
   */
  private async fetchLatestMessages(): Promise<void> {
    const subs = globalSubscriptionManager?.getSubscriptions() ?? [];
    if (subs.length === 0) return;

    console.info(`[Index] Fetching latest messages for ${subs.length} subscriptions...`);
    for (const sub of subs) {
      try {
        const service = new NtfyService(sub.server);
        const messages = await service.fetchMessages(sub.topic, 'all');
        // 过滤已本地删除的消息
        const deletedIds = await globalMessageCacheService?.getDeletedIds(sub.server, sub.topic) ?? new Set<string>();
        const undeleted = messages.filter(m => !deletedIds.has(m.id));
        if (undeleted.length > 0) {
          const latest = undeleted[undeleted.length - 1];
          globalSubscriptionManager?.updateLastMessage(sub.server, sub.topic, latest);
          console.info(`[Index] Latest message fetched: ${sub.topic} id=${latest.id}`);
        } else {
          globalSubscriptionManager?.clearLastMessage(sub.server, sub.topic);
          console.info(`[Index] All messages deleted for: ${sub.topic}`);
        }
      } catch (e) {
        console.error(`[Index] fetchLatestMessages failed for ${sub.topic}:`, JSON.stringify(e));
      }
    }
    // 全部拉取完成后统一刷新 UI
    this.subscriptions = globalSubscriptionManager?.getSubscriptions() ?? [];
    console.info(`[Index] fetchLatestMessages complete, UI refreshed`);
  }

  async onRefresh(): Promise<void> {
    this.isRefreshing = true;
    // 先从服务器拉取最新消息，再重建实时连接
    await this.fetchLatestMessages();
    this.stopAllPolling();
    await this.handleConnectionMode();
    this.isRefreshing = false;
  }

  updateConnectedCount(): void {
    let count = 0;
    this.connectionStatus.forEach((state) => {
      if (state === ConnectionState.CONNECTED) count++;
    });
    this.connectedCount = count;
  }

  navigateToAddTopic(): void {
    router.pushUrl({ url: 'pages/AddTopic' });
  }

  navigateToSettings(): void {
    router.pushUrl({ url: 'pages/Settings' });
  }

  navigateToTopicDetail(sub: TopicSubscription): void {
    router.pushUrl({
      url: 'pages/TopicDetail',
      params: {
        server: sub.server,
        topic: sub.topic,
        displayName: sub.displayName
      }
    });
  }

  requestDelete(sub: TopicSubscription): void {
    this.deleteTarget = sub;
    this.showDeleteDialog = true;
  }

  confirmDelete(): void {
    const sub = this.deleteTarget;
    if (!sub) return;

    globalSubscriptionManager?.removeSubscription(sub.server, sub.topic);
    this.stopPolling(sub.server, sub.topic);
    this.wsService.disconnect(sub.server, sub.topic);
    globalMessageCacheService?.clearTopic(sub.server, sub.topic);
    this.subscriptions = globalSubscriptionManager?.getSubscriptions() ?? [];
    // 更新总数
    this.totalCount = this.subscriptions.length;
    // 清理 connectionStatus 中已删除 topic 的旧状态
    const key = `${sub.server}_${sub.topic}`;
    if (this.connectionStatus.has(key)) {
      const newMap = new Map(this.connectionStatus);
      newMap.delete(key);
      this.connectionStatus = newMap;
      this.updateConnectedCount();
    }
    globalStorageManager?.saveSubscriptions(
      globalSubscriptionManager?.toJSON() ?? '[]'
    );
    this.showDeleteDialog = false;
    this.deleteTarget = null;
  }

  cancelDelete(): void {
    this.showDeleteDialog = false;
    this.deleteTarget = null;
  }

  getPriorityColor(priority?: number): string {
    return Constants.PRIORITY_COLORS[priority ?? 3] ?? '#0078D4';
  }

  getConnectionStateColor(server: string, topic: string): string {
    const key = `${server}_${topic}`;
    const state = this.connectionStatus.get(key);
    switch (state) {
      case ConnectionState.CONNECTED:
        return '#FF4CAF50';
      case ConnectionState.CONNECTING:
      case ConnectionState.RECONNECTING:
        return '#FFFFC107';
      case ConnectionState.ERROR:
        return '#FFF44336';
      default:
        return '#FF9E9E9E';
    }
  }

  formatTime(timestamp: number): string {
    const date = new Date(timestamp * 1000);
    const now = new Date();
    const diffMs = now.getTime() - date.getTime();
    const diffMin = Math.floor(diffMs / 60000);

    if (diffMin < 1) return '刚刚';
    if (diffMin < 60) return `${diffMin}分钟前`;
    const diffHour = Math.floor(diffMin / 60);
    if (diffHour < 24) return `${diffHour}小时前`;
    const diffDay = Math.floor(diffHour / 24);
    if (diffDay < 7) return `${diffDay}天前`;
    return `${date.getMonth() + 1}/${date.getDate()}`;
  }

  @Builder
  swipeDeleteBuilder(sub: TopicSubscription) {
    Column() {
      Text('删除')
        .fontSize(14)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .backgroundColor('#FFE81123')
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .onClick(() => {
      this.requestDelete(sub);
    });
  }

  build() {
    Stack() {
      Column() {
        // Header
        Row() {
          Text($r('app.string.app_name'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .margin({ left: 16 });

          // Connection status indicator
          if (this.totalCount > 0) {
            Row() {
              Column()
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor(
                  this.connectedCount > 0 ? '#FF4CAF50' : '#FF9E9E9E'
                )
                .margin({ left: 8, right: 4 });
              Text(`${this.connectedCount}/${this.totalCount} 已连接`)
                .fontSize(10)
                .fontColor($r('app.color.text_hint'));
            }
            .margin({ left: 8 });
          }

          Blank();
          Image($r('app.media.ic_settings'))
            .width(24)
            .height(24)
            .margin({ right: 8 })
            .onClick(() => this.navigateToSettings());
          Image($r('app.media.ic_add'))
            .width(24)
            .height(24)
            .margin({ right: 16 })
            .onClick(() => this.navigateToAddTopic());
        }
        .width('100%')
        .height(56)
        .backgroundColor($r('app.color.card_background'))
        .shadow({ radius: 2, color: '#10000000', offsetY: 2 });

        if (this.subscriptions.length === 0) {
          // Empty state
          Column() {
            Text($r('app.string.no_subscriptions'))
              .fontSize(18)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 120 });
            Text($r('app.string.tap_to_add'))
              .fontSize(14)
              .fontColor($r('app.color.text_hint'))
              .margin({ top: 8 });
          }
          .width('100%')
          .height('100%')
          .alignItems(HorizontalAlign.Center);
        } else {
          // Subscription list with pull-to-refresh
          Refresh({ refreshing: $$this.isRefreshing }) {
            List() {
              ForEach(this.subscriptions, (sub: TopicSubscription, index: number) => {
                ListItem() {
                  Stack({ alignContent: Alignment.TopEnd }) {
                    Row() {
                      // Priority + connection indicator
                      Column() {
                        Column()
                          .width(4)
                          .height(16)
                          .borderRadius(2)
                          .backgroundColor(
                            this.getPriorityColor(sub.lastMessage?.priority)
                          );
                        Column()
                          .width(4)
                          .height(16)
                          .borderRadius(2)
                          .backgroundColor(
                            this.getConnectionStateColor(sub.server, sub.topic)
                          )
                          .margin({ top: 2 });
                      }
                      .width(4)
                      .height(40)
                      .margin({ right: 12 });

                      // Topic info
                      Column() {
                        Text(sub.displayName || sub.topic)
                          .fontSize(16)
                          .fontWeight((sub.lastMessage && (sub.lastReadId === undefined || sub.lastMessage.id !== sub.lastReadId)) ? FontWeight.Bold : FontWeight.Medium)
                          .lineHeight(22)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .maxLines(1);
                        Text(sub.lastMessage?.title || sub.lastMessage?.message || '暂无消息')
                          .fontSize(13)
                          .fontColor($r('app.color.text_secondary'))
                          .lineHeight(18)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .maxLines(1)
                          .margin({ top: 2 });
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start);

                      // Time & server
                      Column() {
                        if (sub.lastMessage) {
                          Text(this.formatTime(sub.lastMessage.time))
                            .fontSize(11)
                            .fontColor($r('app.color.text_hint'));
                        }
                        Text(sub.server.replace('https://', '').split('/')[0])
                          .fontSize(10)
                          .fontColor($r('app.color.text_tertiary'))
                          .margin({ top: 4 });
                      }
                      .alignItems(HorizontalAlign.End)
                      .margin({ right: 4 });

                      Image($r('app.media.ic_chevron'))
                        .width(16)
                        .height(16)
                        .margin({ left: 4, right: 8 });
                    }
                    .width('100%')
                    .padding({ top: 12, bottom: 12, left: 16, right: 8 })
                    .backgroundColor($r('app.color.card_background'))
                    .borderRadius(12)
                    .onClick(() => this.navigateToTopicDetail(sub));

                    // 未读绿色圆点
                    if (sub.lastMessage && (sub.lastReadId === undefined || sub.lastMessage.id !== sub.lastReadId)) {
                      Column()
                        .width(10)
                        .height(10)
                        .borderRadius(5)
                        .backgroundColor('#FF4CAF50')
                        .margin({ top: 12, right: 8 });
                    }
                  }
                  .width('100%');
                }
                .margin({ left: 16, right: 16, top: 6, bottom: 6 })
                .swipeAction({
                  end: {
                    builder: () => { this.swipeDeleteBuilder(sub); },
                    onAction: () => {
                      this.requestDelete(sub);
                    },
                    actionAreaDistance: 56
                  },
                  edgeEffect: SwipeEdgeEffect.Spring
                });
              }, (sub: TopicSubscription) => sub.id + '_' + (sub.lastMessage?.id ?? 'none') + '_' + (sub.lastReadId ?? 'none'));
            }
            .width('100%')
            .layoutWeight(1)
            .backgroundColor($r('app.color.background'))
          }
          .onRefreshing(() => {
            this.onRefresh();
          })
          .width('100%')
          .layoutWeight(1);
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.background'));

      // Delete confirmation dialog
      if (this.showDeleteDialog && this.deleteTarget) {
        Column() {
          Column() {
            Text($r('app.string.delete_subscription_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .margin({ top: 20, bottom: 8 });

            Text(`"${this.deleteTarget.displayName || this.deleteTarget.topic}"`)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 4 });

            Text($r('app.string.delete_subscription_message'))
              .fontSize(13)
              .fontColor($r('app.color.text_hint'))
              .margin({ bottom: 20 });

            Row() {
              Button($r('app.string.cancel'))
                .backgroundColor($r('app.color.button_secondary_bg'))
                .fontColor($r('app.color.text_primary'))
                .borderRadius(20)
                .height(44)
                .layoutWeight(1)
                .margin({ right: 8 })
                .onClick(() => this.cancelDelete());

              Button($r('app.string.delete'))
                .backgroundColor($r('app.color.error_color'))
                .fontColor(Color.White)
                .borderRadius(20)
                .height(44)
                .layoutWeight(1)
                .margin({ left: 8 })
                .onClick(() => this.confirmDelete());
            }
            .width('100%')
            .padding({ left: 20, right: 20, bottom: 20 });
          }
          .width('85%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(16)
          .shadow({ radius: 8, color: '#30000000', offsetY: 4 });
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#40000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => this.cancelDelete());
      }
    }
    .width('100%')
    .height('100%');
  }
}
