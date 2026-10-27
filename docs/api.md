# API 与控制面合同

本文件规定最终核心版本的目标行为，供实现、前端联调和兼容验收使用。接口、示例及能力清单均为设计合同，不表示项目已经实现这些功能。

## 1. 控制面边界

系统面向单人使用，由一个 Node.js 核心进程提供管理 API、Clash API、连接管理和代理转发。最终核心必须交付经过验收的 Caddy forwardproxy HTTP/1.1、HTTP/2、HTTP/3 正向入口；具体部署可以关闭这个入口。Caddy 是允许独立运行的入口进程，不承担机场协议出口或业务路由。

所有管理入口共用同一套配置与运行时对象：

```text
自建 Web /api/v1/* ─┐
                   ├─ ConfigCoordinator / Router / ConnectionRegistry / TrafficMeter
Clash 根路径接口 ───┘                     │
                                       SQLite

Caddy forwardproxy ─ 本机 SOCKS5 bridge ─ Node 代理核心
```

接口分工如下：

| 接口域 | 用途 |
| --- | --- |
| `/api/v1/*` | 单管理员、自己的多组代理凭据、入口、节点、限额、订阅、部署状态 |
| Clash 根路径 | 节点与代理组、选择出口、测速、连接、流量、日志 |
| `/app/` | 自建 Web 静态资源 |
| `/dashboard/` | 固定版本的兼容面板静态资源，若选择随应用分发 |
| Caddy 管理接口 | 仅由部署适配器调用，不转发到公网，不作为应用公共 API |

Clash API 兼容、Clash YAML 导入、机场协议支持是独立能力。一个接口或一种配置格式存在，不表示全部 Mihomo 特性或代理协议均可用。

## 2. 数据类型与公共约定

- 稳定资源 ID 使用 UUID 字符串，名称可修改，引用关系使用 ID。
- 自有 API 使用 camelCase，Clash 接口保留兼容合同要求的原始字段名。
- 自有 API 时间使用 UTC RFC3339 字符串，例如 `2026-10-27T08:00:00.000Z`；界面按用户时区显示。
- 速率单位为字节/秒，流量单位为字节，持续时间字段使用明确的 `Ms` 后缀。
- 自有 API 的持久化累计字节数使用十进制字符串，避免超过 JavaScript 安全整数范围。Clash API 的数值类型按所选兼容合同提供，禁止无说明地改成字符串。
- 上限使用正整数，`null` 表示不启用该项限制，拒绝含糊的负数和未定义的 `0` 语义。
- 节点与代理组名称在 Clash 命名空间中唯一，保留 `DIRECT`、`REJECT`、`GLOBAL`。路径参数按 UTF-8 URL 编码，不能按 `/` 手动拆分名称。
- 配置 revision 使用单调递增的整数。资源分页使用不透明 cursor，默认 50 条，最大 200 条；运行时连接列表最大页长可单独设置为 500。
- 密钥、密码和 token 的读取接口仅返回 `hasSecret`、指纹、轮换时间等元数据。明文只可在创建、轮换、显式授权导出时短暂返回。

自有 API 正常响应：

```json
{
  "data": {},
  "meta": {
    "requestId": "request-uuid",
    "desiredRevision": 42,
    "nodeAppliedRevision": 42,
    "caddyAppliedConfigRevision": 42
  }
}
```

列表响应的 `data` 为数组，`meta.nextCursor` 为下一页 cursor 或 `null`。Caddy revision 与 Node 配置 revision 属于独立命名空间，必须通过 `sourceConfigRevision` 关联，不能直接比较两者数值是否相等。公共摘要中的 `caddyAppliedConfigRevision` 是已应用 Caddy revision 所引用的应用配置 revision，可与 `nodeAppliedRevision` 比较；Caddy 自身的 revision ID 只在组件详情中提供。部署关闭 Caddy 时，该摘要字段为 `null`，状态为 `disabled`；缺少必要配置时为 `notConfigured`。这两种运行状态不取消 HTTP/3 入口的最终交付和验收要求。

自有 API 错误响应：

```json
{
  "error": {
    "code": "REVISION_CONFLICT",
    "message": "配置已被其他页面修改，请重新加载。",
    "details": { "expected": 41, "actual": 42 },
    "requestId": "request-uuid"
  }
}
```

