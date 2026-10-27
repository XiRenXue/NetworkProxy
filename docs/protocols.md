# 协议能力与连接转发设计

本文定义 NetworkProxy 最终核心版本的协议目标、传输组合、运行时不变量和验收条件。本文是待实现的设计契约；能力表中的“支持”表示最终核心应完成的范围，不表示当前仓库已有实现或已通过互通测试。

## 1. 设计约束

- Windows Server 部署，支持多租户，一个 Node.js 核心应用进程；原生入口、机场协议、业务认证、路由、加解密及出口连接均在本进程中完成。
- TypeScript 编写协议和业务代码。允许使用经过审查的进程内密码学、SSH、WebSocket 等库；这些库不替代本项目的连接管理和代理内核。
- SQLite 保存配置及汇总统计；活跃连接、配额、限速器和实时统计由进程内统一运行时维护。
- 自建 Web 和 Clash API 共用同一个运行时；每次操作从认证上下文取得租户范围，不复制连接表、节点选择或计数器，不向租户暴露平台总视图。
- Caddy 是最终核心已经选定的 HTTPS/HTTP/2/HTTP/3 边缘入口，使用固定的 `forwardproxy` 扩展构建；它终止外部 HTTP 代理协议并通过本机 SOCKS5 bridge 接入 Node，不承担机场协议出口或本项目的业务路由。一次部署可以停用 Caddy 入口，但最终交付必须包含配置、运行和 h1/h2/h3 互通验收证据。
- 不进行用户 HTTPS 中间人解密，不安装用户根证书，不修改隧道内部 TLS 流量。
- 租户是路由、凭据、节点、订阅、缓存、连接、统计与配额的隔离单位。同一进程共享 OS 资源和故障域；逻辑隔离不等于进程级 CPU、内存或崩溃隔离。

## 2. 能力是组合，不是协议名称

节点必须以结构化能力表示，不能仅保存 `type: vless` 或 `type: shadowsocks` 后就认为所有变体都能连接。

```ts
type PayloadNetwork = 'tcp' | 'udp';
type Carrier = 'tcp' | 'tls' | 'ws' | 'wss' | 'h2' | 'grpc' | 'httpupgrade';
interface ProtocolCapabilities {
  tcp: boolean;
  udp: 'none' | 'native' | 'framed-stream' | 'quic-datagram';
  domainTarget: boolean;
  ipv6Target: boolean;
}

interface TransportDescriptor {
  carrier: Carrier;
  tls: boolean;
  // 由对应协议适配器给出，不从订阅字段猜测。
  supportedFeatures: readonly string[];
}
```

公共 `ProtocolCapabilities` 与 [design.md](design.md) 一致；`TransportDescriptor` 补充具体承载和功能参数。`carrier` 描述承载代理协议的连接，`PayloadNetwork` 描述被代理的目标流量。例如 VLESS 的 UDP 命令通过 TLS TCP 连接承载时，目标是 UDP，载体仍是可靠有序的 TCP 流。节点列表必须同时展示这两项。

每个节点导入、保存及启用时执行相同的能力校验：协议、密码方法、传输、TLS 参数、流控、UDP 编码和插件必须属于一个已支持的组合。不认识的字段不能静默忽略；不支持组合保存为 `unsupported`，显示字段级原因，并禁止被路由选中。

`CapabilityRegistry` 分别记录 `requirement=required|conditional` 和 `availability=available|unavailable`，并附原因。HTTP/1.1、原生 HTTP/2、Caddy HTTP/3、SOCKS5、SS2017、指定 SS2022 AES、Trojan、VMess AEAD、VLESS 基础命令和 SSH TCP 属于本文最终核心的交付目标；不能通过把尚未完成的必需项标成不可用来通过最终验收。条件能力可以明确报告不可用及其依赖条件。

## 3. 入站能力矩阵

