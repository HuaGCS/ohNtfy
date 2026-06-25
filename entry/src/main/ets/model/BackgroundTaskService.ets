import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { WebSocketService } from './WebSocketService';
import { SubscriptionManager } from './TopicModel';

export class BackgroundTaskService {
  private context: common.Context;
  private bundleName: string;
  private websocketService: WebSocketService;
  private subscriptionManager: SubscriptionManager;
  private heartbeatTimerId: number = -1;
  private isRunning: boolean = false;
  private dataTransferProofTimerId: number = -1;
  private isCanceledBySystem: boolean = false;
  private retryCount: number = 0;

  // 心跳间隔：30秒
  private static readonly HEARTBEAT_INTERVAL_MS = 30000;

  // 数据传输证据间隔：30秒（原5分钟）
  private static readonly DATA_TRANSFER_PROOF_INTERVAL_MS = 30000;

  // 后台任务取消后重新申请的延迟
  private static readonly REAPPLY_DELAY_MS = 3000;

  // 最大重试次数
  private static readonly MAX_RETRIES = 3;

  constructor(context: common.Context, subscriptionManager: SubscriptionManager, bundleName: string) {
    this.context = context;
    this.bundleName = bundleName;
    this.websocketService = WebSocketService.getInstance();
    this.subscriptionManager = subscriptionManager;
    this.registerContinuousTaskCancel();
  }

  private registerContinuousTaskCancel(): void {
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        console.warn(`[ntfy] Background task canceled by system: id=${info.id}, reason=${info.reason}`);
        this.isCanceledBySystem = true;
        this.isRunning = false;

        setTimeout(() => {
          if (!this.isRunning) {
            console.info('[ntfy] Auto re-applying background task after system cancel');
            this.startBackgroundTask().catch((e: Error) => {
              console.error(`[ntfy] Re-apply failed: ${e.message}`);
            });
          }
        }, BackgroundTaskService.REAPPLY_DELAY_MS);
      });
      console.info('[ntfy] ContinuousTaskCancel listener registered');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] Register continuousTaskCancel failed: ${err.code} ${err.message}`);
    }
  }

  private unregisterContinuousTaskCancel(): void {
    try {
      backgroundTaskManager.off('continuousTaskCancel');
    } catch (_e) {
      // ignore
    }
  }

  async startBackgroundTask(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;
    this.isCanceledBySystem = false;
    this.retryCount = 0;

    try {
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: this.bundleName,
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
      console.info('[ntfy] Background task started successfully');

      // 启动后立即执行一次数据传输证明
      await this.performDataTransferProof();
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] Background task start failed: ${err.code} ${err.message}`);
      this.isRunning = false;

      if (!this.isCanceledBySystem) {
        this.scheduleRetry();
      }
      return;
    }

    // 启动 WebSocket Ping（健康检查）
    this.websocketService.startPing();

    // 启动健康检查心跳
    this.startHeartbeat();

    // 启动数据传输证明
    this.startDataTransferProof();
  }

  private scheduleRetry(): void {
    this.retryCount++;
    if (this.retryCount > BackgroundTaskService.MAX_RETRIES) {
      console.error('[ntfy] Background task retry exhausted');
      return;
    }

    const delay = this.retryCount * 5000;
    console.info(`[ntfy] Retry background task in ${delay}ms (attempt ${this.retryCount}/${BackgroundTaskService.MAX_RETRIES})`);

    setTimeout(() => {
      if (!this.isRunning) {
        this.startBackgroundTask().catch((e: Error) => {
          console.error(`[ntfy] Retry ${this.retryCount} failed: ${e.message}`);
        });
      }
    }, delay);
  }

  /**
   * 数据传输证明 - 每30秒向每个ntfy服务器发起消息拉取请求
   */
  private async performDataTransferProof(): Promise<void> {
    const subs = this.subscriptionManager.getSubscriptions();
    if (subs.length === 0) return;

    // 使用数组避免 Map destructuring
    const serverList: string[] = [];
    const topicListByServer: string[][] = [];
    subs.forEach(sub => {
      const idx = serverList.indexOf(sub.server);
      if (idx >= 0) {
        topicListByServer[idx].push(sub.topic);
      } else {
        serverList.push(sub.server);
        topicListByServer.push([sub.topic]);
      }
    });

    for (let si = 0; si < serverList.length; si++) {
      const serverUrl = serverList[si];
      const topics = topicListByServer[si];
      for (let ti = 0; ti < topics.length; ti++) {
        const topic = topics[ti];
        try {
          const httpClient = http.createHttp();
          const baseUrl = serverUrl.replace(/\/+$/, '');
          const url = `${baseUrl}/${topic}/json?poll=1`;
          const response = await httpClient.request(url, {
            method: http.RequestMethod.GET,
            connectTimeout: 5000,
            readTimeout: 8000,
            header: { 'Accept': 'application/json' },
            expectDataType: http.HttpDataType.STRING
          });

          if (response.responseCode === 200) {
            const dataLen = (response.result as string)?.length ?? 0;
            console.info(`[ntfy] Data transfer proof: ${topic} -> ${response.responseCode}, ${dataLen}bytes`);
          } else {
            console.info(`[ntfy] Data transfer proof: ${topic} -> ${response.responseCode}`);
          }
          httpClient.destroy();
        } catch (_e) {
          console.info(`[ntfy] Data transfer proof failed (network activity still counts)`);
        }

        await new Promise<void>(resolve => setTimeout(resolve, 50));
      }
    }
  }

  private startDataTransferProof(): void {
    this.stopDataTransferProof();
    this.dataTransferProofTimerId = setInterval(() => {
      if (!this.isRunning) {
        this.stopDataTransferProof();
        return;
      }
      this.performDataTransferProof();
    }, BackgroundTaskService.DATA_TRANSFER_PROOF_INTERVAL_MS);
  }

  private stopDataTransferProof(): void {
    if (this.dataTransferProofTimerId > 0) {
      clearInterval(this.dataTransferProofTimerId);
      this.dataTransferProofTimerId = -1;
    }
  }

  async stopBackgroundTask(): Promise<void> {
    this.isRunning = false;
    this.isCanceledBySystem = false;
    this.retryCount = 0;
    this.stopHeartbeat();
    this.stopDataTransferProof();

    this.websocketService.stopPing();

    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      console.info('[ntfy] Background task stopped');
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[ntfy] Background task stop failed: ${err.code} ${err.message}`);
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();

    this.heartbeatTimerId = setInterval(() => {
      if (!this.isRunning) {
        this.stopHeartbeat();
        return;
      }

      console.info('[ntfy] Background heartbeat tick');

      const healthResults = this.websocketService.healthCheck();
      let unhealthyCount = 0;
      healthResults.forEach((healthy) => {
        if (!healthy) unhealthyCount++;
      });

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

  destroy(): void {
    this.unregisterContinuousTaskCancel();
    this.stopBackgroundTask();
  }
}