错误体不包含堆栈、文件系统敏感路径或任何凭据。Clash 接口使用兼容目标要求的错误结构，不套用自有 API 的 envelope。

## 3. 鉴权与访问控制

### 3.1 自建 Web

- 仅有一个管理员身份；不提供公开注册、租户或角色管理接口。
- `POST /api/v1/auth/login` 验证密码并创建短期服务端会话。
- 会话 Cookie 使用 `HttpOnly`、`Secure` 和适合部署方式的 `SameSite` 策略；反向代理后的 HTTPS 状态只接受来自可信本机 Caddy 的转发信息。
- 修改操作验证 CSRF token 和 Origin。登录、密码校验、导出及敏感操作有独立速率限制。
- 修改管理密码后撤销旧会话，可保留当前会话的行为必须在操作结果中明确。
- 自有 WebSocket 使用同一管理员身份，但必须独立验证握手认证和 Origin。

### 3.2 Clash 控制接口

- REST 使用 `Authorization: Bearer <secret>`。
- 为浏览器面板支持文档及目标面板使用的 WebSocket `token` 查询参数；查询 token 从访问日志、错误报告和转发日志中脱敏。
- Clash secret 与 Web 管理密码、代理入口凭据分别管理，支持轮换和撤销。
- CORS 使用配置的来源允许列表，不能默认对任意来源开放带凭据访问；预检请求不要求浏览器尚未发送的 Bearer，但实际请求仍必须鉴权。
- WebSocket 除 token 外还检查 Origin；非浏览器客户端无 Origin 的行为通过独立配置决定。
- 代理账号凭据不能调用管理 API，管理 secret 也不能自动作为代理账号密码。

### 3.3 状态码

| 状态码 | 自有 API 语义 |
| --- | --- |
| `200` | 查询、验证或同步运行时操作成功 |
| `201` | 同步创建的非配置资源成功，例如备份记录 |
| `202` | 已接受配置操作或长任务，必须查询 operation 结果 |
| `204` | 无响应体的运行时删除或退出成功 |
| `400` | 请求 JSON、参数或协议格式错误 |
| `401` | 缺少认证或认证失效 |
| `403` | Origin、CSRF、来源或敏感操作授权不满足 |
| `404` | 资源或未知端点不存在 |
| `409` | revision 冲突、资源被引用或部署正在冲突操作 |
| `413` | 配置、订阅或请求体超过大小上限 |
| `422` | 类型正确但配置能力、字段组合或资源关系不合法 |
| `428` | 配置修改缺少 `If-Match` |
| `429` | 管理操作或测速超过限制，附 `Retry-After` |
| `500` | 未预期的内部错误，返回 requestId |
| `501` | 已识别的兼容功能未提供，不能假装成功 |
| `503` | 核心未就绪、正在排空或必要组件不可用 |

Clash 状态码以指定兼容合同的 fixture 为准；本表不能覆盖兼容接口原有语义。

## 4. 配置 revision、影响计划与操作状态

### 4.1 串行配置发布

所有持久配置写入共享一个配置操作队列。写请求必须携带 `If-Match: "42"`，服务端对完整候选配置校验后分配新的 revision。

配置型 POST、PATCH、PUT、DELETE 统一返回 `202`，包含 `operationId`、`targetRevision` 和相关资源 ID。资源创建还返回 `Location`。服务端在返回 `202` 前将操作及其预期 revision、输入摘要、提交来源与恢复策略持久化到 `management_operations`；未分配目标 revision 时 `targetRevision` 为 `null`，分配后查询结果更新。接受响应表示配置操作已持久接受，不表示 Caddy 与 Node 都已生效。

```json
{
  "data": {
    "operationId": "operation-uuid",
    "resourceId": "resource-uuid",
    "targetRevision": 43,
    "state": "queued"
  },
  "meta": { "requestId": "request-uuid", "desiredRevision": 42 }
}
```

`GET /api/v1/operations/:id` 的 `state` 为 `queued | validating | preparing | running | applyingNode | applyingCaddy | verifying | succeeded | failed | rolledBack | requiresRestart | interrupted`，并返回分组件结果、可读错误和受影响连接数量。只有本次计划要求的全部组件均确认目标状态后才进入 `succeeded`；HTTP `202` 不是该终态。单个操作的终态不得从失败悄悄改为成功，重试生成新的 operation。

