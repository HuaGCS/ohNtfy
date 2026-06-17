import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NtfyMessage } from './TopicModel';
import { Constants } from '../common/Constants';

interface NotificationSlot {
  slotType: notificationManager.SlotType;
  level: number;
  desc: string;
  vibrationEnabled: boolean;
}

export class NotificationService {
  private context: common.UIAbilityContext;
  private bundleName: string;
  private notifiedIds: Set<string> = new Set();
  private static readonly MAX_NOTIFIED_CACHE = 200;
  // 常驻占位通知 ID（用于指示后台服务正在运行）
  private static readonly PLACEHOLDER_NOTIFICATION_ID = 0x7FFFFFFF;
  private isPlaceholderShowing: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.bundleName = context.abilityInfo.bundleName;
  }

  async initialize(): Promise<void> {
    try {
      // Add notification slots for different priority levels
      const slots: NotificationSlot[] = [
        {
          slotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
          level: 4,
          desc: '高优先级通知',
          vibrationEnabled: true
        },
        {
          slotType: notificationManager.SlotType.SERVICE_INFORMATION,
          level: 3,
          desc: '普通优先级通知',
          vibrationEnabled: false
        }
      ];

      for (const slot of slots) {
        try {
          await notificationManager.addSlot(slot.slotType);
        } catch (e) {
          // Slot may already exist, ignore
        }
      }

      await notificationManager.requestEnableNotification(this.context);
    } catch (e) {
      console.error('Failed to init notifications:', (e as BusinessError).message);
    }
  }

  async showNotification(message: NtfyMessage, server: string, topic: string): Promise<void> {
    // 避免重复通知
    if (this.notifiedIds.has(message.id)) return;

    try {
      const wantParams: Record<string, string> = {
        'topic': topic,
        'server': server
      };
      const want: Want = {
        bundleName: this.bundleName,
        abilityName: 'EntryAbility',
        parameters: wantParams
      };
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: this.hashCode(message.id),
      };
      const agent = await wantAgent.getWantAgent(wantAgentInfo);

      const priority = message.priority ?? Constants.PRIORITY_DEFAULT;
      const isHighPri = priority >= Constants.PRIORITY_HIGH;
      const slotType = isHighPri
        ? notificationManager.SlotType.SOCIAL_COMMUNICATION
        : notificationManager.SlotType.SERVICE_INFORMATION;

      const title = message.title || topic;
      const text = message.message || '';
      const tags = message.tags ? message.tags.map(t => `:${t}:`).join(' ') : '';

      const notificationRequest: notificationManager.NotificationRequest = {
        id: this.hashCode(message.id),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text,
            additionalText: tags || `${server}/${topic}`
          }
        } as notificationManager.NotificationContent,
        notificationSlotType: slotType,
        showDeliveryTime: true,
        wantAgent: agent,
        groupName: `${server}_${topic}`
      };

      await notificationManager.publish(notificationRequest);

      // 仅在发布成功后标记为已通知，防止失败后永久跳过
      this.notifiedIds.add(message.id);
      while (this.notifiedIds.size > NotificationService.MAX_NOTIFIED_CACHE) {
        const first = this.notifiedIds.values().next().value as string;
        this.notifiedIds.delete(first);
      }
    } catch (e) {
      console.error('Failed to show notification:', (e as BusinessError).message);
    }
  }

  async showGroupSummary(server: string, topic: string, count: number): Promise<void> {
    try {
      const groupKey = `${server}_${topic}`;
      const notificationRequest: notificationManager.NotificationRequest = {
        id: this.hashCode(`summary_${groupKey}`),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: topic,
            text: `${count} 条新消息`,
            additionalText: server
          }
        } as notificationManager.NotificationContent,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        showDeliveryTime: false,
        groupName: groupKey
      };
      await notificationManager.publish(notificationRequest);
    } catch (e) {
      console.error('Failed to show summary:', (e as BusinessError).message);
    }
  }

  async cancelNotification(messageId: string): Promise<void> {
    try {
      await notificationManager.cancel(this.hashCode(messageId));
      this.notifiedIds.delete(messageId);
    } catch (e) {
      console.error('Failed to cancel notification:', (e as BusinessError).message);
    }
  }

  async cancelTopicNotifications(server: string, topic: string): Promise<void> {
    const groupName = `${server}_${topic}`;
    try {
      await notificationManager.cancelGroup(groupName);
      await notificationManager.cancel(this.hashCode(`summary_${groupName}`));
    } catch (e) {
      console.error('Failed to cancel topic notifications:', (e as BusinessError).message);
    }
  }

  async cancelAll(): Promise<void> {
    try {
      await notificationManager.cancelAll();
      this.notifiedIds.clear();
    } catch (e) {
      console.error('Failed to cancel all notifications:', (e as BusinessError).message);
    }
  }

  isAlreadyNotified(messageId: string): boolean {
    return this.notifiedIds.has(messageId);
  }

  clearNotifiedIds(): void {
    this.notifiedIds.clear();
  }

  /**
   * 发布常驻占位通知，告知用户 ntfy 正在后台运行
   * 系统对有关联常驻通知的后台进程会降低挂起优先级
   */
  async publishPlaceholder(topicCount: number, connectedCount: number): Promise<void> {
    try {
      const notificationRequest: notificationManager.NotificationRequest = {
        id: NotificationService.PLACEHOLDER_NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'ntfy 正在后台运行',
            text: `${topicCount} 个订阅 · ${connectedCount} 个连接`,
            additionalText: '正在监听推送通知...'
          }
        } as notificationManager.NotificationContent,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        showDeliveryTime: false,
        tapDismissed: false  // 点击不自动清除（未携带 wantAgent 时也保留）
      };

      // isOngoing 和 isUnremovable 在 API 24 中为预留字段（暂未支持）
      await notificationManager.publish(notificationRequest);
      this.isPlaceholderShowing = true;
      console.info('[ntfy] Placeholder notification published');
    } catch (e) {
      console.error('[ntfy] Failed to publish placeholder notification:', (e as BusinessError).message);
    }
  }

  /**
   * 更新常驻通知内容（如连接数变化）
   */
  async updatePlaceholder(topicCount: number, connectedCount: number): Promise<void> {
    if (!this.isPlaceholderShowing) return;
    await this.publishPlaceholder(topicCount, connectedCount);
  }

  /**
   * 取消常驻占位通知
   */
  async cancelPlaceholder(): Promise<void> {
    if (!this.isPlaceholderShowing) return;
    try {
      await notificationManager.cancel(NotificationService.PLACEHOLDER_NOTIFICATION_ID);
      this.isPlaceholderShowing = false;
      console.info('[ntfy] Placeholder notification cancelled');
    } catch (e) {
      console.error('[ntfy] Failed to cancel placeholder notification:', (e as BusinessError).message);
    }
  }

  /**
   * 查询常驻通知是否正在显示
   */
  isPlaceholderActive(): boolean {
    return this.isPlaceholderShowing;
  }

  private hashCode(str: string): number {
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i);
      hash = ((hash << 5) - hash) + char;
      hash = hash & hash;
    }
    return Math.abs(hash);
  }
}
