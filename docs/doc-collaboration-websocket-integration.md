# Doc Collaboration WebSocket PaaS 对接文档

文档协同通过系统 PaaS 主 WebSocket 的 `Document` 通道传输 Yjs 正文更新、在线状态和临时消息。客户端复用登录会话、主连接、心跳与重连能力，为每个编辑器建立独立的逻辑连接。

最小接入流程为：**挂接本地接收队列 → 平台 `subscribe` → `collabJoin` → 接收服务端差量 → 补传客户端差量 → 持续交换更新**。每次物理连接重连后都执行这一流程。

适用实现：2026-10-12 的 CSES `feat-doc`，提交 `51a36a8460cd`；PaaS 传输约定参照本地源码 `c827bf1`。部署时应确认服务端与 PaaS 依赖包含相应能力，尤其是浏览器握手 Query 参数支持。本文描述源码协议，不作为环境发布或真实网络联调完成的证明。

## 接入范围与职责

| 层次 | 职责 |
| --- | --- |
| PaaS 主连接 | 登录会话、物理连接、平台订阅、消息路由、心跳和重连 |
| Doc Collaboration | 文档房间、Yjs 差量同步、Awareness、协同错误与逻辑连接生命周期 |
| 编辑器 | 业务 Y.Doc 数据模型、编辑操作、光标绑定、本地离线状态、错误提示 |
| 文档业务接口 | 创建文档、取得正式 docId、业务权限、文档元信息 |

`collabJoin` 只加入已有文档，不创建业务文档。任务描述等嵌入式编辑器也传正式 `docId`，不能用任务 ID、临时 ID 或 Yjs clientID 替代。正文内的块、富文本和属性沿用现有编辑器模型，传输层不约定一个通用的 `getText('content')` 根节点。

权限、评论、分享等普通文档通知仍按[文档 Socket 变更通知规则](doc-socket-change-notifications.md)接收。协同使用非空编辑器 instance，不与空 instance 的业务通知订阅混用。

## PaaS 连接与会话

### 系统客户端

使用登录后的 `ctx.bus` 和 `ctx.bus.webSocketClient`。编辑器不单独创建 WebSocket，不更换系统 WS 地址，也不在 `collabJoin.body` 中发送 token。

主连接地址取当前环境的 `websocketHost`；服务端配置入口为 `web-config.websocket-host`。URL 路径沿用部署配置，不能把旧独立协同服务的 `/collaboration` 地址拼到主连接上。标准 `y-websocket` 或 Hocuspocus Provider 不能只改 URL 后直接接入，需要适配本文的 PaaS JSON 协议。

### 自建宿主的握手参数

自建 Web/桌面宿主应在应用级建立一个 PaaS 主连接，再由多个编辑器复用。先完成系统登录，使用登录流程产生的有效会话信息。

| 参数 | 位置 | 说明 |
| --- | --- | --- |
| `cookieId` | Header 或 Query | PaaS 会话标识，沿用登录结果；不是本文新增的 JWT/Bearer token |
| `deviceId` | Header 或 Query | 与登录登记一致的设备 ID；不能为每个编辑器重新生成 |
| `company` / `companyId` | Header 或 Query | 当前企业上下文；同一来源优先使用 `company` |
| `appVersion`、`osVersion` | Header 或 Query | 客户端版本信息 |
| `device` | Header | 设备类型；未提供时服务端默认 `WebBrowser` |

服务端先读取 Header，再用 Query 补齐缺失值。浏览器原生 WebSocket 无法设置这些自定义 Header 时，可通过 `URL.searchParams` 编码 Query。凭证只用于主连接初始化，不写入正文、Awareness 或 Stateless。

应用级 URL 构造示例，`websocketHost` 已包含部署要求的完整路径：

```ts
const url = new URL(websocketHost);
url.searchParams.set('cookieId', login.cookieId);
url.searchParams.set('deviceId', login.deviceId);
url.searchParams.set('companyId', currentCompanyId);
// 由宿主连接管理器使用 url；已有 ctx.bus 的编辑器无需执行这一步。
```

