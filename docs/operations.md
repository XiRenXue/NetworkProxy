# Windows 与 Caddy 运行设计

## 1. 进程和信任边界

一个 Node 进程负责业务与自研代理核心，一个用户允许的 Caddy 进程负责入口。两者分别托管，均有固定版本和可恢复配置。没有 sing-box、Mihomo 或其他外部机场协议内核。

Windows 支持由用户态实现提供 QUIC；Caddy 的 HTTP/3 就是这种使用方式。Node 的某个 Windows 发布包缺少 node:quic，与 Windows 操作系统不能运行 QUIC 是不同结论。

只有包含 `github.com/caddyserver/forwardproxy` 的 Caddy 构建才提供本文的 h1/h2/h3 正向入口。标准 reverse_proxy 用于网站/API/WebSocket，不作为通用 CONNECT 转发的隐含实现。

## 2. HTTP/2、HTTP/3 入口

```text
HTTP/1.1 / HTTP/2 / HTTP/3 客户端
    → Caddy forwardproxy：TLS/QUIC、HTTP 协议与外部 owner 认证
    → 127.0.0.1:11080：Node 专用 SOCKS5 bridge
    → Node：配额、路由、机场握手、载荷转发和统计
```

bridge 只监听 IPv4 loopback，启用 SOCKS5 NOAUTH，并固定映射 edge-owner。公开 SOCKS5 入口独立配置、强制用户名密码认证。部署脚本检查桥接地址不能是 `0.0.0.0`、`::` 或公开地址。

这里选择本机无认证入口是明确的本机信任边界：本机其他进程也可能访问它，Windows 账户隔离和服务器本身须可信。上游 URL 不写服务用户名/密码，原因是当前 forwardproxy 的普通 HTTP upstream 分支对 Proxy-Authorization 有额外处理，不能允许内部密钥进入目标请求。

所有源站认证和访问限制由 Node 实际路由执行。模块 upstream 模式跳过其 ACL/ports 逻辑，配置生成器不输出两套互相矛盾的 ACL。

外层认证用户名、真实客户端 IP、HTTP 版本和 QUIC session ID 不会通过普通 SOCKS5 自动传给 Node。Node 记录 bridge、edge-owner 和 loopback 来源；Caddy 访问日志提供边缘信息，不在 Clash metadata 中伪造客户端地址。自用可以接受这个统一身份，原生 SOCKS/SS 凭据仍可按设备区分。

HTTP/2 和 HTTP/3 每条 CONNECT 流都产生一个 Node 桥接隧道并独立占额度。普通 HTTP 的计数依据真实存活的桥接连接：若固定模块每请求新建连接，则响应完成应释放；若确有连接复用，则池化连接仍占物理/桥接额度，并在约定空闲期限内回收。不能因未知的关闭路径无限占用名额，该行为必须做源码审计和集成验证。

此链支持 TCP CONNECT，不是 CONNECT-UDP/MASQUE。SOCKS5/SS UDP 直接接入 Node；Hysteria2/TUIC 出站需要各自的 QUIC 实现，Caddy 入口不能代替它们。

## 3. Caddy 构建与配置所有权

发布清单保存：Caddy 版本、forwardproxy commit、模块列表、二进制 SHA-256 和配置 hash。模块明确标注 experimental，因此不能使用浮动 latest 作为部署合同。必须验证以下门槛：h1/h2/h3 CONNECT、普通 HTTP 释放、取消/错误清理、无凭据泄漏、域名由 Node 接收、Caddy reload 后状态与长连接行为。

若固定版本不满足门槛，应选择包含上游修复且满足相同合同的扩展构建，否则该入口发布验收失败；不允许带着已知凭据泄漏或资源泄漏部署。本方案不默认扩大为自行维护 Go 扩展。协议核心仍为 Node，不把机场配置迁入 Caddy。使用第三方模块的行为测试属于最终核心发布验收。

[Caddyfile.example](../deploy/Caddyfile.example) 是内存渲染结果的配置示意，使用手动证书路径来避免把 ACME 与任意 authority 的正向代理路由混写。生产运行使用无代理权限的 [bootstrap 配置](../deploy/Caddyfile.bootstrap.example)，再由 Node 加载内存生成的受管 JSON；不能把替换成真实认证信息的示意文件作为常规明文配置落盘。部署时使用锁定的 Caddy 构建验证语法和实际入口。该仓库未安装或启动 Caddy，也未声称模板已通过目标二进制验证。

实际受管配置由 Node 的 CaddyController 生成 JSON 并通过本机 Admin API 应用，不在运行中调用 shell。关闭 Caddy autosave/persist_config，数据库保存 secretRef 模板，实际明文认证只在内存渲染。Caddy 重启后先回到 bootstrap，Node 通过健康核对重新应用受管配置；不要使用含秘密的旧 autosave 恢复。Caddy 管理接口只绑定 loopback；服务器本机账户为其信任边界。Caddy 与 Node 的运行账户分别只获得所需数据/证书读取权限。

证书可以外部供应，或由单独配置好的 Caddy ACME 自动化策略供应。自动签发要求真实域名、DNS 与可达的挑战入口。Node 原生 TLS 入口通过显式证书供应器取得证书，不读取 Caddy 内部目录的未公开实现布局。

## 4. 目录