| 入站 | TCP 代理 | UDP 代理 | 身份来源 | 最终核心边界 |
|---|---|---|---|---|
| HTTP/1.1 | 正向 HTTP、标准 CONNECT、经验证的标准 WebSocket Upgrade | 无 | 每请求 Proxy-Authorization，用户名包含租户命名空间 | 支持绝对 URI、IPv4/IPv6/域名目标、持久连接；Upgrade 后为一个持续代理会话 |
| HTTPS HTTP/1.1 | 同上 | 无 | TLS 后执行代理认证 | TLS 在 Node 或 Caddy 终止 |
| HTTP/2 代理 | 普通 HTTP 请求流正向转发、每个 CONNECT 流独立建立 TCP 隧道 | 无 | 每个 HTTP/2 流独立认证为租户和凭据 | Node `http2` 原生实现，两类请求均为最终目标；不可把首条流身份复用给其他流；不默认支持 h2 扩展 CONNECT/WebSocket |
| SOCKS5 | CONNECT | UDP ASSOCIATE | 带租户命名空间的用户名密码；专用本机 bridge 可用固定租户身份 NOAUTH | 不实现 BIND；UDP 分片 `FRAG != 0` 丢弃并记录原因 |
| Shadowsocks AEAD2017 | 支持 | 支持 | 专用入口绑定的租户与凭据/密钥 | 下表列出的三种 AEAD 方法；每个租户的每组密钥使用独立端口 |
| Shadowsocks 2022 | 支持 | 支持 | 专用入口绑定的租户与凭据/密钥 | 仅明确列出的两种 AES 方法和单用户协议；2022 独立编解码，不用同端口猜测租户 |
| Caddy HTTP/1.1 / HTTP/2 / HTTP/3 | 普通 HTTP 正向请求、CONNECT 到 TCP 目标，均通过租户专用本机 SOCKS5 bridge | 无 CONNECT-UDP | Caddy 专用外部端口认证后映射该租户的内部 `edge-owner` | 最终交付必须验证 h1/h2/h3；Node 按实际桥接 TCP 隧道计数，不假定获得外部用户名或流边界 |

HTTP/1.1、HTTP/2 可以使用独立监听器，也可以在同一个 TLS 监听器通过 ALPN 选择。HTTP 和 SOCKS5 可提供显式 `mixed` TCP 监听器；其前导识别必须受握手缓冲及期限限制，不能无限等待以猜测协议。

管理 API、Clash API 和代理入口使用独立路由与认证边界，不因共用 Node 进程而共享匿名访问权限。

### 3.1 共享原生入口的租户识别

共享 HTTP/SOCKS5 监听器的线上用户名为 `immutableTenantSlug~username`。租户 slug 由平台分配并在创建后不可变，使用规范化的小写 ASCII 命名；凭据用户名禁止 `~` 并校验 SOCKS5 的 255 字节长度限制。认证器先解析命名空间，再在该租户授权给当前监听器的凭据集合中验证密码，产出不可变的 `(tenantId, credentialId)`；不从请求头中的任意 tenantId、目标域名、客户端 IP 或未经验证的转发字段推断租户。

HTTP 每个普通请求、CONNECT 和 Upgrade 都独立认证；h2 每个 stream 独立认证。共享 Socket 只承担平台级物理资源限制，首个请求/流的租户不能授权后续流。没有授权给共享监听器的租户即使知道正确密码也不得接入。SOCKS5 一个控制连接认证一次，后续 TCP/UDP 工作继承同一租户上下文。

SS 没有通用用户名字段，采用平台分配的独立 TCP/UDP 端口映射租户与密钥。平台不得为不同租户配置同一入站有效密钥材料，避免报文跨端口重放、身份歧义与缓存隔离失效。密钥在租户私有上游间的使用仍以独立连接上下文处理。

## 4. 出站能力矩阵

| 出站 | 代理 TCP | 代理 UDP | 目标域名交给上游 | 传输范围 |
|---|---|---|---|---|
| HTTP/1.1 CONNECT | 支持 | 不支持 | 支持 authority 域名 | TCP 或 TLS；上游必须允许相应 CONNECT 目标端口 |
| HTTP/2 CONNECT | 支持 | 不支持 | 支持 authority 域名 | TLS + ALPN h2；每个 CONNECT 使用独立 stream；可复用受限数量的 h2 session |
| SOCKS5 | CONNECT | UDP ASSOCIATE | 支持域名 ATYP | TCP 控制连接 + 原生 UDP 数据报 |
| Shadowsocks AEAD2017 | 支持 | 支持 | 支持域名地址编码 | 原生 TCP/UDP；不隐式启用插件 |
| Shadowsocks 2022 AES | 支持 | 支持 | 支持域名地址编码 | 原生 TCP/UDP；独立的 2022 报文、派生、时间及重放语义 |
| Trojan | 支持 | 支持 | 支持协议地址字段 | 标准 Trojan + TLS；UDP 使用协议数据报在流中封装 |
| VMess AEAD | 支持 | 支持 | 支持协议地址字段 | TCP/TLS/WS/WSS，以及通过明确兼容配置启用的标准 gRPC/HTTPUpgrade |
| VLESS | 支持 | 支持基础 UDP 命令 | 支持协议地址字段 | TCP/TLS/WS/WSS，以及通过明确兼容配置启用的标准 gRPC/HTTPUpgrade；不启用 XUDP/Mux/Vision |
| SSH direct-tcpip | 支持 | 不支持 | 由 SSH 服务端处理目标主机 | SSH2 TCP；主机密钥校验、密码或私钥认证；不运行外部 ssh.exe |
| DIRECT | 支持 | 支持 | 本机解析 | 显式配置才允许；默认路由不使用失败直连 |
| REJECT | 拒绝 | 丢弃/拒绝关联 | 无 | 用于明确的规则终止和无可用出口 |