会话读取依赖有效的 `cookieId + deviceId` 登录缓存。物理 WebSocket 打开或收到 `feedback` 并不能证明业务会话有效：CSES 分发器对空用户 ID 直接忽略业务消息，不保证返回 `collabError`。

**当前权限边界：协同 WS 入口没有调用文档读写权限校验，也没有只读模式或文档级授权 token。** `companyId` 是会话上下文，不是授权凭据；`ACCESS_DENIED` 错误码的存在也不表示此入口已完成权限校验。宿主的业务权限检查不能替代服务端访问控制，当前协议不能被视为已具备对不可信客户端开放的文档级隔离能力。

### 物理连接心跳

已有客户端沿用主连接管理器。自建宿主使用 PaaS 控制消息，例如：

```json
{"subscription":{"channel":"","topic":"","instance":""},"action":"ping","body":{}}
```

当前 PaaS 返回形如 `{"text":"pong","serverTime":1791792000000,"serverName":"node-name"}` 的控制帧，宿主应在业务路由前处理；它没有 `collab*` action。心跳周期和断线判定沿用宿主及部署约定。Awareness 另有在线状态心跳，不能替代物理连接心跳。

## PaaS 消息封装与路由

线上使用 **WebSocket 文本帧中的 JSON 对象**：

```json
{
  "subscription": {
    "channel": "Document",
    "topic": "doc-123",
    "instance": "editor-uuid"
  },
  "action": "collabJoin",
  "body": { "stateVector": "AA==" }
}
```

| 字段 | 类型与必填性 | 含义 |
| --- | --- | --- |
| `subscription` | object，必填 | PaaS 三级路由 |
| `subscription.channel` | string，必填 | 固定 `Document`，大小写必须一致 |
| `subscription.topic` | string，必填 | 正式 docId，非空、非纯空白、最长 128 字符 |
| `subscription.instance` | string，必填 | 编辑器实例 ID，非空、非纯空白、最长 128 字符 |
| `action` | string，必填 | 使用本文列出的精确 action 名称 |
| `body` | object | 按 action 定义；无参数时发送 `{}` |
| `companyId` | string，可选，顶层 | PaaS 通用企业上下文；通常沿用主连接，业务切换由宿主统一管理 |

服务端可能补充顶层 `timestamp`、`seq`、`tracing`、`policy`、`isCompensated` 等 PaaS 字段。客户端允许这些扩展字段；`seq` 不是文档 revision，`timestamp` 不是文档落库时间，也不能用它们关联某次 `collabUpdate` 的完成状态。

同一编辑器生命周期内保持 instance 稳定，主连接重连后可复用；重新挂载生成新 instance。同一物理连接打开同一文档的两个编辑器时，instance 必须不同。服务端成员键为 `(connectionId, instance)`，其中 `connectionId` 由服务端取得，不由客户端发送。

`Y.Doc.clientID` 由 Yjs 生成，是 CRDT/Awareness 标识，与用户 ID、deviceId、instance 均不同。多个视图共享同一个 Y.Doc 时，应共享一个协同会话并由业务层管理引用计数，避免多个 instance 争用同一 Awareness clientID。

移动原生 SDK 将临时 Awareness 放在独立 Yrs Doc 中：新逻辑实例及物理连接恢复时调用
`beginAwarenessSession` 轮换在线身份；同连接周期同步、重试及正文历史回放不轮换。正文 Doc 保留
原身份与持久化增量。这样旧实例退出、物理断开或跨节点在线状态清理延迟时，新归属不会争用旧 clientID。
会话的旧回调仍须通过所属控制器/引擎所有权校验，不能仅依靠更换在线身份隔离文档。

## 平台订阅和协同握手

### 订阅顺序

1. 注册本地 `Document → docId → instance` 接收队列。
2. 主连接可用后发送同路由 `subscribe`。
3. 随后在同一连接发送 `collabJoin`，携带当前 Y.Doc 的状态向量。
4. 收到 `collabSync` 后应用服务端差量，再按其状态向量补传本地差量。

