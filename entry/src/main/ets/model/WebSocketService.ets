import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NtfyMessage } from './TopicModel';

export enum ConnectionState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  RECONNECTING = 3,
  ERROR = 4,
  CLOSED = 5,
}

export interface WsStatus {
  server: string;
  topic: string;
  state: ConnectionState;
  lastMessageTime?: number;
  reconnectAttempts: number;
}

export type MessageCallback = (message: NtfyMessage, server: string, topic: string) => void;
export type StatusCallback = (status: WsStatus) => void;

/** 单个 topic 在共享连接上的状态 */
interface TopicState {
  lastMessageTime: number;
}

/** 每台服务器的共享 WS 连接 */
interface WsEntry {
  server: string;
  topics: Map<string, TopicState>; // topic -> state
  ws: webSocket.WebSocket;
  state: ConnectionState;
  reconnectAttempts: number;
  timerId: number;
  lastMessageTime: number; // 该连接收到任意消息的时间
}

export class WebSocketService {
  // key = server URL
  private connections: Map<string, WsEntry> = new Map();
  private onMessageCallbacks: MessageCallback[] = [];
  private onStatusCallback: StatusCallback | null = null;
  private static instance: WebSocketService;

  private static readonly INITIAL_RECONNECT_DELAY_MS = 1000;
  private static readonly MAX_RECONNECT_DELAY_MS = 60000;
  private static readonly CONNECTION_TIMEOUT_MS = 15000;
  // 经过这么多轮尝试后使用最大重连延迟（约8分钟后稳定在60秒一次）
  private static readonly MAX_DELAY_AFTER_ATTEMPTS = 10;
  // 健康检查：连接超过此时间无消息则强制重连（3分钟）
  private static readonly HEALTH_CHECK_IDLE_MS = 3 * 60 * 1000;
  private static readonly PING_INTERVAL_MS = 30000;
  private pingTimerId: number = -1;

  static getInstance(): WebSocketService {
    if (!WebSocketService.instance) {
      WebSocketService.instance = new WebSocketService();
    }
    return WebSocketService.instance;
  }

  /** 启动健康检查定时器（服务端会通过 keepalive 事件保活，我们只做空闲检测） */
  startPing(): void {
    this.stopPing();
    this.pingTimerId = setInterval(() => {
      this.connections.forEach((entry) => {
        if (entry.state === ConnectionState.CONNECTED) {
          const idleTime = Date.now() - entry.lastMessageTime;
          if (idleTime > WebSocketService.HEALTH_CHECK_IDLE_MS && entry.lastMessageTime > 0) {
            console.warn(`[WS] HealthCheck idle ${idleTime}ms, force reconnect ${entry.server}`);
            this.forceReconnect(entry.server);
          }
        }
      });
    }, WebSocketService.PING_INTERVAL_MS);
    console.info('[WS] Health check timer started');
  }

  stopPing(): void {
    if (this.pingTimerId > 0) {
      clearInterval(this.pingTimerId);
      this.pingTimerId = -1;
    }
  }

  /**
   * 健康检查 — 按服务器维度检查
   * 返回 Map<server_topic, healthy>
   */
  healthCheck(): Map<string, boolean> {
    const result = new Map<string, boolean>();
    const now = Date.now();

    this.connections.forEach((entry, serverKey) => {
      const healthy = this.checkConnection(entry, now);
      entry.topics.forEach((_ts, topic) => {
        result.set(`${serverKey}_${topic}`, healthy);
      });
    });
    return result;
  }

  private checkConnection(entry: WsEntry, now: number): boolean {
    if (entry.state === ConnectionState.CONNECTED) {
      const idleTime = now - entry.lastMessageTime;
      if (idleTime > WebSocketService.HEALTH_CHECK_IDLE_MS && entry.lastMessageTime > 0) {
        console.warn(`[WS] HealthCheck: ${entry.server} idle ${idleTime}ms, force reconnect`);
        this.forceReconnect(entry.server);
        return false;
      } else {
        return true;
      }
    } else if (entry.state === ConnectionState.DISCONNECTED ||
      entry.state === ConnectionState.ERROR ||
      entry.state === ConnectionState.CLOSED) {
      console.info(`[WS] HealthCheck: ${entry.server} is disconnected, trigger reconnect`);
      this.forceReconnect(entry.server);
      return false;
    }
    return true;
  }