重启后，配置操作按持久的 pending/applied revision、组件实际配置 hash 和 last-good 策略恢复或收敛，不把上一进程的阶段直接认定为成功。测速、进行中的网络导入、临时流式导出等不能恢复的任务标记 `interrupted`，由用户重新发起；不得无条件重放有外部副作用的任务。已解析并持久化的导入预览可以保留，但重新应用仍检查当前 revision。

三类状态分开表示，禁止互相替代：

| 字段 | 取值与含义 |
| --- | --- |
| `revisionState` | `pending | applied | failed | superseded`，对应 SQLite `config_revisions.state` 或 `caddy_revisions.state` |
| operation `state` | 本次任务的排队、阶段与终态；不直接存成 revisionState |
| `deploymentState` | 当前组件组合的收敛与健康摘要；可以为 partial/degraded，即使某一 revision 曾经 applied |

配置事务写入 `pending`；组件应用确认后才标记对应 revision `applied`；明确失败标记 `failed`；候选被新版本替代使用 `superseded`。某 revision 历史上已应用，不代表进程重启后已经重新验证，也不代表它仍是当前 applied 指针。

### 4.2 影响计划

`POST /api/v1/config/plan` 接收 `baseRevision` 与候选配置或资源变更，返回：

```json
{
  "targetComponents": ["node", "caddy"],
  "nodeAction": "hotApply",
  "caddyAction": "reload",
  "requiresRestart": false,
  "listenerChanges": [],
  "connectionsPolicy": "keepExisting",
  "estimatedAffectedConnections": 0,
  "warnings": []
}
```

`nodeAction` 为 `none | hotApply | rebind | restart`；`caddyAction` 为 `none | reload | restart`。字段中不提供无法测得的停机时间承诺。

- 路由、代理组选择、限额主要作用于新会话。
- 禁用或删除凭据默认断开相关现有会话。
- 修改凭据、节点或规则时，计划明确 `keepExisting | disconnectAffected | drain`，由操作确认参数选择允许的行为。
- 新旧端口可并存时，先准备新监听再发布；同端口更换协议、部分 TLS 或管理监听变化可要求受控重绑定或重启。
- 计划与执行之间再次检查 revision，不能用过期计划修改新配置。

### 4.3 Node 与 SQLite

Node 内可热应用的配置遵循：校验、准备资源、短事务持久化、同步发布已准备的不可变运行时快照、确认生效。准备或提交失败时释放临时资源，旧快照继续服务。

提交后的运行时发布必须短小且不执行网络 I/O。不可恢复的发布错误导致受控退出，重启加载已提交配置；不能返回成功并让数据库与运行时长期分离。

### 4.4 Caddy 的部署一致性

Caddy 是独立进程，SQLite 事务不能原子覆盖 Caddy reload。部署适配器记录以下状态：

```text
desiredRevision
nodeAppliedRevision
caddyDesiredRevision
caddyAppliedRevision
caddyAppliedConfigRevision
lastGoodRevision
deploymentState
```

`deploymentState` 为 `disabled | notConfigured | converged | applying | partial | failed | requiresRestart`。Node 总体健康另有 `ready | draining | degraded | unavailable`，不能用“某配置曾经 applied”推导当前健康。生成的 Caddy JSON 配置通过固定模块合同校验，经本机 Admin API 应用，并对入口执行健康验证；运行时不 spawn Caddy CLI 或其他子进程。

Caddy 自身的 desired/applied/last-good 指针指向 `caddy_revisions`，每条记录保留 `sourceConfigRevision`。`caddyDesiredRevision` 和 `caddyAppliedRevision` 不能当作 Node 的配置 ID；对外比较组件是否运行同一应用配置时使用 `nodeAppliedRevision` 与 `caddyAppliedConfigRevision`。组件无变更时可复用已验证的配置内容，收敛判断结合来源映射与配置 hash，不要求独立 revision 数值相等。

涉及两个组件时按影响计划顺序应用。例如创建入口先准备 Node bridge，再启用 Caddy；删除入口先停止 Caddy 接入，再移除 bridge。失败保留准确的 partial 状态，并尝试恢复上一份已验证配置。无法回滚时明确展示实际 revision，禁止以“保存成功”覆盖运行失败。