SSH 通过进程内协议库实现 `direct-tcpip` channel。库的固定版本、Windows 支持、主机密钥指纹、私钥格式和互通样本需要进入发布证据；依赖库不支持的算法不显示为可选算法。

HTTP 上游可能允许普通绝对 URI 转发，但拒绝 CONNECT 到某些端口。统一 `dialTcp()` 合约要求建立透明 TCP 隧道，因此 HTTP CONNECT 适配器应将上游拒绝作为真实失败。不能把“HTTP 代理端口可连接”报告成对所有目标可用，也不能在失败后自动改走 DIRECT。

## 5. 传输组合白名单

协议和承载层分别建模，但只开放经过协议实现和互通验证的组合。

| 协议 | 原生 TCP | TLS | WS/WSS | 标准 gRPC | HTTPUpgrade |
|---|---|---|---|---|---|
| HTTP CONNECT | 是 | 是 | 否 | 否 | 否 |
| HTTP/2 CONNECT | 否 | 是，ALPN h2 | 否 | 否 | 否 |
| SOCKS5 | 是 | 不作为通用机场参数开放 | 否 | 否 | 否 |
| SS2017 / SS2022 | 是 | 不隐式套 TLS | 不隐式支持 SIP003 插件 | 否 | 否 |
| Trojan | 否；核心要求 TLS | 是 | 不纳入标准 Trojan 配置 | 否 | 否 |
| VMess AEAD | 是 | 是 | 是 | 是，明确 serviceName/mode | 是，明确 Host/path |
| VLESS | 是 | 是 | 是 | 是，明确 serviceName/mode | 是，明确 Host/path |
| SSH | SSH 自身协商 | 不另套通用 TLS | 否 | 否 | 否 |

这里的 gRPC/HTTPUpgrade 指对应代理实现定义的兼容传输，不表示任意 gRPC 服务或任意 HTTP Upgrade 服务都可承载 VMess/VLESS。每一组合需要固定以下参数与行为：

- gRPC：服务名、方法路径、消息封装、单流/多流模式、TLS/ALPN、流取消、响应 trailers 和错误码。多流/Mux 未验证时不启用该模式。
- HTTPUpgrade：Host、path、预期升级响应、升级后预读数据、TLS、服务端兼容实现。它与 WebSocket 是不同载体。
- WebSocket：HTTP 升级验证、Host/path、TLS/SNI、二进制数据、ping/pong、关闭码、帧/消息长度限制；以连续字节流向协议适配器暴露数据，不把 WS 消息边界当成代理报文边界。
- TLS：SNI、ALPN、受信根或指定 CA、证书主机名验证、握手超时。默认验证证书；自定义 CA 是支持的明确配置。

为实现互操作确实需要的自定义请求头必须通过白名单和长度限制；不允许覆盖由载体生成的握手关键字段。

## 6. Shadowsocks 的精确范围

### 6.1 AEAD2017

最终核心支持的协议方法名称为：

- `aes-128-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`

协议方法名与 Node/OpenSSL 算法名分别映射，不能直接当作同一个字符串。实现覆盖密码/主密钥派生、salt、每连接子密钥、nonce、TCP 加密长度和载荷记录、UDP 独立数据报认证、地址编码及重放防护。

每个 TCP 方向独立维护密钥与 nonce 状态；必须先验证完整 AEAD 记录，再把这条记录的明文交给下一层。认证失败立即终止，不能尝试跳过损坏字节继续同步。随机 salt 必须来自安全随机源，禁止复用。

### 6.2 SS2022

最终核心支持：

- `2022-blake3-aes-128-gcm`
- `2022-blake3-aes-256-gcm`

SS2022 必须是独立的协议编解码器，实现规范中的 BLAKE3 派生、固定/可变头、时间校验、会话标识、数据报编号及重放检查。不能通过替换 AEAD 方法或直接复用 AEAD2017 报文实现。

密钥输入按方法规定的原始长度和 Base64 编码严格校验。仅支持一入口一身份；不解析多用户身份头链，不宣称支持任意 SS2022 多用户服务器配置。`2022-blake3-chacha20-poly1305` 不属于本文确定的核心方法。

BLAKE3 使用固定版本、进程内、经过测试向量验证的实现；密码库提供原语，本项目负责协议语义。安装和构建不得隐式下载外部代理内核。

### 6.3 凭据与重放状态

每个租户的不同设备可以使用不同的 SS 端口/密钥，每个入口映射不可变的租户与业务凭据 ID，与该租户的 HTTP/SOCKS 共享租户级及凭据级并发、流量限制。物理端口由平台分配，租户不能自行绑定任意地址或抢占其他租户端口。

