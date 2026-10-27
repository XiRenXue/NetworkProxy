# 本次设计验证记录

日期：2026-10-27。验证对象为设计文档和数据库结构，代理程序尚未实现。

## 已执行

- 在当前 Windows x64、Node v24.15.0 的内置 SQLite 3.51.3 上执行完整 schema.sql，成功创建 25 张业务表。
- PRAGMA foreign_key_check 无违规，PRAGMA integrity_check 返回 ok。
- 执行 17 项结构与语义检查，覆盖内部无密钥 bridge 身份、拒绝公开无密钥凭据、非法额度、代理组间接环、非组成员父节点、选择必须属于组、统计检查点重试幂等、拒绝倒序/不一致样本、跨 run 累计、跨 UTC 小时分桶、异步操作终态及中断约束。
- 检查 Markdown 本地链接存在且代码围栏成对。
- 实测当前 Windows Node v24.15.0 使用 --experimental-quic 导入 node:quic，返回 ERR_UNKNOWN_BUILTIN_MODULE；因此设计采用 Caddy forwardproxy 提供 HTTP/3 入站，不依赖该二进制的原生 QUIC。
- 通过 Context7 及官方文档/源码核对 Node HTTP/2 CONNECT、流背压、Caddy h1/h2/h3、forwardproxy 本机 SOCKS5 upstream、persist_config off 和相关边界。

数据库执行使用内存数据库，不写入任何真实账号或服务器配置。此检查确认 SQL 结构与所列约束可执行；不替代锁定 better-sqlite3 版本、迁移运行器和真实磁盘/WAL 的集成验收。

## 尚未执行的运行验收

Caddy 目标构建的配置验证、h1/h2/h3 客户端互通、机场节点互通、Clash 面板兼容、Windows 自启与负载测试尚未执行。具体完成合同见 [acceptance.md](acceptance.md)。本次交付为完整设计规格，不声称运行能力已经通过验收。
