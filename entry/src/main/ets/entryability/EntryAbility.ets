import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { NotificationService } from '../model/NotificationService';
import { StorageManager } from '../model/StorageManager';
import { SubscriptionManager } from '../model/TopicModel';
import { BackgroundTaskService } from '../model/BackgroundTaskService';
import { MessageCacheService } from '../model/MessageCacheService';
import { WebSocketService } from '../model/WebSocketService';
import { NtfyMessage } from '../model/TopicModel';

export let globalStorageManager: StorageManager;
export let globalNotificationService: NotificationService;
export let globalSubscriptionManager: SubscriptionManager;
export let globalBackgroundTaskService: BackgroundTaskService;
export let globalMessageCacheService: MessageCacheService;
export let globalWebSocketService: WebSocketService;

export default class EntryAbility extends UIAbility {
  private storageManager: StorageManager = new StorageManager();
  private notificationService: NotificationService | null = null;
  private subscriptionManager: SubscriptionManager = new SubscriptionManager();
  private backgroundTaskService: BackgroundTaskService | null = null;
  private messageCacheService: MessageCacheService | null = null;
  private websocketService: WebSocketService;

  constructor() {
    super();
    this.websocketService = WebSocketService.getInstance();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.notificationService = new NotificationService(this.context);
    this.backgroundTaskService = new BackgroundTaskService(this.context);
    this.messageCacheService = new MessageCacheService(this.storageManager);

    globalStorageManager = this.storageManager;
    globalNotificationService = this.notificationService;
    globalSubscriptionManager = this.subscriptionManager;
    globalBackgroundTaskService = this.backgroundTaskService;
    globalMessageCacheService = this.messageCacheService;
    globalWebSocketService = this.websocketService;

    // 注册 WS 消息回调：通知 + 缓存 + 更新订阅状态
    this.websocketService.setOnMessage((msg: NtfyMessage, server: string, topic: string) => {
      console.info(`[EntryAbility] WS message received: id=${msg.id}, topic=${topic}, title=${msg.title ?? '-'}, event=${msg.event}`);

      if (this.notificationService) {
        this.notificationService.showNotification(msg, server, topic);
      }
      if (this.messageCacheService) {
        this.messageCacheService.addMessages(server, topic, [msg]);
      }
      this.subscriptionManager.updateLastMessage(server, topic, msg);
      console.info(`[EntryAbility] WS message processed: ${topic}`);
    });
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    await this.storageManager.initialize(this.context);
    if (this.notificationService) {
      await this.notificationService.initialize();
    }

    const savedData = await this.storageManager.loadSubscriptions();
    this.subscriptionManager.fromJSON(savedData);

    // 仅在 WS 模式下连接
    await this.connectWebSocketsIfEnabled();

    windowStage.loadContent('pages/Index', (err) => {
      if (err) {
        console.error('Failed to load main page:', JSON.stringify(err));
      }
    });
  }

  onNewWant(want: Want): void {
    const topic = want?.parameters?.['topic'] as string;
    const server = want?.parameters?.['server'] as string;
    if (topic && server) {
      AppStorage.setOrCreate<string>('navigateToTopic', topic);
      AppStorage.setOrCreate<string>('navigateToServer', server);
    }
  }

  async onForeground(): Promise<void> {
    const savedData = await this.storageManager.loadSubscriptions();
    this.subscriptionManager.fromJSON(savedData);

    // 仅在 WS 模式下连接
    await this.connectWebSocketsIfEnabled();

    if (this.backgroundTaskService) {
      await this.backgroundTaskService.stopBackgroundTask();
    }
  }

  async onBackground(): Promise<void> {
    const json = this.subscriptionManager.toJSON();
    await this.storageManager.saveSubscriptions(json);

    if (this.backgroundTaskService) {
      await this.backgroundTaskService.startBackgroundTask();
    }
  }

  onDestroy(): void {
    this.notificationService?.cancelAll();
    this.websocketService.disconnectAll();
    if (this.backgroundTaskService) {
      this.backgroundTaskService.stopBackgroundTask();
    }
    if (this.messageCacheService) {
      this.messageCacheService.clearAll();
    }
  }

  private async connectWebSocketsIfEnabled(): Promise<void> {
    const useWs = await this.storageManager.loadSetting('use_websocket', 'true');
    console.info(`[EntryAbility] connectWebSocketsIfEnabled: use_websocket=${useWs}`);
    if (useWs !== 'true') {
      this.websocketService.disconnectAll();
      return;
    }
    const subs = this.subscriptionManager.getSubscriptions();
    console.info(`[EntryAbility] Connecting WS for ${subs.length} subscriptions`);
    subs.forEach((sub, index) => {
      setTimeout(() => {
        console.info(`[EntryAbility] WS connecting: ${sub.server}/${sub.topic}`);
        this.websocketService.connect(sub.server, sub.topic);
      }, index * 150);
    });
  }
}