重放缓存以租户和实际密钥指纹为分区；同租户同密钥的监听器必须共享该密钥的重放域，跨租户入站重复有效密钥被配置验证拒绝。缓存具有规范要求的时间窗、容量和淘汰规则；超过容量时拒绝新会话并记录资源原因，不能为了腾空间而无限缩短有效防护窗口。密钥轮换创建新状态空间。仅保存在内存的缓存重启后会丢失，必须在协议实现评审中记录该行为；SS2022 时间窗校验仍然执行，不将重启视作绕过认证或时间检查的理由。

## 7. 明确的能力扩展边界

以下内容不因支持同名基础协议而自动可用：

| 能力 | 本文最终核心结论 | 原因与重新纳入条件 |
|---|---|---|
| AnyTLS | 条件能力，当前未标记可用 | 需要独立的会话复用、认证、padding 和兼容规范；不能等同于 Trojan/TLS。只有确定协议版本、UDP 语义与互通样本后才可加入可用能力 |
| VLESS REALITY / XTLS Vision | 条件能力，当前基线未提供 | 独立握手和 TLS 行为要求，不能用普通 `tls.connect()`、SNI 或修改 cipher 替代；必须有符合单进程约束的实现和独立互通证据 |
| Hysteria2、TUIC | 条件能力，当前基线不可用 | 依赖合适的 QUIC 协议栈、拥塞/认证/数据报语义；必须验证实际 Node 发布产物及进程内实现，不能据实验分支文档宣称可用 |
| 原生 Node HTTP/3 代理 | 当前基线不可用；不替代已经选定的 Caddy H3 | 2026-10-27 本机 Node v24.15.0 Windows x64 使用 `--experimental-quic` 导入 `node:quic` 实测为 `ERR_UNKNOWN_BUILTIN_MODULE`；该结果只约束这个二进制，不推断 Windows 整体能力 |
| CONNECT-UDP / MASQUE | 不支持 | HTTP/3 CONNECT TCP 隧道不等于 UDP 代理；需要独立实现 HTTP Datagram、Capsule 和对应协商 |
| WireGuard | 条件能力，当前基线未提供 | 独立隧道与网络栈语义，不属于通用 TCP 代理适配器；需满足进程内实现和目标部署环境要求 |
| SSR、SS 插件、ShadowTLS | 不支持 | 独立的认证/混淆或外部传输协议；不能通过忽略订阅字段达到兼容 |
| VMess 旧 alterId / Mux、VLESS XUDP / Mux | 不支持 | 与已确定的 AEAD/基础命令不同；会改变会话、UDP 和资源计数语义 |
| 任意代理链嵌套 | 不开放任意图 | 核心路由选一个最终出口；受控组合如 Caddy bridge、SSH channel 属于明确载体，防止环路和无限拨号 |

这些是能力边界，不是迭代路线。最终发布应公布真实能力清单；未达到白名单和验收要求的条目不能伪装为健康节点。

## 8. Caddy 边缘接入与 bridge

最终核心选定的边缘拓扑（允许按部署配置停用，交付仍须验收）：

```text
租户 A 客户端 -> Caddy :1443 (TCP/UDP) -> 127.0.0.1:11081 -> tenant-A / edge-owner
租户 B 客户端 -> Caddy :2443 (TCP/UDP) -> 127.0.0.1:11082 -> tenant-B / edge-owner
                                                         -> 各租户准入/路由/上游
```

必须使用确实包含并支持相应功能的 Caddy `forwardproxy` 构建；普通反向代理配置不能替代正向代理 CONNECT。Caddy 组件及其模块版本进入部署清单，启动检查验证本机 bridge 可达，最终验收分别验证 h1/h2/h3。`upstream` 必须指向 Node bridge；缺失、失联或模块行为不符合契约时拒绝转发，禁止绕过 Node 默认直连。

每个租户必须具有独立的 Caddy 外部监听端口和独立 Node loopback bridge，映射在平台受管配置中固定为该租户的内部凭据。`edge-owner` 仅是租户内名称，可以在不同租户重复，运行时键始终为 `(tenantId, credentialId)`。bridge 只绑定 `127.0.0.1` / 显式 `::1`，不得默认绑定所有接口；NOAUTH 意味着信任本机调用方，不保证 Node 能区分 Caddy 与其他有本机访问权限的进程。

该端口映射是当前扩展合同下的租户身份边界。SNI/域名只完成 TLS 站点选择，CONNECT 的 authority 是目标站点；不能只靠请求 Host/SNI 或一个公共 `forwardproxy` 的认证用户名，把多个租户自动转到不同 upstream。原版固定 upstream 不透传原始用户名，因而“同一外部端口、不同用户名、统一 NOAUTH bridge”不属于支持拓扑。需要共用端口的租户应使用原生 Node h1/h2 入口；不能为解决此问题暗中引入新的 Go 认证模块。

每个 Caddy 站点只接受其对应租户的外部凭据，禁止将租户 A 的凭据复制到租户 B 站点。CaddyController 在暂停租户时停止该站点新接入；Node 同时拒绝其 bridge 身份，不能仅等待 Caddy reload 生效。

