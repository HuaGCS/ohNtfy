import { http } from '@kit.NetworkKit';
import { NtfyMessage, NtfyPublishRequest } from './TopicModel';
import { Constants } from '../common/Constants';

export class NtfyService {
  private serverUrl: string;
  private httpClient: http.HttpRequest | null = null;

  constructor(serverUrl: string = Constants.DEFAULT_SERVER) {
    this.serverUrl = serverUrl.replace(/\/+$/, '');
  }

  private getHttpClient(): http.HttpRequest {
    if (!this.httpClient) {
      this.httpClient = http.createHttp();
    }
    return this.httpClient;
  }

  setServer(url: string): void {
    this.serverUrl = url.replace(/\/+$/, '');
  }

  getServer(): string {
    return this.serverUrl;
  }

  /**
   * 解析 ntfy /json 端点返回的 NDJSON 响应。
   * /json 返回的是一行一个 JSON 对象（NDJSON），?poll=1 时一次性返回所有缓存消息，否则为流式推送。
   * 仅保留 event === 'message' 的消息，过滤掉 open / keepalive / poll_request。
   */
  static parseRawResponse(raw: string): NtfyMessage[] {
    if (!raw || raw.trim().length === 0) {
      return [];
    }

    const trimmed = raw.trim();
    const messages: NtfyMessage[] = [];

    // JSON 数组格式: [{...}, {...}]（某些中间代理可能返回）
    if (trimmed.startsWith('[')) {
      try {
        const arr: Array<Object> = JSON.parse(trimmed) as Array<Object>;
        if (Array.isArray(arr)) {
          for (const item of arr) {
            const obj = item as Record<string, Object>;
            if (obj && obj['event'] === 'message') {
              messages.push(item as NtfyMessage);
            }
          }
          return messages;
        }
      } catch (e) {
        // 不是 JSON 数组，继续尝试 NDJSON
      }
    }

    // NDJSON 格式：每行一个 JSON
    const lines = raw.split('\n');
    for (const line of lines) {
      const trimmedLine = line.trim();
      if (trimmedLine.length === 0) {
        continue;
      }
      // 兼容 SSE data: 前缀（/sse 端点，当前未使用但保留兼容）
      const jsonStr = trimmedLine.startsWith('data:')
        ? trimmedLine.slice(5).trim()
        : trimmedLine;
      try {
        const msg = JSON.parse(jsonStr) as NtfyMessage;
        if (msg && msg.event === 'message') {
          messages.push(msg);
        }
      } catch (e) {
        continue;
      }
    }
    return messages;
  }

  /**
   * 一次性拉取缓存消息（?poll=1，立即返回并断开连接）。
   * @param topic 主题名
   * @param since 拉取起点：'all' = 全部历史缓存，消息ID = 该ID之后，留空 = 最近缓存
   * @param filters 可选过滤：priority/tags/title/message
   */
  async fetchMessages(topic: string, since?: string, filters?: Record<string, string>): Promise<NtfyMessage[]> {
    let url = `${this.serverUrl}/${topic}/json?poll=1`;
    if (since) {
      url += `&since=${encodeURIComponent(since)}`;
    }
    if (filters) {
      for (const key of Object.keys(filters)) {
        url += `&${key}=${encodeURIComponent(filters[key])}`;
      }
    }

    try {
      const response: http.HttpResponse = await this.getHttpClient().request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
        header: {
          'Accept': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode === 200) {
        const raw = response.result as string;
        return NtfyService.parseRawResponse(raw);
      }
      console.error(`fetchMessages failed: HTTP ${response.responseCode} for ${url}`);
      return [];
    } catch (e) {
      console.error(`Failed to fetch messages (${url}):`, JSON.stringify(e));
      return [];
    }
  }

  /**
   * 轮询拉取新消息（?poll=1，一次性拉取最近缓存后立即返回）。
   * 与 /json 长连接不同，这里用一次性的 poll=1，由调用方用 setInterval/setTimeout 控制轮询间隔。
   */
  async pollMessages(topic: string): Promise<NtfyMessage[]> {
    const url = `${this.serverUrl}/${topic}/json?poll=1`;

    try {
      const response: http.HttpResponse = await this.getHttpClient().request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
        header: {
          'Accept': 'application/json'
        },
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode === 200) {
        const raw = response.result as string;
        return NtfyService.parseRawResponse(raw);
      }
      console.error(`pollMessages failed: HTTP ${response.responseCode} for ${url}`);
      return [];
    } catch (e) {
      console.error(`Failed to poll messages (${url}):`, JSON.stringify(e));
      return [];
    }
  }

  async publish(request: NtfyPublishRequest): Promise<boolean> {
    const url = `${this.serverUrl}/${request.topic}`;
    const body: Record<string, Object> = {};

    if (request.message) body['message'] = request.message;
    if (request.title) body['title'] = request.title;
    if (request.priority) body['priority'] = request.priority;
    if (request.tags) body['tags'] = request.tags;
    if (request.click) body['click'] = request.click;

    try {
      const response: http.HttpResponse = await this.getHttpClient().request(url, {
        method: http.RequestMethod.POST,
        connectTimeout: 10000,
        readTimeout: 15000,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING
      });

      if (response.responseCode === 200) {
        return true;
      }
      console.error(`publish failed: HTTP ${response.responseCode} for ${url}`);
      throw new Error(`服务器返回状态码 ${response.responseCode}`);
    } catch (e) {
      console.error('Failed to publish message:', JSON.stringify(e));
      throw new Error('发布消息失败：' + ((e as Error)?.message || '未知错误'));
    }
  }

  destroy(): void {
    if (this.httpClient) {
      this.httpClient.destroy();
      this.httpClient = null;
    }
  }
}
