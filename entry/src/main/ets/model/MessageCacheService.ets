import { NtfyMessage } from './TopicModel';
import { StorageManager } from './StorageManager';
import { Constants } from '../common/Constants';

export class MessageCacheService {
  private storage: StorageManager;
  private memoryCache: Map<string, NtfyMessage[]> = new Map();
  private initialized: boolean = false;

  constructor(storage: StorageManager) {
    this.storage = storage;
  }

  async initialize(server: string, topic: string): Promise<void> {
    if (this.initialized) {
      // Individual topic init
      await this.loadFromDisk(server, topic);
      return;
    }
    this.initialized = true;
  }

  async getMessages(server: string, topic: string): Promise<NtfyMessage[]> {
    const key = this.cacheKey(server, topic);
    let messages: NtfyMessage[];
    if (this.memoryCache.has(key)) {
      messages = [...this.memoryCache.get(key)!];
    } else {
      messages = await this.loadFromDisk(server, topic);
    }
    // 过滤已删除的消息
    return this.filterDeleted(server, topic, messages);
  }

  async addMessages(server: string, topic: string, messages: NtfyMessage[]): Promise<NtfyMessage[]> {
    const key = this.cacheKey(server, topic);
    let existing = this.memoryCache.get(key) ?? [];

    const existingIds = new Set(existing.map(m => m.id));
    const deletedIds = await this.getDeletedIds(server, topic);
    // 过滤已删除的消息
    const newMessages = messages.filter(m => !existingIds.has(m.id) && !deletedIds.has(m.id));

    if (newMessages.length === 0) return [...existing];

    existing = [...newMessages, ...existing];
    existing.sort((a, b) => b.time - a.time);

    if (existing.length > Constants.MAX_MESSAGES_PER_TOPIC) {
      existing = existing.slice(0, Constants.MAX_MESSAGES_PER_TOPIC);
    }

    this.memoryCache.set(key, existing);
    await this.saveToDisk(server, topic, existing);
    return [...existing];
  }

  async getUnreadCount(server: string, topic: string, lastReadId?: string): Promise<number> {
    const messages = await this.getMessages(server, topic);
    if (!lastReadId) return messages.length;

    const lastReadIndex = messages.findIndex(m => m.id === lastReadId);
    if (lastReadIndex === -1) return messages.length;
    return messages.filter((_, idx) => idx < lastReadIndex).length;
  }

  async clearTopic(server: string, topic: string): Promise<void> {
    const key = this.cacheKey(server, topic);
    this.memoryCache.delete(key);
    try {
      await this.storage.saveMessages(server, topic, '[]');
    } catch (e) {
      console.error('Failed to clear message cache:', e);
    }
  }

  async removeMessage(server: string, topic: string, messageId: string): Promise<void> {
    const key = this.cacheKey(server, topic);
    let existing = this.memoryCache.get(key);
    if (!existing) {
      existing = await this.loadFromDisk(server, topic);
    }
    const updated = existing.filter(m => m.id !== messageId);
    this.memoryCache.set(key, updated);
    // 持久化记录已删除的消息 ID，防止重新拉取后再次出现
    await this.recordDeletedId(server, topic, messageId);
    try {
      const json = JSON.stringify(updated);
      await this.storage.saveMessages(server, topic, json);
    } catch (e) {
      console.error('Failed to remove message from cache:', e);
    }
  }

  /** 获取该 topic 下已删除的消息 ID 集合 */
  async getDeletedIds(server: string, topic: string): Promise<Set<string>> {
    try {
      const key = this.deletedKey(server, topic);
      const json = await this.storage.loadSetting(key, '[]');
      const ids = JSON.parse(json) as string[];
      return new Set(ids);
    } catch (e) {
      return new Set();
    }
  }

  /** 持久化记录一条删除的消息 ID */
  private async recordDeletedId(server: string, topic: string, messageId: string): Promise<void> {
    try {
      const ids = await this.getDeletedIds(server, topic);
      ids.add(messageId);
      const key = this.deletedKey(server, topic);
      const json = JSON.stringify(Array.from(ids));
      await this.storage.saveSetting(key, json);
    } catch (e) {
      console.error('Failed to record deleted message ID:', e);
    }
  }

  /** 过滤掉已删除的消息 */
  private async filterDeleted(server: string, topic: string, messages: NtfyMessage[]): Promise<NtfyMessage[]> {
    const deletedIds = await this.getDeletedIds(server, topic);
    if (deletedIds.size === 0) return messages;
    return messages.filter(m => !deletedIds.has(m.id));
  }

  private deletedKey(server: string, topic: string): string {
    return `${Constants.STORAGE_KEY_DELETED_MSGS_PREFIX}${server}_${topic}`;
  }

  clearAll(): void {
    this.memoryCache.clear();
  }

  private async loadFromDisk(server: string, topic: string): Promise<NtfyMessage[]> {
    try {
      const json = await this.storage.loadMessages(server, topic);
      const messages = JSON.parse(json) as NtfyMessage[];
      const key = this.cacheKey(server, topic);
      this.memoryCache.set(key, messages);
      return [...messages];
    } catch (e) {
      return [];
    }
  }

  private async saveToDisk(server: string, topic: string, messages: NtfyMessage[]): Promise<void> {
    try {
      const json = JSON.stringify(messages);
      await this.storage.saveMessages(server, topic, json);
    } catch (e) {
      console.error('Failed to save message cache:', e);
    }
  }

  private cacheKey(server: string, topic: string): string {
    return `${server}_${topic}`;
  }
}
