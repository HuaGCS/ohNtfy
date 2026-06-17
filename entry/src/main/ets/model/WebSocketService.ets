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

interface WsEntry {
  server: string;
  topic: string;
  ws: webSocket.WebSocket;
  state: ConnectionState;
  reconnectAttempts: number;
  timerId: number;
  lastMessageTime: number;
}

export class WebSocketService {
  private connections: Map<string, WsEntry> = new Map();
  private onMessageCallbacks: MessageCallback[] = [];
  private onStatusCallback: StatusCallback | null = null;
  private static instance: WebSocketService;

  // 无限重连：移除固定次数限制，使用指数退避+最大延迟
  private static readonly INITIAL_RECONNECT_DELAY_MS = 1000;
  private static readonly MAX_RECONNECT_DELAY_MS = 60000;
  private static readonly CONNECTION_TIMEOUT_MS = 15000;
  // 经过这么多轮尝试后使用最大重连延迟（约8分钟后稳定在60秒一次）
  private static readonly MAX_DELAY_AFTER_ATTEMPTS = 10;
  // 健康检查：超过此时间无消息则认为连接可能失活（10分钟）
  private static readonly HEALTH_CHECK_IDLE_MS = 10 * 60 * 1000;
  // WebSocket ping 间隔
  private static readonly PING_INTERVAL_MS = 120000;
  private pingTimerId: number = -1;

  static getInstance(): WebSocketService {
    if (!WebSocketService.instance) {
      WebSocketService.instance = new WebSocketService();
    }
    return WebSocketService.instance;
  }

  /**
   * 启动全局 Ping 定时器，对所有已连接的 WebSocket 发送 ping
   */
  startPing(): void {
    this.stopPing();
    this.pingTimerId = setInterval(() => {
      this.pingAll();
    }, WebSocketService.PING_INTERVAL_MS);
    console.info('[WS] Ping timer started');
  }

  stopPing(): void {
    if (this.pingTimerId > 0) {
      clearInterval(this.pingTimerId);
      this.pingTimerId = -1;
    }
  }

  /**
   * 对所有已连接（非正在重连中）的连接执行健康检查。
   * - 如果超过 HEALTH_CHECK_IDLE_MS 未收到消息，强制断开重连
   * - 对正常连接发送一个 ping 帧保活
   */
  healthCheck(): Map<string, boolean> {
    const result = new Map<string, boolean>();
    const now = Date.now();

    this.connections.forEach((entry, key) => {
      // 只检查应该连接状态的条目（CONNECTED 或正在重试中）
      if (entry.state === ConnectionState.CONNECTED) {
        const idleTime = now - entry.lastMessageTime;
        if (idleTime > WebSocketService.HEALTH_CHECK_IDLE_MS && entry.lastMessageTime > 0) {
          console.warn(`[WS] HealthCheck: ${entry.server}/${entry.topic} idle ${idleTime}ms, force reconnect`);
          this.forceReconnect(entry.server, entry.topic);
          result.set(key, false);
        } else {
          // 发送 ping 帧保活（写一个空帧或ping控制帧）
          this.sendPing(entry);
          result.set(key, true);
        }
      } else if (entry.state === ConnectionState.DISCONNECTED ||
        entry.state === ConnectionState.ERROR ||
        entry.state === ConnectionState.CLOSED) {
        // 应该连接但断开了，触发重连
        console.info(`[WS] HealthCheck: ${entry.server}/${entry.topic} is disconnected, trigger reconnect`);
        this.forceReconnect(entry.server, entry.topic);
        result.set(key, false);
      }
    });
    return result;
  }

  private sendPing(entry: WsEntry): void {
    try {
      // 发送一个空的文本帧作为 ping (ntfy server 会忽略它)
      entry.ws.send('{"event":"ping"}');
    } catch (_e) {
      // 如果发送失败，会触发 error 事件走重连流程
    }
  }

  private pingAll(): void {
    this.connections.forEach(entry => {
      if (entry.state === ConnectionState.CONNECTED) {
        this.sendPing(entry);
      }
    });
  }