一个实际存活的 Caddy 到 bridge TCP 隧道计为一个 Node TCP 代理会话。外部 CONNECT 通常对应独立桥接隧道，应以互通测试确认；普通 HTTP 请求可能在 Caddy 内复用上游连接，Node 不能按未传递的外部请求/流个数计数。bridge 的额度限制的是 Node 实际接收的隧道数，外部 HTTP/2/HTTP/3 并发流和预认证资源另由 Caddy 层约束。

Node 看到的源地址是 Caddy，本机 bridge 不承诺保留终端客户端 IP、HTTP 版本、请求数或原始设备凭据；这些字段显示为“边缘代理/未知”，不得伪造。

若需要同租户内按设备限制，通过 Node 原生入口使用不同凭据，或由平台分配彼此隔离且明确映射身份的额外 bridge；不在 SOCKS5 NOAUTH 协议中假定存在原始用户名传递。通过一个租户的 Caddy 入口接入的会话共享该租户内部 bridge 凭据额度，不影响其他租户。

Caddy 的 HTTP/3 监听使用对应租户端口的 UDP 处理 QUIC；Node SOCKS/SS 原生 UDP 使用各自的监听端口。H3 CONNECT 只能在这条拓扑中承载 TCP 目标，不能把 UDP 数据报自动转发到 Node。普通 HTTP 正向请求必须经过 bridge，并以对应模块实际行为和测试证明；不能只测试 CONNECT 后就声明所有 HTTP 请求都走 Node 路由。

## 9. 统一协议适配器契约

```ts
type Target =
  | { kind: 'domain'; host: string; port: number }
  | { kind: 'ipv4' | 'ipv6'; host: string; port: number };

interface DialContext {
  sessionId: string;
  tenantId: string;
  credentialId: string;
  listenerId: string;
  tenantRevision: number;
  platformRevision: number;
  deadline: number; // 单调时钟的截止时间
  signal: AbortSignal;
}

interface UpstreamAdapter {
  capabilities: Readonly<ProtocolCapabilities>;
  dialTcp(target: Target, context: DialContext): Promise<import('node:stream').Duplex>;
  openUdp(context: DialContext): Promise<DatagramChannel>;
}

interface DatagramChannel {
  send(target: Target, payload: Uint8Array): Promise<void>;
  close(reason: string): void;
  // 接收必须保留来源地址、数据报边界；队列与最大数据报受策略约束。
}
```

此处公共契约与 [design.md](design.md) 一致。TCP 返回受统一生命周期管理的 `Duplex`，具有有序双向流、半关闭、错误和幂等关闭语义。适配器内部可能用一个 TCP Socket、TLS 流、HTTP/2 stream、WS 流或 SSH channel；调用方不依赖底层 Socket 类型。

所有出站连接池和复用载体以 `tenantId + tenantLocalNodeId + effectiveConfigFingerprint + securityContext` 分区，包括 h2 session、WS、SSH connection 和已解密认证缓存。平台共享目录节点也通过每租户本地 alias/授权引用创建上下文，不直接把平台 ID 当作跨租户复用键。租户无权读出共享节点真实密钥；撤销授权使该租户的新拨号立即失败并关闭政策指定的既有会话。跨租户不共享已认证 Socket、session 或 channel 池。

`DatagramChannel` 必须保留数据报边界与每报目标/来源元数据，不能只返回一个普通 `Duplex` 让调用方猜测报文长度。原生 UDP 和流内 UDP 都通过这个合约进入统一 UDP 管理。无 UDP 能力的适配器必须拒绝 `openUdp`，路由层正常情况下应在调用前过滤它。

所有初始缓冲都由明确所有者持有并仅交接一次。适配器成功意味着代理链握手已完成且目标会话已被上游接受；单纯连接机场 TCP 端口不构成 `dialTcp` 成功。

## 10. 会话状态与并发不变量

TCP 会话状态：

```text
accepted -> parsing -> authenticated -> admitted -> dialing
         -> relaying -> draining -> closed
```

身份以不可变的 `(tenantId, credentialId)` 表示，不把用户名、SS 明文密钥或管理 token 写入连接元数据。路由、节点和入口在会话建立时记录为快照；配置更新不会悄悄改变已经建立的链路。连接 ID 只是定位符，查询或断开仍验证租户；Clash API 不得凭全局 UUID 操作其他租户对象。

计数口径：

| 指标 | 计数对象 |
|---|---|
| `clientSockets` | 已接受而尚未关闭的客户端 TCP Socket，包括未认证及闲置 keep-alive |
| `proxySessions` | 已取得名额且未结束的 TCP 代理会话，包含拨号中状态 |
| `pendingHandshakes` | 尚未完成认证的握手工作 |
| `outboundAttempts` | 尚未完成的上游连接尝试 |
| `udpAssociations` | SOCKS 控制关联或 SS 的已认证 UDP 来源关联 |
| `udpFlows` | 已认证关联中按目标区分的数据报转发流 |