`POST /api/v1/deployment/reconcile` 对当前 desired revision 重新收敛；`POST /api/v1/config/rollback` 以指定已验证配置创建一个新的 revision，保留完整操作记录。

`GET /api/v1/deployment` 至少提供如下结构，便于定位“已写入但入口未生效”及 Caddy 被手工修改的情况：

```json
{
  "data": {
    "desiredRevision": 42,
    "nodeAppliedRevision": 42,
    "caddyAppliedConfigRevision": 42,
    "revisionState": "applied",
    "deploymentState": "converged",
    "health": "ready",
    "lastOperationId": "operation-uuid",
    "node": {
      "desiredRevision": 42,
      "appliedRevision": 42,
      "lastGoodRevision": 42,
      "revisionState": "applied",
      "runId": "run-uuid",
      "configHash": "sha256:node-config-digest",
      "verifiedAt": "2026-10-27T08:00:00.000Z",
      "actualListeners": [],
      "pendingListeners": []
    },
    "caddy": {
      "enabled": true,
      "desiredRevision": 7,
      "appliedRevision": 7,
      "lastGoodRevision": 7,
      "sourceConfigRevision": 42,
      "revisionState": "applied",
      "expectedConfigHash": "sha256:caddy-config-digest",
      "observedConfigHash": "sha256:caddy-config-digest",
      "drift": false,
      "adminReachable": true,
      "edgeReady": true,
      "verifiedAt": "2026-10-27T08:00:00.000Z",
      "version": "pinned-caddy-version",
      "moduleCommit": "pinned-forwardproxy-commit"
    },
    "errors": []
  }
}
```

该例省略正常响应的 `meta`，字段中的版本和摘要是占位值。实际监听包含用途、地址、端口、TCP/UDP、入口 ID 与 ready 状态。Caddy 可达不等于出口可用：须分别报告 Admin API、外部 h1/h2/h3 入口与 Node bridge 的验证结果。读取实际配置失败时，`observedConfigHash` 为 `null`、`drift` 为 `null`，展示未知状态，不能猜测为一致。确认漂移或应用结果不确定时暂停受影响桥接入口的新会话，保留错误和恢复入口。

## 5. 自有管理 API 资源

以下路径均位于 `/api/v1`。列表、单项、创建、修改和删除分别使用 GET、GET `/:id`、POST、PATCH `/:id`、DELETE `/:id`，表中列出的动作接口独立定义。

| 资源或路径 | 核心字段和行为 |
| --- | --- |
| `auth/login`、`auth/logout`、`auth/session` | 登录、退出、当前单管理员会话；登录失败不区分用户名与密码错误 |
| `admin/password` | 修改管理员密码，要求当前密码或近期重新认证 |
| `status` | 运行状态、启动时间、运行 revision、连接计数、流量、事件循环指标、组件健康 |
| `capabilities` | 实际入站/出站协议、传输、加密方法、UDP、热更新及 Clash 能力；分别返回 requirement 与 availability |
| `settings` | 全局并发、速率、超时、统计、日志和 DNS 策略 |
| `credentials` | 名称、启用、自己的设备标签、允许入口、有效期、并发与带宽覆盖值；不返回现存明文密码 |
| `credentials/:id/rotate` | 生成或设置新凭据；明确是否断开既有连接 |
| `listeners` | 协议、绑定地址、端口、TLS、凭据引用、默认路由、启用状态、入口用途 |
| `nodes` | 类型、服务器、端口、传输、TLS、凭据引用、UDP 能力；字段按类型鉴别联合校验 |
| `nodes/:id/test` | 启动经节点的受限连通性/延迟测试，返回 operation |
| `groups` | 名称、选择类型、成员、默认选择、探测和失败策略；禁止环和空可用路径 |
| `rules` | 顺序、匹配条件、出口目标、是否启用；批量重排在一个 revision 内完成 |
| `subscriptions` | URL 的受保护引用、格式、更新时间、过滤、节点归属与更新结果 |
| `subscriptions/:id/refresh` | 校验后原子替换该来源的节点集；错误保留原节点 |
| `imports`、`imports/:id` | URI、Clash YAML 或订阅解析报告；区分 recognized、supported、unsupported、invalid，提供字段级原因与来源 |
| `imports/:id/preview`、`imports/:id/apply` | 预览节点、名称、引用与能力变更；按选定条目创建配置 operation |
| `connections` | cursor 分页、入口/凭据/节点/状态筛选，查询内存注册表 |
| `connections/:id` DELETE | 断开单个会话，幂等；返回 `204` |
| `connections` DELETE | 按显式筛选批量断开，返回受影响数量，禁止把空筛选误当成所有 |
| `statistics` | 按时间、入口、凭据、节点查询汇总；持续时间与总量口径明确 |
| `logs` | 分页查询有界日志，支持 level、组件、requestId、connectionId |
| `audit-events` | 配置修改、凭据轮换、部署与备份操作，日志中不含秘密 |
| `config/export` | 导出脱敏配置；带秘密导出要求近期重新认证和显式参数 |
| `config/validate` | 完整配置纯校验，不写库、不拨号、不修改监听 |
| `config/plan`、`config/apply`、`config/rollback` | 影响计划、完整配置应用、创建回滚 revision |
| `deployment` | Node/Caddy desired、applied、健康、失败和重启需求 |
| `deployment/reconcile` | 重试收敛当前期望配置 |
| `deployment/caddy/config` | 生成配置的脱敏预览、配置摘要和固定模块版本 |
| `operations/:id` | 配置、刷新、测速、备份等操作状态 |
| `backups` | 列出和创建一致性备份，默认只包含加密存储的秘密及密钥恢复说明 |
| `backups/:id/restore-plan` | 校验并展示恢复影响，不立即恢复 |
| `backups/:id/restore` | 维护状态中恢复；不允许活动写事务下直接覆盖数据库文件 |