  /**
   * 强制重新连接指定订阅
   */
  forceReconnect(server: string, topic: string): void {
    const key = this.makeKey(server, topic);
    const entry = this.connections.get(key);
    if (!entry) return;

    this.stopReconnect(entry);
    try {
      entry.ws.close(() => {});
    } catch (_e) {
      // ignore
    }

    // 保留 entry 记录，重新创建连接（从 attempt=0 开始）
    this.createConnection(server, topic, 0);
  }

  /**
   * 获取所有已注册的 key 列表（用于健康检查遍历）
   */
  getAllConnectionKeys(): string[] {
    return Array.from(this.connections.keys());
  }

  /**
   * 获取指定连接的空闲时间（毫秒），-1 表示不存在
   */
  getIdleTime(server: string, topic: string): number {
    const entry = this.connections.get(this.makeKey(server, topic));
    if (!entry || entry.lastMessageTime === 0) return -1;
    return Date.now() - entry.lastMessageTime;
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

  connect(server: string, topic: string): void {
    const key = this.makeKey(server, topic);
    const existing = this.connections.get(key);
    if (existing && (existing.state === ConnectionState.CONNECTED ||
      existing.state === ConnectionState.CONNECTING)) {
      return;
    }
    if (existing) {
      this.disconnect(server, topic);
    }
    this.createConnection(server, topic, 0);
  }

  disconnect(server: string, topic: string): void {
    const key = this.makeKey(server, topic);
    const entry = this.connections.get(key);
    if (!entry) return;
    this.stopReconnect(entry);
    try {
      entry.ws.close((_e: BusinessError) => {});
    } catch (_e) {
      // ignore close errors
    }
    this.connections.delete(key);
    this.updateState(server, topic, ConnectionState.DISCONNECTED, 0);
  }

  disconnectAll(): void {
    this.connections.forEach((entry, key) => {
      this.stopReconnect(entry);
      try {
        entry.ws.close(() => {});
      } catch (_e) {
        // ignore
      }
    });
    this.connections.clear();
    this.stopPing();
  }

  getState(server: string, topic: string): ConnectionState {
    const entry = this.connections.get(this.makeKey(server, topic));
    return entry?.state ?? ConnectionState.DISCONNECTED;
  }

  getConnectedCount(): number {
    let count = 0;
    this.connections.forEach(entry => {
      if (entry.state === ConnectionState.CONNECTED) count++;
    });
    return count;
  }

  getAllStatus(): WsStatus[] {
    const result: WsStatus[] = [];
    this.connections.forEach(entry => {
      result.push({
        server: entry.server,
        topic: entry.topic,
        state: entry.state,
        lastMessageTime: entry.lastMessageTime,
        reconnectAttempts: entry.reconnectAttempts
      });
    });
    return result;
  }

  private createConnection(server: string, topic: string, attempt: number): void {
    const key = this.makeKey(server, topic);
    const state = attempt === 0 ? ConnectionState.CONNECTING : ConnectionState.RECONNECTING;

    const wsBase = server.replace(/^http:/, 'ws:').replace(/^https:/, 'wss:');
    const url = `${wsBase}/${topic}/ws`;

    const ws = webSocket.createWebSocket();
    let isResolved = false;

    const entry: WsEntry = {
      server,
      topic,
      ws,
      state,
      reconnectAttempts: attempt,
      timerId: -1,
      lastMessageTime: 0
    };
    this.connections.set(key, entry);
    this.updateState(server, topic, state, attempt);

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err) {
        console.error(`[WS] message error: ${err.message}`);
        return;
      }
      const text = typeof value === 'string' ? value : value.toString();
      try {
        const msg = JSON.parse(text) as NtfyMessage;
        if (msg && msg.event === 'message') {
          entry.lastMessageTime = msg.time * 1000; // 转为毫秒
          console.info(`[WS] dispatching message id=${msg.id} to ${this.onMessageCallbacks.length} callbacks`);
          for (const cb of this.onMessageCallbacks) {
            cb(msg, server, topic);
          }
        }
      } catch (_e) {
        // ignore non-JSON frames
      }
    });

    ws.on('open', (_err: BusinessError, _value: Object) => {
      isResolved = true;
      entry.state = ConnectionState.CONNECTED;
      entry.reconnectAttempts = 0;
      entry.lastMessageTime = Date.now(); // 连接成功时记录时间
      this.updateState(server, topic, ConnectionState.CONNECTED, 0);
      console.info(`[WS] connected: ${server}/${topic}`);
    });

    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      if (!isResolved) {
        isResolved = true;
      }
      const currentEntry = this.connections.get(key);
      if (!currentEntry) return;
      console.info(`[WS] closed: ${server}/${topic} code=${value.code} reason=${value.reason}`);
      this.scheduleReconnect(currentEntry);
    });

    ws.on('error', (err: BusinessError) => {
      if (!isResolved) {
        isResolved = true;
      }
      const currentEntry = this.connections.get(key);
      if (!currentEntry) return;
      currentEntry.state = ConnectionState.ERROR;
      this.updateState(server, topic, ConnectionState.ERROR, currentEntry.reconnectAttempts);
      console.error(`[WS] error: ${server}/${topic} msg=${err.message}`);
      this.scheduleReconnect(currentEntry);
    });

    ws.connect(url, (err: BusinessError, value: boolean) => {
      if (err) {
        if (!isResolved) {
          isResolved = true;
        }
        const currentEntry = this.connections.get(key);
        if (!currentEntry) return;
        currentEntry.state = ConnectionState.ERROR;
        this.updateState(server, topic, ConnectionState.ERROR, currentEntry.reconnectAttempts);
        this.scheduleReconnect(currentEntry);
      }
    });

    // Connection timeout
    setTimeout(() => {
      if (!isResolved) {
        isResolved = true;
        const currentEntry = this.connections.get(key);
        if (!currentEntry) return;
        try {
          currentEntry.ws.close(() => {});
        } catch (_e) {
          // ignore
        }
        currentEntry.state = ConnectionState.ERROR;
        this.updateState(server, topic, ConnectionState.ERROR, currentEntry.reconnectAttempts);
        this.scheduleReconnect(currentEntry);
      }
    }, WebSocketService.CONNECTION_TIMEOUT_MS);
  }

  private scheduleReconnect(entry: WsEntry): void {
    const key = this.makeKey(entry.server, entry.topic);
    // 不再检查重连上限，改为无限重连
    if (!this.connections.has(key)) {
      // 如果连接已被手动删除（disconnect），不再重连
      return;
    }

    entry.reconnectAttempts++;

    // 指数退避：如果超过 MAX_DELAY_AFTER_ATTEMPTS 次，固定使用最大延迟
    let delay: number;
    if (entry.reconnectAttempts <= WebSocketService.MAX_DELAY_AFTER_ATTEMPTS) {
      delay = Math.min(
        WebSocketService.INITIAL_RECONNECT_DELAY_MS * Math.pow(2, entry.reconnectAttempts - 1),
        WebSocketService.MAX_RECONNECT_DELAY_MS
      );
    } else {
      delay = WebSocketService.MAX_RECONNECT_DELAY_MS;
    }

    entry.state = ConnectionState.RECONNECTING;
    this.updateState(entry.server, entry.topic, ConnectionState.RECONNECTING, entry.reconnectAttempts);

    console.info(`[WS] scheduleReconnect: ${entry.server}/${entry.topic} attempt=${entry.reconnectAttempts} delay=${delay}ms`);

    const timerId = setTimeout(() => {
      const current = this.connections.get(key);
      if (!current) return;
      // 清理旧的 WS 连接
      try {
        current.ws.close(() => {});
      } catch (_e) {
        // ignore
      }
      this.createConnection(entry.server, entry.topic, entry.reconnectAttempts);
    }, delay);

    entry.timerId = timerId;
  }

  private stopReconnect(entry: WsEntry): void {
    if (entry.timerId > 0) {
      clearTimeout(entry.timerId);
      entry.timerId = -1;
    }
  }

  private updateState(server: string, topic: string, state: ConnectionState, attempts: number): void {
    if (this.onStatusCallback) {
      this.onStatusCallback({
        server,
        topic,
        state,
        reconnectAttempts: attempts
      });
    }
  }

  private makeKey(server: string, topic: string): string {
    return `${server}_${topic}`;
  }
}