  /** 获取所有已注册的 (server, topic) key 列表 */
  getAllConnectionKeys(): string[] {
    const keys: string[] = [];
    this.connections.forEach((entry) => {
      entry.topics.forEach((_ts, topic) => {
        keys.push(`${entry.server}_${topic}`);
      });
    });
    return keys;
  }

  /** 获取指定 topic 的空闲时间（毫秒），-1 表示不存在 */
  getIdleTime(server: string, topic: string): number {
    const entry = this.connections.get(server);
    if (!entry) return -1;
    const topicState = entry.topics.get(topic);
    if (!topicState || topicState.lastMessageTime === 0) return -1;
    return Date.now() - topicState.lastMessageTime;
  }

  setOnMessage(callback: MessageCallback | null): void {
    if (callback) {
      if (!this.onMessageCallbacks.includes(callback)) {
        this.onMessageCallbacks.push(callback);
      }
    } else {
      this.onMessageCallbacks = [];
    }
  }

  removeOnMessage(callback: MessageCallback): void {
    const idx = this.onMessageCallbacks.indexOf(callback);
    if (idx >= 0) {
      this.onMessageCallbacks.splice(idx, 1);
    }
  }

  setOnStatusChange(callback: StatusCallback | null): void {
    this.onStatusCallback = callback;
  }

  clearOnMessage(): void {
    this.onMessageCallbacks = [];
  }

  clearOnStatusChange(): void {
    this.onStatusCallback = null;
  }

  /**
   * 连接指定服务器的指定 topic
   * 同一服务器下的 topic 共享一条 WS 连接（URL 逗号分隔）
   */
  connect(server: string, topic: string): void {
    const existingEntry = this.connections.get(server);
    if (existingEntry) {
      // 服务器连接已存在：如果 topic 未注册则注册并重建连接
      if (!existingEntry.topics.has(topic)) {
        existingEntry.topics.set(topic, { lastMessageTime: 0 });
        // topic 列表变了，需要重建连接（URL 中包含所有 topic）
        this.rebuildConnection(existingEntry);
        this.fireStatusForEntry(existingEntry);
      }
      return;
    }
    // 新建服务器连接
    this.createConnection(server, topic);
  }

  /**
   * 批量连接同一服务器的多个 topic（一次性创建，避免逐个重建问题）
   * 用于后台恢复时的批量重连
   */
  connectTopics(server: string, topics: string[]): void {
    if (topics.length === 0) return;

    let entry = this.connections.get(server);
    if (entry) {
      // 已有连接，检查是否有新 topic
      let hasNew = false;
      for (const t of topics) {
        if (!entry.topics.has(t)) {
          entry.topics.set(t, { lastMessageTime: 0 });
          hasNew = true;
        }
      }
      if (hasNew) {
        this.rebuildConnection(entry);
        this.fireStatusForEntry(entry);
      }
      return;
    }
    // 新建连接，一次性注册所有 topic
    entry = {
      server,
      topics: new Map(),
      ws: webSocket.createWebSocket(),
      state: ConnectionState.CONNECTING,
      reconnectAttempts: 0,
      timerId: -1,
      lastMessageTime: 0
    };
    for (const t of topics) {
      entry.topics.set(t, { lastMessageTime: 0 });
    }
    this.connections.set(server, entry);
    this.createConnection(server);
  }

  /** 取消订阅指定 topic */
  disconnect(server: string, topic: string): void {
    const entry = this.connections.get(server);
    if (!entry) return;

    entry.topics.delete(topic);
    this.fireStatusForTopic(server, topic, ConnectionState.DISCONNECTED, 0);

    // 无更多 topic → 关闭连接
    if (entry.topics.size === 0) {
      this.closeEntry(entry);
      this.connections.delete(server);
    } else {
      // 还有 topic，重建连接（URL 中移除该 topic）
      this.rebuildConnection(entry);
    }
  }

  /** 断开所有连接 */
  disconnectAll(): void {
    this.connections.forEach((entry) => {
      this.closeEntry(entry);
    });
    this.connections.clear();
    this.stopPing();
  }

  /** 获取连接状态（以 topic 粒度返回，实际取的是服务器连接状态） */
  getState(server: string, topic: string): ConnectionState {
    const entry = this.connections.get(server);
    if (!entry || !entry.topics.has(topic)) return ConnectionState.DISCONNECTED;
    return entry.state;
  }