补充规则：

- 资源删除检查引用；默认返回 `409 RESOURCE_IN_USE`，不静默级联删除路由和代理组。
- 节点能力和传输字段必须与真实实现匹配，不能保存任意 JSON 后假定运行时支持。
- `capabilities` 分别提供 `requirement: required | conditional` 和 `availability: available | unavailable`、原因、依赖及互通证据标识。部署关闭的能力可为 available 但 enabled=false；必需能力 unavailable 时阻止“最终核心验收通过”。
- 导入器保留不能运行的节点为 `unsupported` 诊断记录，提供协议、传输、加密、缺失字段与未知字段的具体原因。秘密字段脱敏或按存储合同加密；记录不能被路由或代理组选中，不能用默认协议替代。
- `unsupported` 不是语法解析失败。整体格式非法或下载失败保留原来源的已应用节点；合法导入中的 unsupported 条目显示在预览和诊断列表，支持的条目只有通过显式应用才进入配置。订阅自动更新也使用同样的能力检查与稳定合并合同。
- 外部订阅、测速 URL、配置导入均有大小、超时、并发和重定向限制；本机管理端口与自环代理目标不可作为未经授权的探测目标。
- 普通流量统计允许按周期批量落盘，自有 API 暴露 `lastPersistedAt` 和崩溃丢失窗口；不将此统计描述成精确计费账本。
- `GET /api/v1/statistics` 支持 UTC 的 `from`（含）、`to`（不含）、`granularity=hour` 及全局/入口/凭据/出口维度。小时历史来自 `usage_buckets`，累计来自 totals；各维度是独立视图，不能相加得到全局总量。响应明确 `persistedThrough`、粒度与缺失区间，不用当前速率倒推历史。旧节点删除后的历史保留稳定主体 ID 和必要的名称快照。
- `status` 和 `deployment` 始终能区分服务正常、排空、组件失效和配置未收敛。

### 5.1 生命周期命令

`POST /api/v1/system/drain` 同步进入拒绝新会话的排空状态，返回 `200` 和排空期限；已有会话按期限继续运行。`POST /api/v1/system/resume` 仅在配置和组件健康时恢复接入。`POST /api/v1/system/shutdown` 先同步进入 draining、持久记录停机意图并返回 `200` 的命令接受状态，再执行最终 flush 和退出；响应不表示进程已经退出。这些是运行命令，不套用配置变更的 `202` 合同。所有命令要求管理员认证与 CSRF/Origin 检查，Clash token 不获得隐含的停机权限。

## 6. Clash REST 兼容矩阵

合同名称为 `clash-core`，目标面板版本及全部请求样本放入实现时的兼容 fixtures。基础 Clash 行为与 Mihomo 扩展分别登记。

