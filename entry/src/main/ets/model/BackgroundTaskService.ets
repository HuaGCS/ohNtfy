import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { WebSocketService } from './WebSocketService';
import { Constants } from '../common/Constants';

export class BackgroundTaskService {
  private context: common.UIAbilityContext;
  private websocketService: WebSocketService;
  private pollingTimerId: number = -1;
  private isRunning: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.websocketService = WebSocketService.getInstance();
  }

  async startBackgroundTask(): Promise<void> {
    if (this.isRunning) return;
    this.isRunning = true;

    try {
      // Request continuous task for notification service
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

    this.startHeartbeat();
  }

  async stopBackgroundTask(): Promise<void> {
    this.isRunning = false;
    this.stopHeartbeat();

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
    // Heartbeat every 2 minutes to keep WS connections alive
    this.pollingTimerId = setInterval(() => {
      if (!this.isRunning) {
        this.stopHeartbeat();
        return;
      }
      console.info('[ntfy] Background heartbeat - connections:', this.websocketService.getConnectedCount());
    }, Constants.POLL_INTERVAL_MS * 4);
  }

  private stopHeartbeat(): void {
    if (this.pollingTimerId > 0) {
      clearInterval(this.pollingTimerId);
      this.pollingTimerId = -1;
    }
  }

  isRunningState(): boolean {
    return this.isRunning;
  }
}
