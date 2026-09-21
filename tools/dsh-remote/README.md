# DSH Remote — 手机远程访问

通过 **Tailscale Serve** 把本地 `deepseek-harness-desktop` 暴露为 `https://<你的tailnet>.ts.net`，手机加入同一 Tailnet 即可访问。默认在 Tailscale Serve 与 DSH 之间启动一个仅监听 loopback 的 relay，重写 `Host`/`Origin` 后再转发 API、流式响应和 WebSocket，兼容 DSH 的 API trust fence。**短暂暴露**：DSH 启动时自动暴露，关闭时自动断开。

## 特性

- **事件驱动 + 60s对账**：WMI `__InstanceCreationEvent/__InstanceDeletionEvent (WITHIN 2s)` 事件唤醒，0 CPU 休眠；每 60s 对账一次，崩溃/漏事件也能自愈
- **自动端口**：`config.toml` 设 `port=0` 时自动读 `~/.store.dat` 的 `port`，再探测 `3081/3080` Listen
- **API 兼容**：默认使用 `127.0.0.1:3090` relay -> DSH 实际端口，解决远程域名访问 API 返回 `403 forbidden`
- **幂等**：重复执行不会重复创建 Serve
- **通知**：走系统 Toast（可关）
- **常驻/短暂可选**：`auto_off=true` 关闭 DSH 就 `tailscale serve off`

## 文件

```
tools/dsh-remote/
├── config.toml              # 配置（端口/对账/通知）
├── DshRemoteUtils.ps1       # 公共库（读配置/端口/Serve状态/通知）
├── Start-DshRemote.ps1      # 一键暴露（幂等，自动等端口）
├── Stop-DshRemote.ps1       # 一键关闭
├── Watch-DshRemote.ps1      # 事件驱动 Watcher（核心）
├── Get-DshRemoteStatus.ps1  # 状态查询
├── Install-Watcher.ps1      # 安装开机自启任务
├── Restart-Watcher.ps1      # 只 /End + /Run 已有任务，让它重载当前脚本
├── Uninstall-Watcher.ps1    # 卸载
├── dsh-remote-relay.js      # loopback HTTP/SSE/WebSocket Host/Origin relay
└── watcher.log              # 运行日志（超过 5 MB 轮转为 watcher.log.1）
```

## 快速开始

```powershell
# 1) 手动试一次（会等 DSH 端口就绪再暴露）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-DshRemote.ps1
# 查看状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\Get-DshRemoteStatus.ps1
# 关闭
powershell -NoProfile -ExecutionPolicy Bypass -File .\Stop-DshRemote.ps1

# 2) 安装跟随启停的 Watcher（推荐）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Watcher.ps1
# 以后：DSH 启动 -> 2s内自动暴露；DSH 关闭 -> 2s内自动 off，漏事件 60s 内自愈
# 改完 Watch-DshRemote.ps1 后只重载任务，不删任务、不动 Serve/relay
# Restart-Watcher 会 /End + /Run，再轮询最多 8s 确认任务 Running；未确认则打印实际状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Watcher.ps1
# 日志
Get-Content .\watcher.log -Tail 50 -Wait

# 卸载
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-Watcher.ps1
```


## 配置 `config.toml`

```toml
[server]
port = 0          # 0=自动探测，>0=固定
https_port = 443

[relay]
enabled = true    # 通过 loopback relay 让远程 DSH API 通过 trust fence
port = 3090       # relay 本地端口，必须与 server.port 不同

[watcher]
poll_interval = 60 # 对账周期；事件驱动为主。配置值 < 30 会被忽略并继续用默认 60
auto_off = true    # true=短暂暴露，false=常驻
probe_timeout = 12

[general]
show_notification = true
```

## 资源占用

- 事件驱动：无事件时完全休眠，**0% CPU**，`powershell` 常驻 ~30MB
- WMI 的 `WITHIN 2s` 是 WMI 内部轻量 poll，脚本侧无开销
- 对账 60s 一次，单次 <50ms
- 日志：`watcher.log` 超过 5 MB 时改名为 `watcher.log.1`（只留一份旧日志），再继续写新文件
- 对比：`Tailscale` ~50MB，`DSH` ~200MB，Watcher 可忽略

## 常见问题

- **Tailscale 未在线**：`tailscale status --json` 需 `BackendState=Running`，先 `tailscale up`
- **端口未监听**：DSH 还在启动，Watcher 会等 `probe_timeout` 再重试；`Get-DshRemoteStatus.ps1` 看 `listening`
- **更新后失效**：Watcher 是独立计划任务，不会被 DSH 更新覆盖
- **开机弹出 Remote closed / DSH closed**：上次会话的 Tailscale Serve 配置还在，Watcher 登录后对账发现 DSH 没跑就会 `serve off`。现在本会话没见过 DSH 启动时只静默清残留，不再弹关闭通知；真正关掉 DSH 仍会提示