原生 HTTP/1.1 普通正向代理按一个请求/响应交换计一会话；原生 HTTP/2 普通请求按一个 stream 计一会话。CONNECT 按隧道计数，标准 h1 WebSocket Upgrade 后同一会话持续到隧道结束，不重复申请名额。原生 HTTP pipeline、keep-alive 和 h2 多流不能绕过会话额度；闲置客户端连接仍占 Socket 额度。Caddy bridge 只按实际桥接 TCP 隧道计会话，不能套用原生 HTTP 的逐请求/stream 计数。

准入在认证后、拨号前执行，同步检查并增加全局 → 租户 → 凭据 → 入口额度，不跨 `await`。层级表示所有约束必须同时成立，不意味着分步持有名额；任一限制失败则全部不增加。返回一个具有 `releaseOnce()` 的 lease；同一会话重试上游复用 lease，禁止按每次拨号重复收费或释放。平台共享监听器同时具有物理上限和租户份额，认证前工作只占全局/来源预算，不能依赖未经认证的 tenantId 分配受保护资源。

租户 suspend/到期/授权撤销立即提升授权 epoch，拒绝新的认证和准入，取消其拨号、探测、订阅、管理操作与实时推送，并幂等关闭 TCP、UDP、空闲池连接。轮询或长任务在应用结果前重新检查 epoch，不能凭旧上下文恢复租户服务。平台统一停机关闭全部；租户停用只枚举所属注册表分区，不关闭其他租户共享的物理监听器或管理进程。

上游失败、客户端取消、认证后超时、WS/h2/SSH channel 关闭和进程排空均进入相同的幂等清理路径。`error`、`end`、`close` 多次发生不能重复减计数。任何计数不得为负数；停止后所有 lease 和定时器归零。

## 11. 普通 HTTP 与 HTTP/2 的特殊处理

- HTTP/1.1 使用 Node HTTP parser，限制首部大小、数量、等待时长和 pipeline 深度；拒绝不明确的消息边界和不合法目标。
- absolute URI、Host、CONNECT authority 按协议分别解析；IPv6 使用方括号规则，禁止用 `split(':')` 解析所有 authority。
- `Proxy-Authorization` 只用于入口认证，不能泄漏给目标或机场；普通请求逐跳头及 `Connection` 指定字段按 HTTP 规范过滤。对已验证的标准 h1 WebSocket Upgrade 单独保留/重建协议必需的升级首部，不能一律删除后仍宣称支持 Upgrade。
- 正向代理请求可以通过上游透明 TCP 隧道发送 origin-form HTTP；一旦发送请求应用字节，不进行透明重放。
- CONNECT 只有上游隧道建立成功后才向客户端发送成功响应。请求解析后预读的 `head` 先受长度约束，再且仅再发送一次。
- HTTP/2 一个 CONNECT stream 对应一个代理会话。stream 取消只关闭该会话，不销毁无关的 h2 session；session 关闭才终止其所有 stream。
- 原生 HTTP/2 普通请求以 `:scheme`、`:authority`、`:path` 构造转发目标，处理 h2 与目标 HTTP 语义转换、禁止首部和流取消。该路径与 CONNECT 同属必需能力，不能只验证 CONNECT。
- 标准 h1 WebSocket Upgrade 在认证、准入和上游握手成功后转为双向字节流，升级预读数据仅交接一次；它不意味着默认支持 h2 扩展 CONNECT（RFC 8441）。
- h2 session 的最大并发 stream、流/连接窗口、头部和待发送字节均有上限。复用降低 Socket 数，但不减少会话计数。
- 基础 HTTP CONNECT 不承载 UDP，不把 HTTP/2 或 HTTP/3 的存在当作数据报支持信号。

## 12. 背压、半关闭和有界内存

每个 TCP 方向独立维护状态和缓冲预算。发送端返回不可继续写入时暂停来源读取，收到恢复信号后继续；密码编解码、WS、h2、gRPC、SSH 载体都必须向上游传播背压。

每条流有 soft high-water mark 和 hard buffer limit；所有会话还共享进程缓冲预算。握手缓冲、加密记录、WS 消息、gRPC 消息、UDP 队列、日志环和订阅响应分别设限。超过硬上限时终止或拒绝对应工作，不能无限扩容。

认证帧的明文只能在该帧校验成功后释放。某一方向 EOF 时结束对侧写入，保留反向读取直到结束或半关闭期限；两侧都结束后清理。不能使用未经封装的双向 `pipe` 就认为已经处理好错误传播、半关闭和资源释放。

超时分为握手、拨号、协议响应、空闲、半关闭排空和停机总期限。每个会话共享一个取消源；任何终止原因都能取消正在拨号、DNS、TLS、测速或载体升级的工作。