本地队列订阅负责接收分发，PaaS `subscribe` 负责平台登记，`collabJoin` 负责加入房间。三者职责不同。PaaS 发送器按连接的 channel/topic 订阅过滤业务响应，缺少 `subscribe` 时可能连 `collabError` 都收不到。每个编辑器应登记自己的 instance，不依赖其他页面已有的空 instance 订阅。

平台订阅请求：

```json
{"subscription":{"channel":"Document","topic":"doc-123","instance":"editor-uuid"},"action":"subscribe","body":{}}
```

平台反馈示例，省略可选传输字段：

```json
{
  "subscription": {"channel":"Document","topic":"doc-123","instance":"editor-uuid"},
  "action": "feedback",
  "body": {
    "isSuccess": true,
    "message": "订阅成功",
    "header": {"channel":"Document","topic":"doc-123","instance":"editor-uuid"}
  }
}
```

`feedback` 只说明平台订阅处理结果；正文同步以 `collabSync` 为入口，不等待或判断中文提示文本。

### 双向同步

| 顺序 | 方向 | 消息和处理 |
| --- | --- | --- |
| 1 | 客户端 → 服务端 | `collabJoin { stateVector: Base64(Y.encodeStateVector(ydoc)) }` |
| 2 | 服务端 → 当前编辑器 | `collabSync { data, stateVector }`，给出客户端缺失的正文及服务端状态向量 |
| 3 | 客户端本地 | `Y.applyUpdate(ydoc, decode(data), REMOTE)` |
| 4 | 客户端 → 服务端 | `collabUpdate { data: Base64(Y.encodeStateAsUpdate(ydoc, decode(stateVector))) }`，补传服务端缺失的本地修改 |
| 5 | 双向 | 本地 update 事件上行；远端 `collabUpdate` 应用到同一 Y.Doc |

首次 join 还可能返回非空 Awareness 快照及 `collabSyncStatus { synced: true }`。join 和后续 update 各自都有 SyncStatus，第一条 true 不能作为步骤 4 已处理的确认。

`AA==` 是空状态向量 `[0]`；空文档 V1 update `[0,0]` 为 `AAA=`。以下仅展示空文档响应形状，真实数据必须由 Yjs 生成：

```json
{
  "subscription": {"channel":"Document","topic":"doc-123","instance":"editor-uuid"},
  "action": "collabSync",
  "body": {"data":"AAA=","stateVector":"AA=="}
}
```

主动补偿使用 `collabSync`，请求 body 与 join 相同，前提是已经加入房间。它也必须执行“应用服务端差量 → 补传客户端差量”。

## Action 协议

### 客户端发送

除 join、leave 和平台订阅操作外，下列命令都要求当前 `(connectionId, instance)` 已加入对应文档。

| action | body | 服务端行为 |
| --- | --- | --- |
| `subscribe` | `{}` | 登记 PaaS 订阅，返回 `feedback`；不加入协同房间 |
| `collabJoin` | `{ "stateVector"?: string }` | 加载并加入已有文档，返回 `collabSync`、可选 Awareness 快照及 SyncStatus；省略向量时返回完整状态 |
| `collabSync` | `{ "stateVector"?: string }` | 返回正文差量和服务端向量，随后 SyncStatus |
| `collabUpdate` | `{ "data": string }` | 应用 Base64 编码的 Yjs V1 update；有实际可广播更新时发送 `collabUpdate`，请求者另收 SyncStatus |
| `collabAwareness` | `{ "data": string }` | 更新本编辑器在线状态，向其他编辑器广播，不产生正文 SyncStatus |
| `collabQueryAwareness` | `{}` | 向当前编辑器返回 `collabAwareness` 快照，包括空快照 |
| `collabStateless` | `{ "payload": string }` | 原样回复请求编辑器，响应 action 为 `collabStateless` |
| `collabBroadcastStateless` | `{ "payload": string }` | 发送给当前服务实例中同文档的其他已加入编辑器，响应 action 为 `collabStateless` |
| `collabLeave` | `{}` | 移除当前编辑器，正常退出没有专用成功回包；不关闭主连接、不移除平台订阅 |
| `unsubscribe` | `{}` | 移除指定平台订阅；非空 docId 和 instance 也触发协同 leave，实际移除订阅时返回 `feedback` |

