export class Constants {
  static readonly DEFAULT_SERVER = 'https://ntfy.sh';
  static readonly STORAGE_KEY_SUBSCRIPTIONS = 'ntfy_subscriptions';
  static readonly STORAGE_KEY_SETTINGS = 'ntfy_settings';
  static readonly STORAGE_KEY_MESSAGES_PREFIX = 'ntfy_messages_';
  static readonly STORAGE_KEY_DELETED_MSGS_PREFIX = 'ntfy_deleted_msg_';
  static readonly POLL_INTERVAL_MS = 30000;
  static readonly MAX_MESSAGES_PER_TOPIC = 100;

  static readonly PRIORITY_MIN = 1;
  static readonly PRIORITY_LOW = 2;
  static readonly PRIORITY_DEFAULT = 3;
  static readonly PRIORITY_HIGH = 4;
  static readonly PRIORITY_MAX = 5;

  static readonly PRIORITY: number[] = [0, 1, 2, 3, 4, 5];

  static readonly PRIORITY_LABELS: Record<number, string> = {
    1: '最低',
    2: '低',
    3: '普通',
    4: '高',
    5: '最高'
  };

  static readonly PRIORITY_COLORS: Record<number, string> = {
    1: '#FF757575',
    2: '#FF388E3C',
    3: '#FF0078D4',
    4: '#FFF57C00',
    5: '#FFD32F2F'
  };

  // WebSocket settings
  static readonly WS_MAX_RECONNECT_ATTEMPTS = 10;
  static readonly WS_INITIAL_RECONNECT_DELAY = 1000;
  static readonly WS_MAX_RECONNECT_DELAY = 60000;
  static readonly WS_CONNECTION_TIMEOUT = 15000;

  // Notification settings
  static readonly NOTIFICATION_MAX_CACHE_IDS = 200;

  // Background heartbeat / data transfer proof: 30 seconds
  // 系统要求 DATA_TRANSFER 模式下持续60秒内不低于16KB/s
  // 30秒间隔的 HTTP poll + WebSocket keepalive 可满足该要求
  static readonly BACKGROUND_HEARTBEAT_INTERVAL_MS = 30000;
  static readonly DATA_TRANSFER_PROOF_INTERVAL_MS = 30000;

  // 后台任务取消后重新申请延迟（3秒）
  static readonly BACKGROUND_REAPPLY_DELAY_MS = 3000;
}
