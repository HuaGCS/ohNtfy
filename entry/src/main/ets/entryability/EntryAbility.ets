import { UIAbility, AbilityConstant, Want, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { NotificationService } from '../model/NotificationService';
import { StorageManager } from '../model/StorageManager';
import { SubscriptionManager } from '../model/TopicModel';
import { MessageCacheService } from '../model/MessageCacheService';
import { WebSocketService } from '../model/WebSocketService';
import { BackgroundTaskService } from '../model/BackgroundTaskService';

// 导出全局实例
export let globalStorageManager: StorageManager;
export let globalSubscriptionManager: SubscriptionManager;
export let globalWebSocketService: WebSocketService;
export let globalMessageCacheService: MessageCacheService;
export let globalNotificationService: NotificationService;
export let globalBackgroundTaskService: BackgroundTaskService;

export default class EntryAbility extends UIAbility {
  private storageManager: StorageManager = new StorageManager();
  private subscriptionManager: SubscriptionManager = new SubscriptionManager();
  private notificationService: NotificationService | null = null;
  private backgroundTaskService: BackgroundTaskService | null = null;
  private messageCacheService: MessageCacheService | null = null;
  private websocketService: WebSocketService;
  private suspendDelayRequestId: number = -1;

  constructor() {
    super();
    this.websocketService = WebSocketService.getInstance();
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const bundleName = this.context.abilityInfo.bundleName;
    this.notificationService = new NotificationService(bundleName);
    this.backgroundTaskService = new BackgroundTaskService(this.context, this.subscriptionManager, bundleName);
    this.messageCacheService = new MessageCacheService(this.storageManager);

    // 导出全局实例
    globalStorageManager = this.storageManager;
    globalSubscriptionManager = this.subscriptionManager;
    globalNotificationService = this.notificationService;
    globalBackgroundTaskService = this.backgroundTaskService;
    globalMessageCacheService = this.messageCacheService;
    globalWebSocketService = this.websocketService;

    // 启动后台 AppServiceExtensionAbility（负责 WS 连接 + 通知发布）
    try {
      const serviceWant: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'ServiceExtAbility'
      };
      this.context.startAbility(serviceWant).catch((e: BusinessError) => {
        console.error(`[EntryAbility] Failed to start ServiceExtAbility: ${e.code} ${e.message}`);
      });
      console.info('[EntryAbility] ServiceExtAbility start requested');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[EntryAbility] startAbility error: ${err.code} ${err.message}`);
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    await this.storageManager.initialize(this.context);

    // 初始化通知渠道 + 请求通知权限（仅在 UIAbility 上下文可用）
    if (this.notificationService) {
      await this.notificationService.initialize();
    }
    try {
      await notificationManager.requestEnableNotification(this.context);
    } catch (_e) {
      // ignore
    }

    const savedData = await this.storageManager.loadSubscriptions();
    this.subscriptionManager.fromJSON(savedData);

    // 加载并应用主题
    await this.applySavedTheme();

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

    if (action === 'dismiss' && messageId && this.notificationService) {
      this.notificationService.cancelNotification(messageId);
      return;
    }
    if (action === 'markRead' && messageId && this.notificationService) {
      this.notificationService.cancelNotification(messageId);
      this.subscriptionManager.markRead(server, topic);
      return;
    }

    if (topic && server) {
      AppStorage.setOrCreate<string>('navigateToTopic', topic);
      AppStorage.setOrCreate<string>('navigateToServer', server);
    }
  }

  async onForeground(): Promise<void> {
    const savedData = await this.storageManager.loadSubscriptions();
    this.subscriptionManager.fromJSON(savedData);

    // 停止后台任务（回到前台不需要保活）
    if (this.backgroundTaskService) {
      await this.backgroundTaskService.stopBackgroundTask();
    }

    if (this.suspendDelayRequestId > 0) {
      backgroundTaskManager.cancelSuspendDelay(this.suspendDelayRequestId);
      this.suspendDelayRequestId = -1;
    }

    // 通知后台服务重新加载数据
    try {
      const serviceWant: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: 'ServiceExtAbility'
      };
      this.context.startAbility(serviceWant).catch((_e: BusinessError) => {});
    } catch (_e) {
      // ignore
    }
  }

  async onBackground(): Promise<void> {
    const json = this.subscriptionManager.toJSON();
    await this.storageManager.saveSubscriptions(json);

    // 申请短时任务作为过渡
    try {
      const delayInfo = backgroundTaskManager.requestSuspendDelay('ntfy preparing background task', () => {
        console.info('[ntfy] Suspend delay about to expire');
      });
      this.suspendDelayRequestId = delayInfo.requestId;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] requestSuspendDelay failed: ${err.code} ${err.message}`);
    }

    // 启动长时任务（数据传输证明 + WS 保活）
    if (this.backgroundTaskService) {
      this.websocketService.reconnectAll();
      await this.backgroundTaskService.startBackgroundTask();
    }
  }

  onDestroy(): void {
    this.notificationService?.cancelAll();
    this.websocketService.disconnectAll();
    this.websocketService.stopPing();
    if (this.backgroundTaskService) {
      this.backgroundTaskService.stopBackgroundTask();
      this.backgroundTaskService.destroy();
    }
    if (this.messageCacheService) {
      this.messageCacheService.clearAll();
    }
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
