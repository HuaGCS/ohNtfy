export interface TopicSubscription {
  id: string;
  server: string;
  topic: string;
  displayName: string;
  subscribedAt: number;
  lastMessage?: NtfyMessage;
  lastReadId?: string;
}

/** ntfy 操作按钮 */
export interface NtfyAction {
  action: 'view' | 'http' | 'broadcast';
  label: string;
  url?: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  clear?: boolean;
  intent?: string;
  extras?: Record<string, string>;
}

/** ntfy 附件信息 */
export interface NtfyAttachment {
  name: string;
  url: string;
  type?: string;
  size?: number;
  expires?: number;
}

export interface NtfyMessage {
  id: string;
  time: number;
  event: string;
  topic: string;
  title?: string;
  message?: string;
  priority?: number;
  tags?: string[];
  click?: string;
  icon?: string;
  attachment?: NtfyAttachment;
  actions?: NtfyAction[];
  expires?: number;
}

export interface NtfyPublishRequest {
  topic: string;
  message?: string;
  title?: string;
  priority?: number;
  tags?: string[];
  click?: string;
  actions?: NtfyAction[];
  attach?: string;
  filename?: string;
  delay?: string;
  markdown?: boolean;
}

export class SubscriptionManager {
  private subscriptions: TopicSubscription[] = [];

  getSubscriptions(): TopicSubscription[] {
    return [...this.subscriptions];
  }

  addSubscription(sub: TopicSubscription): void {
    const existing = this.subscriptions.findIndex(
      s => s.server === sub.server && s.topic === sub.topic
    );
    if (existing >= 0) {
      this.subscriptions[existing] = sub;
    } else {
      this.subscriptions.unshift(sub);
    }
  }

  removeSubscription(server: string, topic: string): void {
    this.subscriptions = this.subscriptions.filter(
      s => !(s.server === server && s.topic === topic)
    );
  }

  getSubscription(server: string, topic: string): TopicSubscription | undefined {
    return this.subscriptions.find(
      s => s.server === server && s.topic === topic
    );
  }

  updateLastMessage(server: string, topic: string, message: NtfyMessage): void {
    const idx = this.subscriptions.findIndex(
      s => s.server === server && s.topic === topic
    );
    if (idx >= 0) {
      // 不可变替换：创建新对象以触发 ArkUI @State / ForEach 变化检测
      const old = this.subscriptions[idx];
      this.subscriptions[idx] = {
        id: old.id,
        server: old.server,
        topic: old.topic,
        displayName: old.displayName,
        subscribedAt: old.subscribedAt,
        lastMessage: message,
        lastReadId: old.lastReadId
          ?? old.lastMessage?.id
          ?? ''   // 无历史消息时标记为全未读
      };
    }
  }

  clearLastMessage(server: string, topic: string): void {
    const idx = this.subscriptions.findIndex(
      s => s.server === server && s.topic === topic
    );
    if (idx >= 0) {
      const old = this.subscriptions[idx];
      this.subscriptions[idx] = {
        id: old.id,
        server: old.server,
        topic: old.topic,
        displayName: old.displayName,
        subscribedAt: old.subscribedAt,
        lastMessage: undefined,
        lastReadId: undefined
      };
    }
  }

  markRead(server: string, topic: string): void {
    const idx = this.subscriptions.findIndex(
      s => s.server === server && s.topic === topic
    );
    if (idx >= 0) {
      const old = this.subscriptions[idx];
      const newReadId = old.lastMessage?.id;
      console.info(`[SubscriptionManager] markRead: ${topic}, lastMsgId=${newReadId}, old.lastReadId=${old.lastReadId}`);
      this.subscriptions[idx] = {
        id: old.id,
        server: old.server,
        topic: old.topic,
        displayName: old.displayName,
        subscribedAt: old.subscribedAt,
        lastMessage: old.lastMessage,
        lastReadId: newReadId
      };
    } else {
      console.warn(`[SubscriptionManager] markRead: subscription not found: ${server}/${topic}`);
    }
  }

  isUnread(server: string, topic: string): boolean {
    const sub = this.subscriptions.find(
      s => s.server === server && s.topic === topic
    );
    if (!sub || !sub.lastMessage) return false;
    return sub.lastMessage.id !== sub.lastReadId;
  }

  fromJSON(json: string): void {
    try {
      this.subscriptions = JSON.parse(json);
    } catch (e) {
      this.subscriptions = [];
    }
  }

  toJSON(): string {
    return JSON.stringify(this.subscriptions);
  }
}