  /** 获取当前已连接的服务器数量 */
  /** 强制重连所有服务器（用于前台恢复） */
  reconnectAll(): void {
    // 清除所有现有连接状态，准备重建
    this.connections.forEach((entry) => {
      if (entry.timerId > 0) {
        clearTimeout(entry.timerId);
        entry.timerId = -1;
      }
      try {
        entry.ws.close((_err: BusinessError) => {});
      } catch (_e) {
        // ignore
      }
    });
    this.connections.clear();
    console.info('[WS] All connections cleared for fresh reconnect');
  }

  getConnectedCount(): number {
    let count = 0;
    this.connections.forEach((entry) => {
      if (entry.state === ConnectionState.CONNECTED) count++;
    });
    return count;
  }

  /** 获取所有 topic 粒度的状态 */
  getAllStatus(): WsStatus[] {
    const result: WsStatus[] = [];
    this.connections.forEach((entry) => {
      entry.topics.forEach((ts, topic) => {
        result.push({
          server: entry.server,
          topic: topic,
          state: entry.state,
          lastMessageTime: ts.lastMessageTime,
          reconnectAttempts: entry.reconnectAttempts
        });
      });
    });
    return result;
  }

  /**
   * 强制重连指定服务器（所有 topic 一起恢复）
   * topic 参数保留仅用于接口兼容
   */
  forceReconnect(server: string, _topic?: string): void {
    const entry = this.connections.get(server);
    if (!entry) return;

    this.closeEntry(entry);
    this.createConnection(server);
  }

  // ──────────── 内部方法 ────────────

  private rebuildConnection(entry: WsEntry): void {
    this.closeEntry(entry);
    this.createConnection(entry.server);
  }

  /**
   * 构造 WS URL：ws://server/topic1,topic2/ws
   * 当 topics 为空时返回 null
   */
  private buildUrl(entry: WsEntry): string | null {
    const topics: string[] = [];
    entry.topics.forEach((_ts, topic) => {
      topics.push(topic);
    });
    if (topics.length === 0) return null;

    const wsBase = entry.server.replace(/^http:/, 'ws:').replace(/^https:/, 'wss:');
    return `${wsBase}/${topics.join(',')}/ws`;
  }

  /**
   * 创建到服务器的 WS 共享连接
   * @param server 服务器地址
   * @param firstTopic 第一个 topic（新建连接时为必填；重建时省略从现有 topics 继承）
   */
  private createConnection(server: string, firstTopic?: string): void {
    let entry = this.connections.get(server);
    if (!entry) {
      // 首次创建
      entry = {
        server,
        topics: new Map(),
        ws: webSocket.createWebSocket(),
        state: ConnectionState.CONNECTING,
        reconnectAttempts: 0,
        timerId: -1,
        lastMessageTime: 0
      };
      if (firstTopic) {
        entry.topics.set(firstTopic, { lastMessageTime: 0 });
      }
      this.connections.set(server, entry);
    } else {
      // 重建：保留已有 topics，用新的 WebSocket 对象
      if (entry.timerId > 0) {
        clearTimeout(entry.timerId);
        entry.timerId = -1;
      }
      try {
        entry.ws.close((_err: BusinessError) => {});
      } catch (_e) {
        // ignore
      }
      entry.ws = webSocket.createWebSocket();
      entry.state = ConnectionState.CONNECTING;
      entry.lastMessageTime = 0;
    }

    // 构造 URL
    const url = this.buildUrl(entry);
    if (!url) {
      console.warn(`[WS] No topics for ${server}, skip connection`);
      return;
    }

    this.fireStatusForEntry(entry);
    const connKey = server;

    let isResolved = false;

    // ── message ──
    entry.ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err) {
        console.error(`[WS] message error: ${err.message}`);
        return;
      }
      const currentEntry = this.connections.get(connKey);
      if (!currentEntry) return;