```text
C:\Program Files\NetworkProxy\
  runtime\node.exe
  server\dist\
  web\dist\
  caddy\caddy.exe
  release-manifest.json

C:\ProgramData\NetworkProxy\
  data\networkproxy.db          同目录还可能有 -wal/-shm
  keys\master.key
  tls\
  caddy\                        受管配置、last-good、Caddy 数据
  logs\
  backups\
```

代码目录只读。运行目录与工作目录都显式设置，不依赖当前 shell。主密钥与可恢复备份分开保管；主密钥不写入源码、SQLite、日志或普通配置导出。

## 5. 托管与启动

可使用 Windows 任务计划程序在开机后以专用低权限账户启动编译后的 Node 与 Caddy，各自配置失败重启和“已有实例时不启动新实例”。若选择服务包装器，只承担系统托管，不承担代理业务。

Node 启动顺序：取得独占的 loopback 管理监听锁 → 读取主密钥与启动设置 → 打开 SQLite 与迁移 → 标记上一次 run 异常结束 → 检查恢复策略 → 编译 last-good/desired 配置 → 准备并启动入口 → 核对 Caddy 配置 → 标记 ready。

端口锁定失败时第二实例在数据库迁移前退出。固定管理地址来自启动参数；修改它要求受控重启。任务计划程序单实例设置是第一层，进程自己的锁是第二层。

Caddy 可以先启动；在 Node 不 ready 时桥接不可转发。Node 也可以先启动；管理状态显示 edgeUnavailable，恢复连接并核对配置后再 ready。相关端口绑定失败不允许静默改用随机端口。

## 6. 网络与防火墙

只开放配置的公开端口。HTTP/3 入口同时需要对应 UDP 端口，TCP 可用于 h1/h2。UDP 不通时客户端是否回退取决于客户端，界面不得显示 HTTP/3 已验证。

SOCKS UDP 使用固定中继端口并返回正确的外部广告地址；不要依赖防火墙未知的随机临时监听端口。SS 的 TCP 与 UDP 同端口分别放行。Node bridge、管理端口与 Caddy Admin API 不开放公网。

所有代理入口都要求外部认证；仅本机受信 bridge 例外。管理站点使用应用会话/Clash secret，并使用 HTTPS。Caddy access log 不记录完整查询 token，Forwarded/Via 的生成与删除策略必须验证不泄漏代理凭据。

## 7. 停止与异常恢复

管理 API 提供受保护的排空停止命令，本机管理命令调用它，不依赖 POSIX SIGTERM。流程为：标记 draining → 停止新会话 → 停止订阅和探测调度 → 发送 WS 停机通知 → 等待会话排空 → 到期限关闭剩余 TCP/UDP → 最终统计 flush → 关闭数据库、日志与监听器 → 退出。

控制台正常退出事件可以进入相同流程；任务管理器强制结束、任务计划强制停止或机器断电可能跳过该流程。因此恢复不以停机钩子成功为前提。

重启不恢复旧 Socket、UDP 关联和名额，所有运行计数从零开始。SQLite 恢复已提交事务；最近 5 秒尚未提交统计允许丢失。配置恢复按 desired/applied/last-good 显示明确状态，错误配置不应造成无限重启。

## 8. 维护与备份

在线备份必须是 SQLite 一致性备份。若锁定驱动不能在单进程预算内完成在线备份，则使用受控维护：停止新会话、排空、停止写入、checkpoint、关闭数据库、复制一致数据库及受保护密钥材料，再重新打开。禁止在 WAL 活跃时只复制 .db。

备份包含 schema 版本、配置 revision、文件 hash、应用版本和密钥恢复说明。恢复先到临时目录检查，不直接覆盖唯一可用副本。恢复凭据须同时具备正确 master.key；普通脱敏配置导出不能替代完整备份。

迁移前生成可恢复备份。升级采用停止 → 备份 → 替换版本 → 迁移 → 启动验证，失败回退兼容版本与数据库备份。不承诺单进程更新过程中现有连接不断开。

磁盘满或数据库错误时，禁止返回配置保存成功；减少日志和非必要明细写入，保留明确状态。用户可以选择继续使用当前已应用的内存配置，但管理面显示持久化故障。

## 9. 可观测性

状态页提供 Node/Caddy 版本与配置 hash、run ID、运行时间、实际监听、TCP/UDP 数量、拨号失败、丢包原因、队列字节、RSS、事件循环 p95/p99 延迟、数据库慢操作、WS 慢消费者和最新统计落盘时间。

性能目标由目标 Windows 服务器上的固定负载测量建立。默认资源数不是吞吐承诺。最终报告记录 CPU、内存、Windows、Node/Caddy 版本、算法、载荷大小与上游时延，使调优结果可复现。

## 10. 证据

- [Caddy 协议配置](https://caddyserver.com/docs/caddyfile/options#protocols)。
- [Caddy forwardproxy 的功能与 upstream 限制](https://github.com/caddyserver/forwardproxy/blob/master/README.md)。
- [forwardproxy 实现](https://github.com/caddyserver/forwardproxy/blob/master/forwardproxy.go)。
- [Node HTTP/2 CONNECT](https://nodejs.org/api/http2.html#connect)。
- [Node v24.x QUIC 文档](https://github.com/nodejs/node/blob/v24.x/doc/api/quic.md)。
