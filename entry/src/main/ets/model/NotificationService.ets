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
      const msgId = message.id;
      const baseWant: Want = {
        bundleName: this.bundleName,
        abilityName: 'EntryAbility',
        parameters: { 'topic': topic, 'server': server }
      };
      const markReadWant: Want = {
        bundleName: this.bundleName,
        abilityName: 'EntryAbility',
        parameters: { 'topic': topic, 'server': server, 'action': 'markRead', 'messageId': msgId }
      };
      const dismissWant: Want = {
        bundleName: this.bundleName,
        abilityName: 'EntryAbility',
        parameters: { 'topic': topic, 'server': server, 'action': 'dismiss', 'messageId': msgId }
      };

      const clickAgent = await wantAgent.getWantAgent({
        wants: [baseWant],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: this.hashCode(msgId),
      });
      const markReadAgent = await wantAgent.getWantAgent({
        wants: [markReadWant],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: this.hashCode(msgId + '_read'),
      });
      const dismissAgent = await wantAgent.getWantAgent({
        wants: [dismissWant],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: this.hashCode(msgId + '_dismiss'),
      });

      const priority = message.priority ?? Constants.PRIORITY_DEFAULT;
      const isHighPri = priority >= Constants.PRIORITY_HIGH;
      const slotType = isHighPri
        ? notificationManager.SlotType.SOCIAL_COMMUNICATION
        : notificationManager.SlotType.SERVICE_INFORMATION;

      const title = message.title || topic;
      const text = message.message || '';
      const tags = message.tags ? message.tags.map(t => `:${t}:`).join(' ') : '';

      // 构建通知时更新角标数
      const activeNotifications = await notificationManager.getActiveNotificationCount().catch(() => 0);
      const badgeNumber = activeNotifications + 1;

      const notificationRequest: notificationManager.NotificationRequest = {
        id: this.hashCode(msgId),
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
        wantAgent: clickAgent,
        groupName: `${server}_${topic}`,
        badgeNumber: badgeNumber > 99 ? 99 : badgeNumber,
        // 高优先级消息点击后保留通知（标记已读后才消失）
        tapDismissed: !isHighPri,
        actionButtons: [
          {
            title: '标记已读',
            wantAgent: markReadAgent
          },
          {
            title: '忽略',
            wantAgent: dismissAgent
          }
        ]
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