## 13. UDP 会话与承载差异

### 13.1 原生 UDP

SOCKS5 UDP 数据必须属于一个有效的、完成认证的 UDP ASSOCIATE；其 TCP 控制连接关闭时销毁关联和所有目标流。校验客户端来源地址/端口与关联策略，不接受任意来源向关联发包。

SOCKS5 上游返回的 UDP relay 地址可能需要按协议和实际控制连接端点解释；不能盲目把通配地址当作可远程发送的地址。IPv4/IPv6、域名 ATYP、地址族转换和 NAT 行为进入互通测试。

SS UDP 在 AEAD 验证通过后才能创建来源关联与目标流；失败报文不分配长期资源。以入口/密钥身份、来源端点及目标构造受限映射，明确配置端口变化是否创建新关联，不用未认证报文迁移旧会话。

### 13.2 UDP-over-stream

Trojan、VMess、VLESS 的 UDP 必须实现各自的帧格式和目标语义。UDP 数据报不能简单拼接写入 TCP；接收端必须恢复原始报文边界。每个逻辑流固定目标时，不把它误当成多目标 UDP socket。

这种承载支持 UDP 目标，但会受 TCP 丢包时的队头阻塞影响。Web 和 Clash 扩展状态应显示 `stream-framed`，不能报告成原生 UDP 或 QUIC。性能验收分别测原生 UDP 与流内数据报，不能用同一延迟结论替代。

### 13.3 限额和关闭

限制 UDP 关联总量、每凭据关联数、每关联目标数、数据报最大长度、待发送队列条数/字节数和报文最大等待时间。空闲使用单调时钟回收；控制连接错误、凭据禁用、入口停止和管理员断开均立即回收相关映射。

不支持 UDP 的出口不得被选中。无合适节点时拒绝关联或丢弃数据报并记录明确原因；不自动走 DIRECT。节点切换默认只影响新流；已有 UDP 流保持节点直到空闲回收，显式断开才重新选路，避免回复来源混乱。

## 14. DNS、路由与目标地址

默认保留客户端提供的域名，交由具备 `domainTarget` 能力的出口处理。上游节点自身域名由 bootstrap resolver 解析，解析链路不依赖该节点自身代理，避免递归。

域名规则先匹配；IP 字面量可直接匹配 CIDR。域名目标需要 IP 规则时，仅在启用 `resolveForIpRules` 后执行本地解析并缓存；该选项会改变 DNS 可见性和规则语义，界面应明确显示。未启用时不为了测速、日志或展示而偷偷预解析目标域名。

路由输入包含原始目标、规范化目标、协议、入口 ID、凭据 ID、目标网络和可选已解析地址。规则最终选择一个节点或代理组；组内先按 TCP/UDP、地址族、传输和健康状态筛选，再执行选择策略。

默认出口是显式代理组；无可用匹配节点时失败。DIRECT 必须由配置明确选择。对本机代理端口、管理端口和 bootstrap 的访问按显式目标策略处理，检测会导致代理回到自身入口的环路。

## 15. 重试、探活与节点切换

只有尚未发送应用载荷的连接建立失败允许有限重试；重试受总拨号期限、尝试次数和每节点退避共同约束，并共用会话 lease。HTTP 请求、SS 早期载荷等只要已发往上游，均禁止透明重放，即使方法看起来幂等。

节点健康状态区分 DNS/TCP/TLS/代理握手/测试目标失败。探活通过真实代理适配器访问配置的测试目标，分别记录建立隧道和首个有效响应的时间；单纯 TCP 连接延迟不冒充代理测试结果。

手动组选择和 URLTest 更新作用于新会话。已存在的 TCP 流不迁移节点；配置可以明确要求断开旧流，但必须由用户操作或预先选定策略触发。错误、退避、恢复和选路决定写入有界日志，避免持续故障造成日志风暴。

## 16. 限速、统计与 Clash 视图

上行表示客户端向目标发送的代理载荷，下行表示目标返回的载荷；原生 UDP 按应用数据报载荷计。协议握手、加密封装、TLS/WS/h2 开销不计入业务载荷；它们可以另列诊断指标。统一转发层只计一次，不能在编解码器和 Socket 两侧重复累加。

全局、凭据、入口上下行使用共享令牌桶，按单调时间补充。大于桶容量的数据块须切分；调度以有界片段在活跃会话之间公平轮转，不能让一个高速连接占满整组带宽。高层配置的速率是组内总速率，不是每条连接各自获得该速率。

TCP 限速通过背压；UDP 使用短且有界的队列，满队列或报文超过等待期限则丢包并累计原因。不能通过无限缓存把限速变成内存增长。

