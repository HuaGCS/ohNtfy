import { AppServiceExtensionAbility, Want } from '@kit.AbilityKit';
import { NotificationService } from '../model/NotificationService';
import { StorageManager } from '../model/StorageManager';
import { SubscriptionManager, NtfyMessage } from '../model/TopicModel';
import { MessageCacheService } from '../model/MessageCacheService';
import { WebSocketService } from '../model/WebSocketService';

// 导出全局实例，供其他模块引用
export let serviceStorageManager: StorageManager;
export let serviceNotificationService: NotificationService;
export let serviceSubscriptionManager: SubscriptionManager;
export let serviceMessageCacheService: MessageCacheService;
export let serviceWebSocketService: WebSocketService;

export default class ServiceExtAbility extends AppServiceExtensionAbility {
  private storageManager: StorageManager = new StorageManager();
  private notificationService: NotificationService | null = null;
  private subscriptionManager: SubscriptionManager = new SubscriptionManager();
  private messageCacheService: MessageCacheService | null = null;
  private websocketService: WebSocketService;

  constructor() {
    super();
    this.websocketService = WebSocketService.getInstance();
  }

  async onCreate(want: Want): Promise<void> {
    console.info('[ServiceExt] onCreate');

    // 使用 AppServiceExtension 的 context 初始化
    const bundleName = this.context.extensionAbilityInfo.bundleName;
    this.notificationService = new NotificationService(bundleName);
    this.messageCacheService = new MessageCacheService(this.storageManager);

    // 导出全局实例
    serviceStorageManager = this.storageManager;
    serviceNotificationService = this.notificationService;
    serviceSubscriptionManager = this.subscriptionManager;
    serviceMessageCacheService = this.messageCacheService;
    serviceWebSocketService = this.websocketService;

    // 初始化持久化存储
    await this.storageManager.initialize(this.context);
    const savedData = await this.storageManager.loadSubscriptions();
    this.subscriptionManager.fromJSON(savedData);

    // 初始化通知渠道
    if (this.notificationService) {
      await this.notificationService.initialize();
    }

    // 注册 WS 消息回调：后台独立处理通知 + 缓存
    this.websocketService.setOnMessage((msg: NtfyMessage, server: string, topic: string) => {
      console.info(`[ServiceExt] WS message received: id=${msg.id}, topic=${topic}`);

      if (this.notificationService) {
        this.notificationService.showNotification(msg, server, topic);
      }
      if (this.messageCacheService) {
        this.messageCacheService.addMessages(server, topic, [msg]);
      }
      this.subscriptionManager.updateLastMessage(server, topic, msg);

      // 持久化保存订阅状态
      const json = this.subscriptionManager.toJSON();
      this.storageManager.saveSubscriptions(json);
    });

    // 建立 WebSocket 连接
    this.connectWebSockets();

    console.info('[ServiceExt] onCreate complete');
  }

  onRequest(want: Want, startId: number): void {
    console.info(`[ServiceExt] onRequest: startId=${startId}`);

    // 重新加载订阅数据
    this.storageManager.loadSubscriptions().then((savedData: string) => {
      this.subscriptionManager.fromJSON(savedData);

      // 确保 WebSocket 已连接
      this.websocketService.reconnectAll();
      this.connectWebSockets();
    });
  }

  async onDestroy(): Promise<void> {
    console.info('[ServiceExt] onDestroy');

    // 保存最终状态
    const json = this.subscriptionManager.toJSON();
    await this.storageManager.saveSubscriptions(json);

    // 清理资源
    this.notificationService?.cancelAll();
    this.websocketService.disconnectAll();
    this.websocketService.stopPing();
    this.websocketService.clearOnMessage();

    this.messageCacheService?.clearAll();
  }

  private connectWebSockets(): void {
    const subs = this.subscriptionManager.getSubscriptions();
    if (subs.length === 0) return;

    // 按服务器分组
    const serverTopics = new Map<string, string[]>();
    subs.forEach(sub => {
      const list = serverTopics.get(sub.server);
      if (list) {
        list.push(sub.topic);
      } else {
        serverTopics.set(sub.server, [sub.topic]);
      }
    });

    // 错开连接时间
    let delay = 0;
    serverTopics.forEach((topics, server) => {
      setTimeout(() => {
        console.info(`[ServiceExt] WS connecting: ${server} topics=[${topics.join(',')}]`);
        this.websocketService.connectTopics(server, topics);
      }, delay);
      delay += 150;
    });
  }
}