`stateVector` 省略或空字符串按未提供处理；实际接入统一发送编码后的真实向量。`collabUpdate.data` 和 `collabAwareness.data` 必填且非空。未知协同 action 在外层可能被忽略，不保证返回“不支持”的错误。

### 服务端发送

响应中的路由指向**接收编辑器**，广播也使用接收者的 instance。因此不能把回包 instance 当作修改者 ID。

| action | body | 客户端处理 |
| --- | --- | --- |
| `collabSync` | `{ "data": string, "stateVector": string }` | 应用正文，再以服务端向量计算本地差量补传 |
| `collabUpdate` | `{ "data": string }` | 应用正文；发送者也可能收到自身更新，利用 Yjs 幂等性处理 |
| `collabAwareness` | `{ "data": string }` | 交给 `applyAwarenessUpdate`，不能交给 `Y.applyUpdate` |
| `collabStateless` | `{ "payload": string }` | 交给应用约定的临时消息处理器 |
| `collabSyncStatus` | `{ "synced": true }` | 当前 join/sync/update 已处理；不是所有客户端收敛或数据库保存确认 |
| `collabError` | `{ "code": string, "message": string }` | 按稳定 code 处理；失败不先发送 `synced: false` |
| `collabClose` | `{}` | 停止发送并重新 join/sync，主连接继续使用；可能是房间关闭，也可能是增量广播过大时要求重新同步 |

正文更新可能经过服务端批处理、去重或依赖补齐，不保证每条入站 update 都对应一条原样广播。协议没有逐命令 `requestId`、正文 `ack`、客户端 `save` 或 `flush` 命令。

## Yjs 编码和客户端接入

### 二进制编码

正文使用 **Base64 编码的原始 Yjs V1 update**；状态向量使用 `Y.encodeStateVector`；在线状态使用 `encodeAwarenessUpdate`。不发送 V2 update、Yjs 对象的 JSON 序列化结果或 y-websocket/Hocuspocus 外层二进制帧。