      const text = typeof value === 'string' ? value : value.toString();
      try {
        const msg = JSON.parse(text) as NtfyMessage;
        const now = Date.now();

        if (msg.event === 'keepalive') {
          // 心跳保活，仅更新时间戳
          currentEntry.lastMessageTime = now;
          return;
        }

        if (msg.event === 'message' && msg.topic) {
          currentEntry.lastMessageTime = now;

          // 更新对应 topic 的状态
          const topicState = currentEntry.topics.get(msg.topic);
          if (topicState) {
            topicState.lastMessageTime = now;
          } else {
            // 收到未注册 topic 的消息，忽略
            return;
          }

          // 路由给回调
          for (const cb of this.onMessageCallbacks) {
            cb(msg, server, msg.topic);
          }
        }
        // event === 'open' 忽略（open 事件已由 on('open') 处理）
      } catch (_e) {
        // ignore non-JSON frames
      }
    });

    // ── open ──
    entry.ws.on('open', (_err: BusinessError, _value: Object) => {
      isResolved = true;
      const currentEntry = this.connections.get(connKey);
      if (!currentEntry) return;

      currentEntry.state = ConnectionState.CONNECTED;
      currentEntry.reconnectAttempts = 0;
      currentEntry.lastMessageTime = Date.now();
      this.fireStatusForEntry(currentEntry);
      console.info(`[WS] connected: ${server}`);
    });

    // ── close ──
    entry.ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (!isResolved) {
        isResolved = true;
      }
      if (!this.connections.has(connKey)) return;
      console.info(`[WS] closed: ${server} code=${value.code} reason=${value.reason}`);
      const currentEntry = this.connections.get(connKey);
      if (currentEntry) {
        this.scheduleReconnect(currentEntry);
      }
    });

    // ── error ──
    entry.ws.on('error', (err: BusinessError) => {
      if (!isResolved) {
        isResolved = true;
      }
      const currentEntry = this.connections.get(connKey);
      if (!currentEntry) return;
      currentEntry.state = ConnectionState.ERROR;
      this.fireStatusForEntry(currentEntry);
      console.error(`[WS] error: ${server} msg=${err.message}`);
      this.scheduleReconnect(currentEntry);
    });

    // ── connect ──
    entry.ws.connect(url, (err: BusinessError, _value: boolean) => {
      if (err) {
        if (!isResolved) {
          isResolved = true;
        }
        const currentEntry = this.connections.get(connKey);
        if (!currentEntry) return;
        currentEntry.state = ConnectionState.ERROR;
        this.fireStatusForEntry(currentEntry);
        this.scheduleReconnect(currentEntry);
      }
    });

    // ── 连接超时 ──
    setTimeout(() => {
      if (!isResolved) {
        isResolved = true;
        const currentEntry = this.connections.get(connKey);
        if (!currentEntry) return;
        try {
          currentEntry.ws.close((_err: BusinessError) => {});
        } catch (_e) {
          // ignore
        }
        currentEntry.state = ConnectionState.ERROR;
        this.fireStatusForEntry(currentEntry);
        this.scheduleReconnect(currentEntry);
      }
    }, WebSocketService.CONNECTION_TIMEOUT_MS);
  }

  private scheduleReconnect(entry: WsEntry): void {
    if (!this.connections.has(entry.server)) return;

    entry.reconnectAttempts++;
    entry.state = ConnectionState.RECONNECTING;
    this.fireStatusForEntry(entry);

    // 指数退避
    let delay: number;
    if (entry.reconnectAttempts <= WebSocketService.MAX_DELAY_AFTER_ATTEMPTS) {
      delay = Math.min(
        WebSocketService.INITIAL_RECONNECT_DELAY_MS * Math.pow(2, entry.reconnectAttempts - 1),
        WebSocketService.MAX_RECONNECT_DELAY_MS
      );
    } else {
      delay = WebSocketService.MAX_RECONNECT_DELAY_MS;
    }

    console.info(`[WS] scheduleReconnect: ${entry.server} attempt=${entry.reconnectAttempts} delay=${delay}ms`);

    const server = entry.server;
    const timerId = setTimeout(() => {
      if (!this.connections.has(server)) return;
      this.createConnection(server);
    }, delay);

    entry.timerId = timerId;
  }

  /** 安全关闭一条连接 */
  private closeEntry(entry: WsEntry): void {
    if (entry.timerId > 0) {
      clearTimeout(entry.timerId);
      entry.timerId = -1;
    }
    try {
      entry.ws.close((_err: BusinessError) => {});
    } catch (_e) {
      // ignore
    }
    entry.state = ConnectionState.DISCONNECTED;
  }

  /** 广播服务器下所有 topic 的状态 */
  private fireStatusForEntry(entry: WsEntry): void {
    const cb = this.onStatusCallback;
    if (!cb) return;
    entry.topics.forEach((ts, topic) => {
      cb({
        server: entry.server,
        topic: topic,
        state: entry.state,
        lastMessageTime: ts.lastMessageTime,
        reconnectAttempts: entry.reconnectAttempts
      });
    });
  }

  /** 广播单个 topic 的状态变化 */
  private fireStatusForTopic(server: string, topic: string, state: ConnectionState, attempts: number): void {
    if (!this.onStatusCallback) return;
    this.onStatusCallback({
      server,
      topic,
      state,
      reconnectAttempts: attempts
    });
  }
}
