import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NtfyMessage } from './TopicModel';
import { Constants } from '../common/Constants';

export class NotificationService {
  private bundleName: string;
  private notifiedIds: Set<string> = new Set();
  private static readonly MAX_NOTIFIED_CACHE = 200;

  constructor(bundleName: string) {
    this.bundleName = bundleName;
  }

  async initialize(): Promise<void> {
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
    } catch (e) {
      console.error('Failed to init notification slots:', (e as BusinessError).message);
    }
  }

  async showNotification(message: NtfyMessage, server: string, topic: string): Promise<void> {
    if (this.notifiedIds.has(message.id)) return;
    if (message.event !== 'message') return;

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

      this.notifiedIds.add(message.id);
      while (this.notifiedIds.size > NotificationService.MAX_NOTIFIED_CACHE) {
        const first = this.notifiedIds.values().next().value as string;
        this.notifiedIds.delete(first);
      }
    } catch (e) {
      console.error('Failed to show notification:', (e as BusinessError).message);
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
