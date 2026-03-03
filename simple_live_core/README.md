# simple_live_core

`simple_live_core` 是 `dart_simple_live` 项目的核心聚合库，用于统一接入多个直播平台的数据能力。

它的目标是：**用一套统一接口，完成不同站点的直播信息查询、播放地址解析与弹幕连接**，让上层应用（Flutter App / TV App / Console）尽量不感知站点差异。

---

## 功能概览

### 1) 多平台直播站点聚合
当前内置站点实现：

- 哔哩哔哩直播（`BiliBiliSite`）
- 斗鱼直播（`DouyuSite`）
- 虎牙直播（`HuyaSite`）
- 抖音直播（`DouyinSite`）

所有站点都遵循统一能力模型（`LiveSite`）：

- 获取分类 / 子分类
- 获取推荐直播列表
- 获取分类下直播列表
- 搜索直播间
- 搜索主播（部分站点可能不支持）
- 获取房间详情
- 获取清晰度列表
- 获取播放链接
- 查询开播状态
- 获取醒目留言（部分站点支持）

---

### 2) 统一弹幕能力
通过 `LiveDanmaku` 抽象弹幕连接流程，并提供各站点实现：

- `BiliBiliDanmaku`
- `DouyuDanmaku`
- `HuyaDanmaku`
- `DouyinDanmaku`

统一事件回调：

- `onReady`：连接建立
- `onMessage`：收到消息（聊天/在线人数/SC 等）
- `onClose`：连接关闭或重连提示

统一生命周期：

- `start(args)`：开始连接
- `heartbeat()`：发送心跳
- `stop()`：停止连接

---

### 3) 统一数据模型
库内提供一套跨站点通用的数据结构，便于上层 UI 和业务复用：

- `LiveCategory` / `LiveSubCategory`
- `LiveCategoryResult`
- `LiveRoomItem`
- `LiveRoomDetail`
- `LivePlayQuality`
- `LivePlayUrl`
- `LiveSearchRoomResult`
- `LiveSearchAnchorResult`
- `LiveAnchorItem`
- `LiveMessage` / `LiveSuperChatMessage`

这套模型已经覆盖常见直播业务所需：列表、详情、播放、多清晰度、弹幕消息流。

---

## 安装

在 `pubspec.yaml` 中引入（按你的工程组织方式选择）。

### 方式一：本地 path 依赖

```yaml
dependencies:
  simple_live_core:
    path: ../simple_live_core
```

### 方式二：Git 依赖

```yaml
dependencies:
  simple_live_core:
    git:
      url: https://github.com/xiaoyaocz/dart_simple_live
      path: simple_live_core
```

---

## 快速开始

### 1) 读取分类和推荐房间

```dart
import 'package:simple_live_core/simple_live_core.dart';

Future<void> main() async {
  final site = BiliBiliSite();

  // 分类
  final categories = await site.getCategores();
  print('分类数量: ${categories.length}');

  // 推荐
  final recommend = await site.getRecommendRooms(page: 1);
  print('推荐房间: ${recommend.items.length}');

  if (recommend.items.isNotEmpty) {
    final roomId = recommend.items.first.roomId;

    // 详情
    final detail = await site.getRoomDetail(roomId: roomId);
    print('房间标题: ${detail.title}');

    // 清晰度
    final qualities = await site.getPlayQualites(detail: detail);
    if (qualities.isNotEmpty) {
      // 播放地址
      final playUrl = await site.getPlayUrls(
        detail: detail,
        quality: qualities.first,
      );
      print('播放地址数量: ${playUrl.urls.length}');
    }
  }
}
```

---

### 2) 接入弹幕

```dart
import 'package:simple_live_core/simple_live_core.dart';

Future<void> startDanmaku(BiliBiliSite site, LiveRoomDetail detail) async {
  final danmaku = site.getDanmaku();

  danmaku.onReady = () => print('弹幕连接成功');
  danmaku.onClose = (msg) => print('弹幕关闭: $msg');
  danmaku.onMessage = (msg) {
    switch (msg.type) {
      case LiveMessageType.chat:
        print('[${msg.userName}] ${msg.message}');
        break;
      case LiveMessageType.online:
        print('在线/人气: ${msg.data}');
        break;
      case LiveMessageType.superChat:
      case LiveMessageType.gift:
        break;
    }
  };

  // 注意：不同站点的 args 类型不同。
  // B 站通常使用 BiliBiliDanmakuArgs。
  await danmaku.start(
    BiliBiliDanmakuArgs(
      roomId: int.parse(detail.roomId),
      token: 'your_token',
      serverHost: 'broadcastlv.chat.bilibili.com',
      buvid: 'your_buvid',
      uid: 0,
      cookie: '',
    ),
  );
}
```

> 提示：弹幕启动参数是站点相关的（例如 `BiliBiliDanmakuArgs`、`DouyinDanmakuArgs`）。推荐通过对应 `Site` 在获取房间详情后，再组装参数。

---

## 平台差异说明

虽然有统一接口，但站点能力存在客观差异，常见情况包括：

- 某些站点不支持主播搜索
- 某些站点暂无醒目留言接口
- 同一能力字段语义可能不完全一致（如在线人数/人气值）

因此建议在上层做两层处理：

1. **优先走统一模型**（保证主体流程一致）
2. **按站点做小范围兼容**（处理特殊字段或不支持功能）

---

## 日志与调试

库内使用 `CoreLog` 统一输出日志，可按需要调整：

- 开关日志：`CoreLog.enableLog`
- 请求日志模式：`CoreLog.requestLogType`
  - `RequestLogType.all`
  - `RequestLogType.short`
  - `RequestLogType.none`
- 自定义日志输出：`CoreLog.onPrintLog`

在联调不同站点时，建议先使用 `all` 模式定位请求与响应问题，稳定后再降级到 `short` 或 `none`。

---

## 对接建议

在实际项目中，建议你把本库作为“数据源层”使用：

- `simple_live_core`：负责站点协议、接口、弹幕
- 业务层（你自己的仓库/service）：做缓存、鉴权、错误映射、重试策略
- UI 层：仅依赖统一模型，不感知站点实现细节

这样可以显著降低后续新增站点或修复站点协议时的改造成本。

---

## 目录参考

```text
simple_live_core/
├── lib/
│   ├── simple_live_core.dart       # 对外导出入口
│   └── src/
│       ├── interface/              # LiveSite / LiveDanmaku 抽象
│       ├── model/                  # 统一数据模型
│       ├── danmaku/                # 各站点弹幕实现
│       ├── common/                 # 网络、日志、工具
│       └── *_site.dart             # 各站点业务实现
├── demo/                           # 协议与样例数据
└── packages/tars_dart/             # tars 协议支持
```

---

## 注意事项

1. 直播平台接口与协议经常变动，某些能力可能阶段性失效，需要跟进修复。
2. 某些站点在无 Cookie 情况下能力受限（如清晰度、访问频率）。
3. 弹幕连接建议配合重连、超时与心跳监控机制使用。
4. 请遵守各平台服务条款与法律法规，仅用于合法合规用途。

---

欢迎基于本库扩展更多站点能力与更完善的异常处理策略。
