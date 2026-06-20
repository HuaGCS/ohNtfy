import { UIAbility, AbilityConstant, Want, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
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

  // 短时任务ID，用于退后台过渡
  private suspendDelayRequestId: number = -1;

  constructor() {
    super();
    this.websocketService = WebSocketService.getInstance();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.notificationService = new NotificationService(this.context);
    // 传入 subscriptionManager 以支持数据传输证明
    this.backgroundTaskService = new BackgroundTaskService(this.context, this.subscriptionManager);
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

    // 加载并应用主题
    await this.applySavedTheme();

    // 仅在 WS 模式下连接
    await this.connectWebSocketsIfEnabled();

    windowStage.loadContent('pages/Index', (err) => {
      if (err) {
        console.error('Failed to load main page:', JSON.stringify(err));
      }
    });
  }

  onNewWant(want: Want): void {
    const action = want?.parameters?.['action'] as string;
    const topic = want?.parameters?.['topic'] as string;
    const server = want?.parameters?.['server'] as string;
    const messageId = want?.parameters?.['messageId'] as string;

    // 通知按钮操作
    if (action === 'dismiss' && messageId && this.notificationService) {
      this.notificationService.cancelNotification(messageId);
      return;
    }
    if (action === 'markRead' && messageId && this.notificationService) {
      // 标记已读：取消通知，下次不再弹出
      this.notificationService.cancelNotification(messageId);
      this.subscriptionManager.markRead(server, topic);
      return;
    }

    // 点击通知正文：打开对应主题
    if (topic && server) {
      AppStorage.setOrCreate<string>('navigateToTopic', topic);
      AppStorage.setOrCreate<string>('navigateToServer', server);
    }
  }

  async onForeground(): Promise<void> {
    const savedData = await this.storageManager.loadSubscriptions();
    this.subscriptionManager.fromJSON(savedData);

    // 停止后台任务（常驻通知、心跳保活）
    if (this.backgroundTaskService) {
      await this.backgroundTaskService.stopBackgroundTask();
    }

    // 取消短时任务（如果有）
    if (this.suspendDelayRequestId > 0) {
      backgroundTaskManager.cancelSuspendDelay(this.suspendDelayRequestId);
      this.suspendDelayRequestId = -1;
    }

    // 回到前台：清空所有旧连接（可能已悬挂），重新建立
    this.websocketService.reconnectAll();

    // 重新连接 WS（回到前台时确保连接）
    await this.connectWebSocketsIfEnabled();
  }

  async onBackground(): Promise<void> {
    const json = this.subscriptionManager.toJSON();
    await this.storageManager.saveSubscriptions(json);

    // 第一步：申请短时任务作为过渡（最长3分钟）
    // 确保在长时任务申请完成前进程不会被挂起
    try {
      const delayInfo = backgroundTaskManager.requestSuspendDelay('ntfy preparing background task', () => {
        console.info('[ntfy] Suspend delay about to expire');
      });
      this.suspendDelayRequestId = delayInfo.requestId;
      console.info(`[ntfy] Suspend delay acquired: ${delayInfo.actualDelayTime}ms`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] requestSuspendDelay failed: ${err.code} ${err.message}`);
    }

    // 第二步：启动长时任务（包含数据传输证明、WS保活等）
    if (this.backgroundTaskService) {
      await this.backgroundTaskService.startBackgroundTask();
    }
  }

  onDestroy(): void {
    this.notificationService?.cancelAll();
    this.websocketService.disconnectAll();
    this.websocketService.stopPing();
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

    // 按服务器分组，每台服务器只连一次（共享连接）
    const serverTopics = new Map<string, string[]>();
    subs.forEach(sub => {
      const list = serverTopics.get(sub.server);
      if (list) {
        list.push(sub.topic);
      } else {
        serverTopics.set(sub.server, [sub.topic]);
      }
    });

    // 每台服务器独立连接，不同服务器之间错开 150ms
    let delay = 0;
    serverTopics.forEach((topics, server) => {
      setTimeout(() => {
        console.info(`[EntryAbility] WS connecting: ${server} topics=[${topics.join(',')}]`);
        this.websocketService.connectTopics(server, topics);
      }, delay);
      delay += 150;
    });
  }

  private async applySavedTheme(): Promise<void> {
    try {
      const mode = await this.storageManager.loadSetting('theme_mode', 'system');
      let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (mode === 'light') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      } else if (mode === 'dark') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      this.context.getApplicationContext().setColorMode(colorMode);
    } catch (e) {
      console.error('[EntryAbility] Failed to apply saved theme:', JSON.stringify(e));
    }
  }
}