| 方法与路径 | 合同 | 实际语义与成功响应 |
| --- | --- | --- |
| `GET /version` | 基础 | 返回项目实际版本；不伪造 Mihomo 版本或 `meta:true` |
| `GET /configs` | 基础 | 返回真实运行配置；端口仅映射指定的兼容主入口 |
| `PATCH /configs` | 基础 | 同步修改已声明支持的热字段；按 fixture 返回成功状态，失败不能只持久化而不应用 |
| `PUT /configs` | 配置导入扩展 | 只有导入器能完整验证并应用对应格式时才支持；否则明确 `501` |
| `GET /proxies` | 基础 | `{ "proxies": { "名称": { ... } } }`，包含真实节点与代理组 |
| `GET /proxies/:name` | 基础 | 单节点或组；名称按兼容规则查找，未知名称返回相应错误 |
| `PUT /proxies/:name` | 基础 | 请求体 `{ "name": "组内节点名" }`；只允许选择真实成员，成功后影响新连接 |
| `GET /proxies/:name/delay` | 基础 | 支持 `url`、`timeout` 等所选合同参数，返回实际代理路径延迟 |
| `GET /rules` | 基础 | 返回运行时生效的规则类型、内容与出口，字段按 fixture |
| `GET /connections` | 基础 | 返回活跃会话快照和本次运行的累计流量 |
| `DELETE /connections/:id` | 基础 | 关闭并释放指定会话，成功 `204`，重复调用按固定兼容行为处理 |
| `DELETE /connections` | 基础 | 关闭全部代理会话，成功 `204`；不会顺带关闭管理 WebSocket |
| `GET /traffic` | 基础流 | 持续输出兼容流量样本，参见流式合同 |
| `GET /logs` | 基础流 | 持续输出兼容日志，支持 level 过滤 |
| `GET /memory` | 面板所需扩展 | 统计口径和字段与目标合同对齐，不把 V8 heap 冒充整个进程 RSS |
| `GET /providers/proxies`、`GET /providers/proxies/:name` | provider 扩展 | 将订阅来源映射为真实 provider，查询归属、更新时间、节点和健康结果 |
| `PUT /providers/proxies/:name` | provider 扩展 | 刷新对应来源，失败保留现有节点 |
| `GET /providers/proxies/:name/healthcheck` | provider 扩展 | 对对应来源执行有界健康检查，不绕过探测并发限制 |
| `/group/*`、`/providers/rules/*`、`/dns/query`、`/cache/*` | Mihomo 扩展 | 按能力登记单独实现；未实现时返回明确错误 |
| `/restart`、`/upgrade*`、TUN/Geo/脚本相关操作 | 生命周期或内核扩展 | 不从端点名称推导能力；未提供的操作明确拒绝 |

`PATCH /configs` 的可写字段由能力清单逐项公布。`mode` 的 `rule | global | direct` 必须映射真实路由行为；`log-level` 必须更新真实日志过滤。只读结构字段、Caddy 管理的监听字段和要求重启的变更应被明确拒绝，并引导自己的 Web 使用影响计划。不能通过 Clash 接口返回 `204` 后异步失败。

Clash 修改也经过统一 ConfigCoordinator。兼容请求没有项目 revision 时，控制面在同一串行队列内获取当前 revision 后执行单项修改；服务端仍保证与 Web 配置操作不会相互覆盖。Clash 同步请求只接受能在请求期限内完成的原子热变更。

Clash 名称和组成员必须对应真实可用路径。`udp`、`alive`、`history` 等字段描述真实能力与探测结果；未知或不适用的信息不能填成看似成功的默认值。

## 7. HTTP 流与 WebSocket 合同

### 7.1 端点

| 路径 | HTTP GET | WebSocket |
| --- | --- | --- |
| `/traffic` | 连续 JSON 行，按目标 fixture 发送 | 每条消息一个 JSON 流量样本 |
| `/logs` | 连续 JSON 行 | 每条消息一个日志对象 |
| `/connections` | 单次 JSON 快照 | 定时推送完整兼容快照 |
| `/memory` | 所选面板要求的采样行为 | 若合同要求，发送对应内存样本 |
| `/api/v1/events` | 不定义为 Clash 流 | 自有带事件类型和 revision 的事件消息 |