测速、订阅更新、管理 API 和 Caddy 到 Node 的内部协议开销属于控制流量，不计入个人代理载荷。Clash `/traffic`、`/connections` 和自建 Web 从同一个 `TrafficMeter`/`ConnectionRegistry` 读取快照。UDP 在兼容连接列表中具有明确 ID、目标和生命周期；一个逻辑流只出现一次。

对 Caddy bridge 会话，Clash metadata 的源是 loopback，凭据是 `edge-owner`。无法观察到的原客户端字段留空或通过本项目扩展字段说明，禁止编造应用进程名、目标 IP 或真实设备身份。

## 17. 协议验收契约

最终核心的每个白名单组合都必须有：规范来源、固定配置、独立服务端/客户端版本、测试方法、Windows 实际结果和失败样本。测试报告记录 Node、Windows、依赖版本和代码修订；本设计不代替执行证据。

| 类别 | 必须覆盖的证据 |
|---|---|
| 字节流解析 | 握手每一字节切分、随机切分、粘包、空分块、超长字段、握手后预读、无界输入被限制 |
| HTTP | 正向请求/响应体、chunked、keep-alive、IPv6 CONNECT、代理认证、首部过滤、标准 h1 WebSocket Upgrade 与预读、拒绝异常边界、上游拒绝 CONNECT、客户端取消 |
| HTTP/2 | 普通请求正向转发及 CONNECT、多 stream 并发准入、流取消、session GOAWAY、窗口背压、每流独立统计、一个失败流不终止无关流 |
| SOCKS5 | 方法协商、用户名密码、IPv4/IPv6/域名、目标拒绝、UDP 关联/来源校验/关闭、非零 FRAG 处理 |
| Shadowsocks | 官方/独立测试向量、全部选定方法、TCP/UDP、错误密钥/标签、salt/nonce/会话编号、重复数据报、时间窗、密钥轮换 |
| VMess/VLESS/Trojan | 指定协议版本、每个白名单传输、TLS/SNI/Host/path、UDP 边界、EOF、取消、错误认证、不可用功能被拒绝 |
| SSH | 主机密钥正确/变更、密码/私钥、channel 拒绝、多个 channel 额度、连接断开、无外部 ssh.exe |
| Caddy 边缘 | 最终交付必须分别验证 h1/h2/h3；普通正向请求及 CONNECT 均经 Node 路由；bridge 仅 loopback；实际桥接隧道计数和上限生效；连接复用不伪报逐请求计数；H3 不误报 UDP 代理 |
| 资源与限额 | 同时接入不超额、失败释放且不为负、未认证总量、长时间背压、半关闭、UDP 淘汰、限速公平性、清理后句柄不增长 |
| 路由与 DNS | 域名保留、IP 规则 opt-in、节点 bootstrap、能力筛选、无可用节点明确失败、禁止隐式 DIRECT、切换不迁移旧流 |

UDP 互通至少验证普通 DNS 请求/响应、多个目标、不同数据报长度、双向报文、来源变化和空闲回收。成功绑定端口、成功导入订阅或单个网页能打开都不构成全协议验收。

## 18. 规范与参考来源

以下链接是协议和实现核查入口，具体实现应在测试资料中固定所依据的文档修订。官方文档、规范与第三方实现之间有差异时，记录差异并以已声明的兼容目标为验收对象。

- [HTTP 语义与 CONNECT，RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html)
- [HTTP/1.1，RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)
- [HTTP/2，RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html)
- [HTTP/3，RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html)
- [CONNECT-UDP，RFC 9298](https://www.rfc-editor.org/rfc/rfc9298.html)
- [SOCKS5，RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html)
- [SOCKS 用户名密码认证，RFC 1929](https://www.rfc-editor.org/rfc/rfc1929.html)
- [Shadowsocks AEAD 说明](https://shadowsocks.org/doc/aead.html)
- [Shadowsocks 2022 规范](https://github.com/Shadowsocks-NET/shadowsocks-specs/blob/main/2022-1-shadowsocks-2022-edition.md)
- [Trojan 协议](https://trojan-gfw.github.io/trojan/protocol)
- [VMess 协议文档](https://www.v2fly.org/developer/protocols/vmess.html)
- [VLESS 协议与 Xray 文档](https://xtls.github.io/development/protocols/vless.html)
- [Xray 传输与实际兼容实现](https://github.com/XTLS/Xray-core)
- [SSH 连接协议，RFC 4254](https://www.rfc-editor.org/rfc/rfc4254.html)
- [AnyTLS 协议实现与规范入口](https://github.com/anytls/anytls-go)
- [Caddy forwardproxy 模块](https://github.com/caddyserver/forwardproxy)
- [Node HTTP](https://nodejs.org/api/http.html)、[HTTP/2](https://nodejs.org/api/http2.html)、[TCP](https://nodejs.org/api/net.html)、[UDP](https://nodejs.org/api/dgram.html)、[流](https://nodejs.org/api/stream.html)、[密码学](https://nodejs.org/api/crypto.html)
