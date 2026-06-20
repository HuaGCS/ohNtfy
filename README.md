# NtfyPush

**HarmonyOS 客户端 for [ntfy.sh](https://ntfy.sh)** — 一个基于 HTTP 的简单发布-订阅通知服务。

通过 NtfyPush，你可以直接在鸿蒙设备上订阅 ntfy 主题，接收实时推送通知，并可向主题发布消息。

## 功能

- 📡 **实时推送** — 支持 WebSocket 实时连接，消息延迟低
- 🔄 **轮询模式** — 兼容性更好，可在 WebSocket 不可用时作为备选
- 🔔 **系统通知** — 收到新消息时推送鸿蒙系统通知
- 📤 **发布消息** — 支持标题、消息体、优先级、标签
- 🏷️ **多主题管理** — 订阅、取消订阅，自定义显示名称
- 🌐 **多服务器** — 支持同时连接多个 ntfy 服务器
- 🔙 **后台接收** — 应用退到后台后持续接收推送（dataTransfer 后台模式）
- 🎨 **主题切换** — 支持浅色/深色/跟随系统
- 🌍 **中英文** — 内置中文和英文界面
- 🔒 **隐私安全** — 所有数据仅存储在设备本地

## 快速开始

### 环境要求

- HarmonyOS SDK API 24+
- DevEco Studio NEXT
- HarmonyOS 设备或模拟器（手机/平板/2in1）

### 构建

- 克隆本仓库
- 使用 DevEco Studio 打开项目目录
- 连接设备/模拟器后，点击 Build > Build HAP(s) / 运行


### 使用

1. 打开应用，点击 **+** 添加订阅
2. 输入主题地址，例如 `https://ntfy.sh/mytopic` 或自建服务器 `http://192.168.1.100:51248/mytopic`
3. 订阅成功后自动建立连接
4. 收到消息时将通过系统通知推送

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | ArkTS（TypeScript-on-HarmonyOS） |
| UI 框架 | ArkUI（声明式 UI） |
| 实时连接 | WebSocket（@kit.NetworkKit） |
| 数据存储 | 本地 Preferences / 文件存储 |
| 后台任务 | Background Tasks Kit（短时任务 + dataTransfer） |
| 通知服务 | Notification Kit |
| 构建工具 | hvigor |

## 项目结构

```
entry/src/main/ets/
├── entryability/
│   └── EntryAbility.ets       # 应用入口，全局服务初始化
├── pages/
│   ├── Index.ets              # 主页：订阅列表 + 连接状态
│   ├── AddTopic.ets           # 添加订阅页
│   ├── TopicDetail.ets        # 主题详情：消息列表 + 发布
│   ├── Settings.ets           # 设置页
│   ├── About.ets              # 关于页
│   ├── Privacy.ets            # 隐私政策
│   └── Licenses.ets           # 开源许可
├── model/
│   ├── TopicModel.ets         # 数据模型 + SubscriptionManager
│   ├── WebSocketService.ets   # WebSocket 连接管理（共享连接/指数退避重连/健康检查）
│   ├── NtfyService.ets        # ntfy HTTP API 封装
│   ├── NotificationService.ets # 系统通知服务
│   ├── StorageManager.ets     # 本地持久化存储
│   ├── BackgroundTaskService.ets # 后台任务管理
│   └── MessageCacheService.ets # 消息缓存
└── common/
    └── Constants.ets          # 常量定义
```

## 连接协议

### WebSocket（默认，推荐）

- 同一服务器下的所有订阅共享一条 WebSocket 连接
- URL 格式：`ws(s)://server/topic1,topic2/ws`
- 自动重连：指数退避（1s → 60s 上限）
- 健康检查：3 分钟无消息触发重连

### JSON 轮询（备选）

- 定期通过 HTTP GET 拉取消息
- 可在设置中切换

## 自建服务器

你可以在自己的服务器上部署 ntfy：

```bash
# 安装 ntfy（需要 Go）
ntfy serve --listen http://0.0.0.0:51248
```

然后在应用中添加 `http://你的IP:51248/主题名` 即可。

> ⚠️ 自建服务器务必监听 `0.0.0.0`，否则设备无法连接

## 许可

本项目采用 **自定义许可证**，**禁止商业用途** 且 **必须保持开源**。详情请参阅 [LICENSE](LICENSE) 文件。

## 免责声明

这是 [ntfy.sh](https://ntfy.sh) 的第三方非官方客户端。本应用与 ntfy 项目无任何关联、认可或赞助关系。所有 ntfy 相关商标和版权归其各自所有者所有。
