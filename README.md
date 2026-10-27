# NetworkProxy

面向 Windows Server、个人自用的代理中转工具。应用核心使用一个 Node.js 进程，以 TypeScript 实现协议、连接管理、路由、限额、Web 管理与 Clash API，使用 SQLite 持久化。

允许一个独立的 Caddy 入口进程。普通 Caddy 用于管理界面和 API 的 HTTPS；含 `caddyserver/forwardproxy` 扩展的构建用于 HTTP/1.1、HTTP/2、HTTP/3 正向代理入口，通过本机桥接入口交给 Node 核心。

当前仓库提供**最终核心版本的设计规格**，尚未实现代理运行程序。文档中的“支持”表示交付要求，是否已实现由能力注册表与验收结果决定。

| 文档 | 内容 |
| --- | --- |
| [完整设计](docs/design.md) | 范围、模块、状态、配置发布、资源预算与目录结构 |
| [协议与兼容性](docs/protocols.md) | 入站、出站、传输、TCP/UDP、DNS、连接生命周期 |
| [API 契约](docs/api.md) | 自建后台、Clash API、WebSocket 与鉴权 |
| [存储设计](docs/storage.md) | SQLite、凭据、配置 revision、备份和恢复 |
| [数据库结构](docs/schema.sql) | 可执行的 SQLite 结构定义 |
| [Windows 与 Caddy](docs/operations.md) | 入口拓扑、部署、停机、维护、Caddy 边界 |
| [最终验收](docs/acceptance.md) | 核心版本完成条件与协议互通矩阵 |
| [Caddy 配置示意](deploy/Caddyfile.example) | 需要替换域名、证书和凭据的配置模板 |
| [Caddy 启动配置](deploy/Caddyfile.bootstrap.example) | 无代理权限启动，由 Node 在内存加载受管配置 |
| [本次设计验证](docs/validation.md) | 已执行的 SQLite 约束检查与验证边界 |

设计基线日期：2026-10-27。目标为完整核心版本，不采用分阶段删减功能的交付口径。