HTTP 流使用适合的流式响应类型，禁止把 NDJSON 包装成 JSON 数组。WebSocket 消息中不添加自有 envelope。Clash 基础日志常见形式为 `{ "type": "info", "payload": "..." }`，实际 level、时间及结构化扩展按固定 fixture。

`/connections?interval=1000` 默认每秒刷新。服务端给 interval 设置合理下限与上限，超界返回参数错误；面板正常默认值必须可用。流量默认每秒采样一次，`up`、`down` 表示字节/秒，累计字段只在合同支持时附加。

### 7.2 运行时约束

- 中央采样器生成一次快照并广播，不为每个面板重复遍历全部会话。
- 流量、连接和日志分别有有界订阅数、采样频率与待发送队列。
- HTTP 写入尊重背压；WebSocket 超过待发送上限时关闭慢消费者，不无限缓存。
- 连接关闭、认证撤销、进程排空时清理计时器和订阅。
- 管理流量、测速与订阅更新不计入普通代理账号的业务流量；探测会话单独标记并受系统资源上限约束。
- 自有事件消息包含 `eventId`、`type`、`time`、`revision`、`data`；断线重连后先获取完整状态，不能假定内存事件队列是持久消息日志。

### 7.3 连接字段

Clash 快照包含合同要求的 `uploadTotal`、`downloadTotal`、`connections`，单会话包含 ID、metadata、上传下载字节、开始时间、代理链和命中规则等信息。

字段类型和方向以 golden fixture 固定，尤其验证：

- `start` 是 RFC3339 字符串还是其他类型，不直接采用二手摘要。
- source/destination 端口是整数还是字符串。
- `chains` 顺序、规则名称、空列表和无规则的表示。
- TCP、UDP、桥接入口的 metadata 类型和 `network` 值。
- 上传为客户端到目标方向，下载为目标到客户端方向；加密开销与应用载荷不能混用。
- 只有真正存在的客户端进程信息才填写 process 字段；Windows 服务器通常不能知道远端设备的进程名称。

## 8. Caddy 入口合同

### 8.1 两类代理职责

标准 Caddy `reverse_proxy` 负责自建 Web、Clash REST、HTTP 流和 WebSocket，能够在外层使用 HTTP/1.1、HTTP/2、HTTP/3。该能力不能自动推导为普通 CONNECT 正向代理能力。

HTTP 正向代理使用固定版本的 `caddyserver/forwardproxy` 扩展。h1/h2/h3 入口及其 Node bridge 是最终核心必需交付能力，部署时可以关闭。其路径为：

```text
客户端 h1/h2/h3
  → Caddy forwardproxy 认证与外层流
  → socks5://127.0.0.1:<bridgePort>
  → Node loopback bridge
  → 统一并发/带宽/路由/上游
```

Node bridge 仅绑定 `127.0.0.1`；如确需 IPv6，单独绑定 `::1`。它使用无认证 SOCKS5，固定映射内部 `edge-owner` 身份，只允许 Caddy 或本机可信进程使用。公共 SOCKS5 入口使用独立监听和正常认证。桥接端口不得绑定所有网卡或由公网端口转发暴露。

固定 loopback upstream URL 不包含用户名密码。该决策同时避免在未经审计的 forwardproxy 普通 HTTP upstream 路径中把内部凭据重新放入 `Proxy-Authorization`。

### 8.2 原始身份与限制

原版固定 upstream 链路不会通过 SOCKS5 自动传递原始 Caddy 用户名、真实客户端 IP、HTTP 主版本或 QUIC 会话 ID。Node 应将其记录为 `edge-owner` 和桥接来源。界面可显示来源为 Caddy，但不能伪造已获知的远端身份。

因此通过 Caddy 的全部会话共用 edge-owner 的连接与带宽额度。自己设备的独立凭据配额通过直接 Node 入口实现；本合同不包含额外身份传递协议或自行开发的 Go 适配器，不能声称现有链路已支持这些能力。

一条 HTTP/2 或 HTTP/3 CONNECT 流对应一条 Node 桥接 TCP 会话。外层只有一个 QUIC 连接时，里面的多条隧道仍分别占代理会话额度。