Yjs 的状态向量用于计算对方缺失的更新，`applyUpdate` 的 origin 可用于避免回发循环。API 见 [Yjs Document Updates](https://docs.yjs.dev/api/document-updates)。

浏览器辅助函数：

```ts
function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}

function fromBase64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), char => char.charCodeAt(0));
}
```

编码前及解码后检查后文的大小限制，捕获 Base64/Yjs 解码异常。不能把 CRDT 字节先转成 UTF-8 文本；也不要用单次 `String.fromCharCode(...largeUpdate)` 展开整篇文档。

### 现有客户端接入点

cses-client 中已有 `packages/docs/src/realtime/docs-collaboration-session.ts` 的 `DocsCollaborationSession`，负责队列、订阅、握手、Awareness、重连和释放。下面适用于 docs 包内部；该类目前未从包根 index 导出，其他包应经过明确的包接口接入。

```ts
// 示例文件位于 packages/docs/src/ 下；ydoc 是业务编辑器已有的 Y.Doc。
import { DocsCollaborationSession } from './realtime/docs-collaboration-session';

const collaboration = new DocsCollaborationSession(ctx.bus, docId, ydoc);
collaboration.awareness.setLocalStateField('user', {
  id: currentUser.id,
  name: currentUser.name
});
collaboration.start();

// await 必须纳入页面已有的失败提示/取消流程。
await collaboration.waitUntilReady(abortSignal);
// ready 表示首轮服务端差量已应用、本地补传已发出，不表示服务端已持久化。

// 页面销毁时执行；不关闭 ctx.bus，不由此销毁业务拥有的 ydoc。
function dispose() {
  collaboration.destroy();
}
```

此客户端代码参考本地 `pre` 提交 `c80d20de57`。其中 `collabError` 当前被统一转换为 `DOCS_SYNC_REJECTED` 并重试，尚未保留服务端 `body.code`；需要按错误码区分“文档缺失/拒绝访问/参数错误”的接入方，应在适配器中补齐本文的错误处理规则，不能假定现有类已经实现该分流。

### 自定义适配器的核心逻辑

自定义适配器使用下面的队列路径；回调中先按完整路由筛选，再处理 `message.action/body`，最后执行本地队列 ACK：

```ts
import type { ISubscribeResult } from '@ccc/core-common';

const instanceId = crypto.randomUUID();
const subscription = { channel: 'Document', topic: docId, instance: instanceId };
const queue = ctx.bus.use('Document').getInstance(docId).getInstance(instanceId);
let receiver: ISubscribeResult | undefined;
receiver = queue.subscribe(message => {
  try {
    const route = message.subscription;
    if (route?.channel !== subscription.channel ||
        route.topic !== docId || route.instance !== instanceId) return;
    handleCollabMessage(message);
  } finally {
    receiver?.acknowledgeMessage(message.messageId);
  }
});
```

`receiver.acknowledgeMessage` 只确认前端本地队列消费，不会确认服务端保存。下列片段展示同步算法，`send` 由适配器实现：检查当前主连接在线，再调用 `ctx.bus.webSocketClient.send({ subscription, action, body })`；离线或发送失败时抛出异常，不进入全局待发送队列。调用方捕获异常并退出 ready 状态。

```ts
import * as Y from 'yjs';
const REMOTE = Symbol('paas-document-remote');

// join 或主动 sync 前暂停实时上行，期间本地修改仍留在同一个 ydoc 中。
function beginSync(action: 'collabJoin' | 'collabSync') {
  ready = false;
  if (action === 'collabJoin') send('subscribe', {});
  send(action, { stateVector: toBase64(Y.encodeStateVector(ydoc)) });
}

// 收到 collabSync，完成双向差量交换的客户端部分。
function receiveSync(body: { data: string; stateVector: string }) {
  Y.applyUpdate(ydoc, fromBase64(body.data), REMOTE);
  send('collabUpdate', {
    data: toBase64(Y.encodeStateAsUpdate(ydoc, fromBase64(body.stateVector)))
  });
  ready = true;
}

function receiveUpdate(body: { data: string }) {
  Y.applyUpdate(ydoc, fromBase64(body.data), REMOTE);
}

const onLocalUpdate = (update: Uint8Array, origin: unknown) => {
  if (online && ready && origin !== REMOTE) {
    send('collabUpdate', { data: toBase64(update) });
  }
};
ydoc.on('update', onLocalUpdate);
```

这是算法片段，`online/ready`、`send`、超时、异常和销毁由适配器维护。只有在线发送成功后才进入本地 ready 状态；发送失败保留 Y.Doc 并重新同步。不要同时启用多个 Provider 向同一房间重复上行。

## Awareness 在线状态

使用 `y-protocols/awareness` 的 `Awareness`、`encodeAwarenessUpdate`、`applyAwarenessUpdate`。状态是 JSON 对象或 `null`；用户资料、光标、选区的内部字段由编辑器绑定层约定。`user`、`cursor` 不是服务端强制字段，也不能作为鉴权依据。

1. 首次正文同步后发送自己的在线状态；只编码本编辑器拥有的 `ydoc.clientID`。
2. 监听 Awareness 的 `update` 事件，包含状态不变时的心跳；仅监听 `change` 会漏掉心跳。
3. 收到 `collabAwareness` 时调用 `applyAwarenessUpdate(awareness, fromBase64(body.data), REMOTE)`，不转发远端状态。
4. 需要快照时发送 `collabQueryAwareness {}`。
5. 重连后提高本地 Awareness 时钟再上报，例如再次调用 `setLocalState(getLocalState())`；重放旧包可能被忽略。

Awareness API 与事件语义见 [Yjs Awareness](https://docs.yjs.dev/api/about-awareness)。服务端每 3 秒检查一次超时，30 秒未收到更高时钟的状态后广播标准 `null` 删除。同一时钟的重复包不刷新存活时间；删除会保留时钟，旧包不能恢复已删除状态。

Awareness 广播不回发原编辑器，但同一主连接上的其他 instance 会收到。leave、unsubscribe、物理断线会清理关联状态；超时只清理在线状态，不移除协同成员。在线状态不落 PostgreSQL，也不改变正文保存计时。

## 断线重连与资源释放

| 场景 | 对接动作 |
| --- | --- |
| 主连接断开 | 设置 offline/未加入，保留 Y.Doc 和本地修改；清除远端在线状态，不逐条缓存旧发送命令 |
| 主连接重新打开或重连 | 对仍挂载的编辑器重新 `subscribe → collabJoin → 双向差量同步`，然后重新上报 Awareness |
| 在线时疑似漏包或发送失败 | 使用 `collabSync` 修复差异；若成员已丢失则重新 join |
| `collabClose` | 退出 ready 状态，保留本地数据，有界重试 join；不关闭主连接 |
| 在线关闭编辑器 | 停止上行，依次发送 `collabLeave`、同 instance 的 `unsubscribe`，释放本实例监听、队列和定时器 |
| 离线关闭编辑器 | 不排队发送旧 leave/unsubscribe；物理断线已经触发清理，取消后续重连 join 回调 |

接收队列用 `receiver.unsubscribe()` 释放，Y.Doc 用 `off('update', handler)` 解绑；移除自己注册的 open/reconnect/close/error 回调。Awareness 由其所有者销毁，Y.Doc 由业务所有者处理。不得取消整个 Document 通道、其他编辑器的订阅，或关闭共享 Socket。

PaaS 重连订阅恢复不替代 CRDT 握手。当前仓库可靠投递配置仅显式开启 `Meeting`，协同回包也未声明需要补偿的投递策略；不能依赖平台缓存恢复所有 Document 更新。状态向量同步是正文恢复入口，必要时周期性同步以修复静默发送失败；现有客户端参考实现每 20 秒执行一次。

遇到旧房间正在销毁，新 join 会等待其完成，单次等待最多 10 秒。客户端同步超时应覆盖这一等待及网络耗时；现有参考实现使用 15 秒。自动重试应有限次、带退避，并避免同一编辑器并发启动多轮握手。

## 错误与大小限制

错误消息示例：

```json
{
  "subscription": {"channel":"Document","topic":"doc-123","instance":"editor-uuid"},
  "action": "collabError",
  "body": {"code":"DOCUMENT_NOT_FOUND","message":"文档不存在"}
}
```

| code | 含义 | 客户端处理 |
| --- | --- | --- |
| `DOCUMENT_NOT_FOUND` | 加载/保存所需的文档记录不存在 | 显示文档不可用，交回业务层确认正式 docId；不在普通打开流程自动创建或 HTTP 恢复 |
| `ACCESS_DENIED` | 协同错误类型中定义的访问拒绝 | 停止自动重试，交回权限流程；当前 WS 主路径没有文档授权校验，不保证权限问题会返回此码 |
| `INVALID_REQUEST` | 缺少 data、非法 Base64、非法正文 update、部分大小/格式校验失败 | 停止原包重试，修复编码/参数，保留本地正文 |
| `INTERNAL_ERROR` | 房间未加入/关闭、队列满、存储或内部异常等 | 有界退避并重新同步；持续失败时提示并记录诊断上下文 |

按 `code` 判断，不解析中文 message。未识别/缺失错误码按协议或未知错误处理，不能当作文档不存在。当前非法 docId/instance 的通用异常也可能映射为 `INTERNAL_ERROR`；客户端仍需提前校验 ID。无订阅、无有效登录或非法外层消息时可能没有结构化回包，应结合超时检查连接和路由。

| 项目 | 当前限制 |
| --- | --- |
| 文档 ID、编辑器 instance | 各最长 128 字符，非空且非纯空白 |
| 入站状态向量 | Base64 解码后最多 64 KiB |
| 单次客户端正文 update | Base64 解码后最多 1 MiB |
| 房间累计编码正文状态 | 最多 32 MiB；不是单帧可发送额度 |
| Awareness 单包及活动快照 | 最多 64 KiB |
| Awareness 单包条目 | 最多 1024 条 |
| 房间 Awareness 记录 | 最多 4096 个 clientID，包含删除时钟 |
| Stateless payload | UTF-8 编码后最多 64 KiB |
| 每条物理连接普通协同命令 | pending 达到 64 条后拒绝新普通命令；leave/unsubscribe/断线清理不受此限制阻挡 |

服务端 `collabSync.data` 是正文差量或完整状态，可能大于 1 MiB；不能把上行单 update 限制当作下行同步上限。Base64 长度为 `4 × ceil(字节数 / 3)`，再加 JSON 开销；1 MiB 二进制约占 1.33 MiB 文本。实际帧还受 PaaS、客户端及代理限制，需按双向最大消息配置和验证。

当前没有应用层分块协议。不能把任意 update 切成字节片段分别作为 `collabUpdate`；每个包必须是合法的完整 V1 update。可用 `Y.mergeUpdates` 合并短时更新，但合并结果仍受单包限制。超限时保留本地数据并提示，不能通过重试同一超限包解决。

## 跨节点同步和保存语义

`doc.collaboration.redis.enabled` 未配置时默认 `true`：正文增量提交到 Redis，经通知与补偿同步到其他服务实例；Awareness 也通过 Redis 发布。客户端无需按 docId 选择服务实例。只有配置为 `false` 时使用单实例本机协同与自动保存，多实例部署不能依赖该模式实现跨节点协作。

Stateless 当前没有 Redis 扩展传播：echo 仅回复请求者，`collabBroadcastStateless` 仅覆盖当前服务实例的同文档其他成员，不适合承载必须到达全体协作者的业务事件。

| 信号或阶段 | 能说明什么 |
| --- | --- |
| PaaS `feedback` | 平台订阅/取消订阅处理结果 |
| 前端队列 ACK | 本地接收队列已消费消息 |
| 客户端 `ready` | 首轮服务端差量已应用、本地差量已提交发送 |
| `collabSyncStatus.synced = true` | 当前 join/sync/update 命令已处理；没有逐操作关联，也不是落库回执 |
| 正文广播 | 该次可广播更新已进入服务端同步链路；不保证所有客户端均已接收 |
| PostgreSQL 保存 | 由服务端后台独立完成，没有客户端入库 ACK |

Redis 模式在末次变更后约 3 秒、或本轮首次未保存变更后约 5 秒安排保存，后台保存器轮询执行；这不是固定时限内持久化成功的保证。最后一个本机编辑器退出会释放本机房间，但不触发 Redis 模式的退出强制落库；保存任务继续独立运行。

显式关闭 Redis 的单实例模式采用相同的 3/5 秒调度，并在房间销毁时补存未保存变更。两种模式都不能在收到 SyncStatus 时显示“已保存到数据库”。

## 联调与排查

| 用例 | 检查结果 |
| --- | --- |
| 单编辑器首开 | 先 subscribe 后 join，收到 collabSync，完成反向差量补传 |
| 两端同时编辑 | 使用同一正式 docId，双方 Y.Doc 收敛，无持续回发循环 |
| 同主连接两个编辑器 | 不同 instance 正确分流；关闭一个不影响另一个 |
| 离线编辑后恢复 | 保留原 Y.Doc，重连完整握手后离线修改合并 |
| Awareness | 显示/更新/清除光标，心跳有效，退出发送删除；不回传其他 clientID |
| 错误 | 缺失文档、非法数据、未 join、无订阅分别表现清楚；未知错误不触发补建 |
| 大文档 | 双向帧大小均验证；超限保留本地数据，不拆分非法 update |
| Redis 多实例 | 不同节点上的编辑器正文和 Awareness 互通；Stateless 按本机范围验收 |
| 保存与释放 | 页面退出不关闭主连接；数据库保存按后台流程检查，不以 SyncStatus 判定 |

常见定位顺序：

1. **主连接打开但没有协同回复**：检查有效登录设备会话、完整路由、非空 instance，以及 `subscribe` 是否先于 join。
2. **只能接收、不能补齐本地内容**：检查收到 collabSync 后是否按服务端 stateVector 补传本地 update。
3. **消息持续回发**：检查远端 `Y.applyUpdate` 的 origin 和本地 update 过滤。
4. **重连后光标不恢复**：检查 Awareness 时钟是否提高，是否错误重放旧包或转发其他 clientID。
5. **跨节点临时消息不互通**：检查是否使用了当前只支持本机广播的 Stateless。

诊断接口为 `GET /doc/collab/rooms/{docId}/status`，使用系统登录会话，接口本身检查文档访问权限。它返回房间、成员、Redis 同步和保存摘要，不创建房间、不读取正文。`complete` 只代表诊断采集完整；`pendingSave`、节点保存状态需结合各自采集时间解读，均不替代每次编辑的保存 ACK。详细字段见[协同模块运行状态说明](../server/src/main/java/org/cses/server/service/doc/collaboration/README.md#room-运行状态查询)。

## 源码入口

| 内容 | 入口 |
| --- | --- |
| 协同 action、Base64 校验、消息封装 | [DocumentSocketDispatcher](../server/src/main/java/org/cses/server/service/doc/collaboration/socket/DocumentSocketDispatcher.java) |
| CSES 登录会话过滤与事件路由 | [WebSocketHandlerDispatcher](../server/src/main/java/org/cses/server/handler/WebSocketHandlerDispatcher.java) |
| 命令处理和 SyncStatus | [DocumentConnection](../server/src/main/java/org/cses/server/service/doc/collaboration/core/DocumentConnection.java) |
| 正文、成员和广播 | [DocumentRoom](../server/src/main/java/org/cses/server/service/doc/collaboration/core/DocumentRoom.java) |
| 房间加载与等待 | [DocumentRoomManager](../server/src/main/java/org/cses/server/service/doc/collaboration/core/DocumentRoomManager.java) |
| Awareness 时钟、归属与上限 | [Awareness](../server/src/main/java/org/cses/server/service/doc/collaboration/protocol/Awareness.java) |
| 错误码及转换 | [CollaborationErrorCode](../server/src/main/java/org/cses/server/service/doc/collaboration/exception/CollaborationErrorCode.java)、[CollaborationException](../server/src/main/java/org/cses/server/service/doc/collaboration/exception/CollaborationException.java) |
| Redis 开关、传播和保存 | [DocumentExtensionFactory](../server/src/main/java/org/cses/server/service/doc/collaboration/config/DocumentExtensionFactory.java)、[RedisDocumentExtension](../server/src/main/java/org/cses/server/service/doc/collaboration/redis/RedisDocumentExtension.java)、[RedisDocumentSaveWorker](../server/src/main/java/org/cses/server/service/doc/collaboration/redis/RedisDocumentSaveWorker.java) |
| 后端协议测试入口 | [DocumentSocketDispatcherTest](../server/src/test/java/org/cses/server/service/doc/collaboration/socket/DocumentSocketDispatcherTest.java) |

PaaS 仓库入口：`websocket/.../WebsocketServer.java`、`handler/SessionRouterHandler.java`、`entry/WebsocketMessage.java`、`delivery/sender/OrderedMessageSender.java`、`session/.../Parser.java`、`store/UserCache.java`。

cses-client 仓库入口：`@ccc/core-common/src/core/event-bus/eventBus.service.ts`、`packages/docs/src/realtime/docs-collaboration-session.ts`、`packages/docs/src/realtime/docs-realtime.service.ts`。客户端章节是对接参考，线上启用状态以目标版本为准。
