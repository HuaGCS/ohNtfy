import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';

export class StorageManager {
  private prefs: preferences.Preferences | null = null;

  async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, 'ntfy_preferences');
    } catch (e) {
      console.error('Failed to initialize preferences:', (e as BusinessError).message);
    }
  }

  async saveSubscriptions(json: string): Promise<void> {
    if (!this.prefs) return;
    try {
      await this.prefs.put(Constants.STORAGE_KEY_SUBSCRIPTIONS, json);
      await this.prefs.flush();
    } catch (e) {
      console.error('Failed to save subscriptions:', (e as BusinessError).message);
    }
  }

  async loadSubscriptions(): Promise<string> {
    if (!this.prefs) return '[]';
    try {
      return (await this.prefs.get(Constants.STORAGE_KEY_SUBSCRIPTIONS, '[]')) as string;
    } catch (e) {
      console.error('Failed to load subscriptions:', (e as BusinessError).message);
      return '[]';
    }
  }

  async saveMessages(server: string, topic: string, messagesJson: string): Promise<void> {
    if (!this.prefs) return;
    const key = `${Constants.STORAGE_KEY_MESSAGES_PREFIX}${server}_${topic}`;
    try {
      await this.prefs.put(key, messagesJson);
      await this.prefs.flush();
    } catch (e) {
      console.error('Failed to save messages:', (e as BusinessError).message);
    }
  }

  async loadMessages(server: string, topic: string): Promise<string> {
    if (!this.prefs) return '[]';
    const key = `${Constants.STORAGE_KEY_MESSAGES_PREFIX}${server}_${topic}`;
    try {
      return (await this.prefs.get(key, '[]')) as string;
    } catch (e) {
      console.error('Failed to load messages:', (e as BusinessError).message);
      return '[]';
    }
  }

  async saveSetting(key: string, value: string): Promise<void> {
    if (!this.prefs) return;
    try {
      await this.prefs.put(key, value);
      await this.prefs.flush();
    } catch (e) {
      console.error('Failed to save setting:', (e as BusinessError).message);
    }
  }

  async loadSetting(key: string, defaultValue: string): Promise<string> {
    if (!this.prefs) return defaultValue;
    try {
      return (await this.prefs.get(key, defaultValue)) as string;
    } catch (e) {
      console.error('Failed to load setting:', (e as BusinessError).message);
      return defaultValue;
    }
  }
}
