import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { WebSocketService } from './WebSocketService';
import { NotificationService } from './NotificationService';
import { SubscriptionManager } from './TopicModel';

export class BackgroundTaskService {
  private context: common.UIAbilityContext;
  private websocketService: WebSocketService;
  private notificationService: NotificationService | null = null;
  private subscriptionManager: SubscriptionManager | null = null;
  private heartbeatTimerId: number = -1;
  private isRunning: boolean = false;

  // 心跳间隔：60秒
  private static readonly HEARTBEAT_INTERVAL_MS = 60000;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.websocketService = WebSocketService.getInstance();
  }

  /**
   * 设置关联的服务引用
   */
  setServices(
    notificationService: NotificationService,
    subscriptionManager: SubscriptionManager
  ): void {
    this.notificationService = notificationService;
    this.subscriptionManager = subscriptionManager;
  }

  async startBackgroundTask(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;

    try {
      // 请求后台长时任务
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: 'EntryAbility'
        } as Want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);

      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      console.info('[ntfy] Background task started');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] Background task start failed: ${err.code} ${err.message}`);
    }

    // 启动 WebSocket Ping
    this.websocketService.startPing();

    // 发布常驻占位通知
    await this.updatePlaceholderNotification();

    // 启动健康检查心跳
    this.startHeartbeat();
  }

  async stopBackgroundTask(): Promise<void> {
    this.isRunning = false;
    this.stopHeartbeat();

    // 停止 WebSocket Ping
    this.websocketService.stopPing();

    // 取消常驻占位通知
    if (this.notificationService) {
      await this.notificationService.cancelPlaceholder();
    }

    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      console.info('[ntfy] Background task stopped');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] Background task stop failed: ${err.code} ${err.message}`);
    }
  }

  /**
   * 更新常驻通知中的连接信息
   */
  async updatePlaceholderNotification(): Promise<void> {
    if (!this.notificationService) return;

    const subCount = this.subscriptionManager?.getSubscriptions().length ?? 0;
    const connectedCount = this.websocketService.getConnectedCount();

    if (this.notificationService.isPlaceholderActive()) {
      await this.notificationService.updatePlaceholder(subCount, connectedCount);
    } else {
      await this.notificationService.publishPlaceholder(subCount, connectedCount);
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();

    // 每分钟执行一次健康检查
    this.heartbeatTimerId = setInterval(async () => {
      if (!this.isRunning) {
        this.stopHeartbeat();
        return;
      }

      console.info('[ntfy] Background heartbeat tick');

      // 1. 执行 WebSocket 健康检查（自动重连失活的连接）
      const healthResults = this.websocketService.healthCheck();
      let unhealthyCount = 0;
      healthResults.forEach((healthy) => {
        if (!healthy) unhealthyCount++;
      });

      // 2. 更新常驻通知中的状态
      await this.updatePlaceholderNotification();

      if (unhealthyCount > 0) {
        console.info(`[ntfy] HealthCheck: ${unhealthyCount} connections reconnected`);
      }
    }, BackgroundTaskService.HEARTBEAT_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimerId > 0) {
      clearInterval(this.heartbeatTimerId);
      this.heartbeatTimerId = -1;
    }
  }

  isRunningState(): boolean {
    return this.isRunning;
  }
}
