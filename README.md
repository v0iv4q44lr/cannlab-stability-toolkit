# CANN Lab / GitCode Devenv SSH 稳定性工具包

针对 `atomgit-cloudenv.cannlabdevspace` 插件 v1.1.2(连接 GitCode CANN Lab 昇腾 910B 环境的
VSCode 通道)连接不稳定问题的客户端根治方案。全部结论来自对插件源码、4600+ 条枢纽日志、
Remote-SSH 日志与 1960 条 WSS 会话的逆向分析,并通过 6 项受控对照实验验证。

## 故障机理(已实证)

连接链路:`VSCode Remote-SSH → ssh.exe → 127.0.0.1:30455(port-forward-hub 进程) → wss://dev.gitcode.com → 容器 sshd`

插件 1.1.2 的三个设计缺陷导致"卡死 / 进不去 / Cannot reconnect":

1. **看门狗饿死**:枢纽活性只认 HTTP `GET /heartbeat`(空闲 35s / 有连接 10min 收不到即自杀,
   并摧毁承载的 SSH 隧道)。心跳只喂"锁持有者",而真正承载流量的枢纽丢锁后无法再被喂 → 必死。
   (实测三个样本:最后一次心跳后 605s / 606s / 38s 死亡,与 35s/10min 常数精确吻合)
2. **单座互踢战争**:GitCode 服务端每个环境只允许一条 WSS 隧道(新连顶旧连,close code 4401)。
   插件收到 4401 后 1 秒盲重连,且重连成功即清零退避计数 → 两个枢纽以 1 秒节奏无限互踢
   (实测 9 分钟 1819 次),重连撞上战火时安装脚本被炸断 → BadInstallScriptResult(致命)→
   "Cannot reconnect. Please reload the window"。
3. **僵尸端口劫持**:枢纽退出流程可能挂起,进程不死、端口不放(实测一个"已打印退出日志"
   24.7 分钟仍持有 30455,导致后续连接全部 EADDRINUSE 恶性循环)。

平台侧(GitCode WSS 服务)是清白的:历史存在 598 分钟的超长会话。

## 文件说明

| 文件 | 作用 |
|---|---|
| `hub-keeper.ps1` | 外部守护(零侵入):每 15s 给"真正持有转发端口/锁"的枢纽喂心跳;击杀"已打印退出却仍占端口"的僵尸;对"占端口但无控制面"的进程三振出局;把锁文件纠正指向服役枢纽,让扩展复用而非增殖 |
| `hub-patch-apply.ps1` | 对插件 `port-forward-hub.js` 打三补丁(自动时间戳备份,锚点校验失败绝不写文件) |
| `hub-patch-rollback.ps1` | 一键回滚到最近备份 |

## 三补丁

- **P1 反自杀**:看门狗阈值 35s/10min → 10min/12h(空闲枢纽照常清理,服役枢纽不再中途被处决)
- **P2 让位止战**:收到 4401 时,无活跃连接的枢纽永久让位退出,有连接的枢纽保持快速重连
  (注意:朴素"抬高退避计数"方案是错的——源码 QP=3,计数≥3 会触发"重连耗尽"并关闭全部连接)
- **P3 退出确定性**:退出前 `closeAllConnections()`(防御性,实测未复现挂起但无害)

## 受控实验结果(隔离沙箱 + 伪造 WSS 服务器)

| 测试 | 结果 |
|---|---|
| T1 原版无心跳 | 精确 40.0s 自杀(35s 阈值 + 10s 检查粒度) |
| T2 补丁版无心跳 | 120s+ 存活(P1 生效) |
| T3 补丁版收 4401 | `preempted-yield` 干净让位,exit 0,锁释放 |
| T4 原版收 4401 | 12 秒 7 轮无限重连,`reconnect.success` 后 attempt 清零实证 |
| T5 keep-alive 挂起退出 | 未复现挂起(两版均 <1s 退出)→ P3 定性为可选防御 |
| T6 keeper 三振规则 | 1/3 → 2/3 → 击杀,节奏精确 |

## 快速开始

```powershell
# 1. 常驻守护(建议加入开机自启)
powershell -ExecutionPolicy Bypass -File hub-keeper.ps1

# 2. 应用补丁(应用后需关闭所有 VSCode 窗口,让新枢纽从补丁代码孵化)
powershell -ExecutionPolicy Bypass -File hub-patch-apply.ps1

# 回滚
powershell -ExecutionPolicy Bypass -File hub-patch-rollback.ps1
```

另外建议在 `~/.ssh/config` 为 devenv 主机加 SSH 层保活(隧道被掐后 60s 内干净检出):
```
Host *.atomgit.0
  ServerAliveInterval 15
  ServerAliveCountMax 4
```

## 注意事项

- 插件升级会覆盖补丁文件,重新执行 `hub-patch-apply.ps1` 即可(脚本自动重新备份);
- 同一环境保持**单窗口**使用(多窗口=多个扩展宿主=心跳错配与枢纽增殖的温床);
- 环境在平台侧休眠(envNotRunning)不受本工具影响,需到 GitCode CANN Lab 页面重新启动;
- keeper 日志:`~/.atomgitdevenv/hub-keeper.log`。

## License

MIT
