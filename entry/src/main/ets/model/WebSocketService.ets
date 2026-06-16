import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { NtfyMessage } from './TopicModel';

export enum ConnectionState {
  DISCONNECTED = 0,
  CONNECTING = 1,
  CONNECTED = 2,
  RECONNECTING = 3,
  ERROR = 4
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

  private static readonly MAX_RECONNECT_ATTEMPTS = 10;
  private static readonly INITIAL_RECONNECT_DELAY_MS = 1000;
  private static readonly MAX_RECONNECT_DELAY_MS = 60000;
  private static readonly CONNECTION_TIMEOUT_MS = 15000;

  static getInstance(): WebSocketService {
    if (!WebSocketService.instance) {
      WebSocketService.instance = new WebSocketService();
    }
    return WebSocketService.instance;
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
          entry.lastMessageTime = msg.time;
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
    if (!this.connections.has(key)) return;

    entry.reconnectAttempts++;
    if (entry.reconnectAttempts > WebSocketService.MAX_RECONNECT_ATTEMPTS) {
      this.connections.delete(key);
      this.updateState(entry.server, entry.topic, ConnectionState.DISCONNECTED, entry.reconnectAttempts);
      return;
    }

    const delay = Math.min(
      WebSocketService.INITIAL_RECONNECT_DELAY_MS * Math.pow(2, entry.reconnectAttempts - 1),
      WebSocketService.MAX_RECONNECT_DELAY_MS
    );

    entry.state = ConnectionState.RECONNECTING;
    this.updateState(entry.server, entry.topic, ConnectionState.RECONNECTING, entry.reconnectAttempts);

    const timerId = setTimeout(() => {
      const current = this.connections.get(key);
      if (!current) return;
      // Clean old WS
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