该路径只提供 TCP CONNECT。它不提供 CONNECT-UDP、MASQUE 或通过 HTTP/3 自动转发 SOCKS5/SS UDP。UDP 通过 Node 明确配置的 UDP 入口和支持 UDP 的上游处理。

### 8.3 普通 HTTP 的验收门槛

forwardproxy upstream 模式必须按固定源码版本审计和测试，不能只验证 CONNECT：

1. 普通 HTTP 转发不会把客户端代理凭据或内部凭据发送到目标。
2. 请求完成、取消、读取错误和写入错误后，底层 loopback Socket 被关闭或按合同回收。
3. `response.Body.Close()` 不被未经验证地当作原始网络连接关闭。
4. 请求体和响应体遵守背压，不把任意大小请求一次性缓存在内存。
5. 当前 upstream 普通 HTTP 路径是否每次请求新建连接、是否存在连接池，必须记录在固定模块的验收报告中；计数定义使用真实存活代理会话，而不是假定一请求永远等于一连接。
6. 上游失败必须返回错误，不能绕过 Node 直接连接目标。
7. 域名保持到 Node，目标地址、端口与自环策略由 Node 执行。
8. 模块若有上述行为缺口，选择已包含上游修复、满足合同的受维护构建并重新验收；没有符合合同的构建时，HTTP/3 入口的发布验收保持阻断。此设计不默认为项目增加自行编写 Go 模块或补丁的开发范围，也不能把缺口标成已解决。

模块本身标注 experimental，应固定 Caddy 版本、模块 commit、构建摘要和 Windows 可执行文件摘要。替换版本必须重新执行入口协议与凭据泄漏回归测试。

### 8.4 WebSocket 与代理元数据

Web/Clash 的标准反向代理路径可以配置可信转发头；信任范围限定为本机 Caddy。Node 直接公网入口不能信任任意客户端提供的 `X-Forwarded-For`。

该信任机制只适用于 HTTP 管理请求，不会让 SOCKS5 bridge 获得原始代理客户端地址。两类来源必须分别显示。

## 9. 兼容验收清单

选择一个固定版本的 yacd 或 MetaCubeXD 作为发布验收对象，保存其版本、静态资源摘要及实际请求回放。需要额外面板时，为每个面板增加独立合同。

| 验收项 | 通过条件 |
| --- | --- |
| 版本与能力 | 不伪造内核身份；面板只进入真实支持的功能路径 |
| 鉴权 | REST、WS、HTTP 流均不能绕过；token 不出现在日志和错误体 |
| 节点切换 | 面板选择后，新的真实连接经过所选节点；旧连接行为符合合同 |
| 测速 | 测试目标请求确实经过指定节点，失败和超时不是零延迟成功 |
| 连接管理 | 单条及全部断开会实际关闭数据通道，并恰好释放一次额度 |
| 统计 | 上传下载方向、累计口径、时间格式与 fixture 一致 |
| 配置冲突 | 两个页面用同一旧 revision 修改时，只有一个可以提交 |
| 配置失败 | 无效路由、节点、端口和 Caddy 配置不会被显示为已生效 |
| Caddy 状态 | desired/applied revision、partial、回滚失败均能观察并恢复 |
| h1/h2/h3 CONNECT | 真实客户端建立隧道、传输、取消；多流分别计数 |
| 普通 HTTP | 不泄漏代理凭据，不遗留 bridge Socket；与 CONNECT 分别覆盖 |
| UDP 边界 | HTTP/3 TCP CONNECT 不被宣称为 UDP 支持；UDP 使用独立验收 |
| 慢面板 | 慢 WS/HTTP 流消费者不能无限增长内存或阻塞代理转发 |
| 不支持的接口 | 有稳定错误行为，不返回伪造成功或不存在的数据 |

## 10. 官方参考与证据固定

- [Mihomo API 文档](https://wiki.metacubex.one/api/)
- [Mihomo 文档源](https://github.com/metacubex/meta-docs/blob/main/docs/api/index.md)
- [Caddy reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Caddy forwardproxy README](https://github.com/caddyserver/forwardproxy/blob/master/README.md)
- [Caddy forwardproxy 源码](https://github.com/caddyserver/forwardproxy/blob/master/forwardproxy.go)

实现时把实际采用的 commit、面板版本及响应样本固定到测试资料中。文档或源码主分支的变化不能自动改变本项目已发布的 API 合同。
