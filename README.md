# CANN Lab / GitCode Devenv SSH 稳定性工具包

针对 `atomgit-cloudenv.cannlabdevspace` 插件 v1.1.2(连接 GitCode CANN Lab 昇腾 910B 环境的
VSCode 通道)连接不稳定问题的客户端根治方案。全部结论来自对插件源码、4600+ 条枢纽日志、
Remote-SSH 日志与 1960 条 WSS 会话的逆向分析,并通过 8 项受控对照实验验证。

## 故障机理(已实证)

连接链路:`VSCode Remote-SSH → ssh.exe → 127.0.0.1:30455(port-forward-hub 进程) → wss://dev.gitcode.com → 容器 sshd`

插件 1.1.2 的四个设计缺陷导致"卡死 / 进不去 / Cannot reconnect":

1. **看门狗饿死(P1 治)**:枢纽活性只认 HTTP `GET /heartbeat`(空闲 35s / 有连接 10min 收不到即自杀,
   并摧毁承载的 SSH 隧道)。心跳只喂"锁持有者",真正承载流量的枢纽丢锁后无法再被喂 → 必死。
   (实测三个样本:最后一次心跳后 605s / 606s / 38s 死亡,与常数精确吻合)
2. **单座互踢战争(P2 治)**:服务端每环境只允许一条 WSS(新连顶旧连,close code 4401)。
   插件收到 4401 后 1 秒盲重连,且重连成功即清零退避计数 → 无限互踢(实测 9 分钟 1819 次)。
3. **退出挂起僵尸(P3 治)**:退出流程可被 keep-alive 连接卡死,进程不死、端口不放
   (实测"已打印退出日志"24.7 分钟仍持有 30455)。
4. **6 秒放弃放大器(P4 治)**:上游任何中断(WSS close 1006/4500)后,枢纽只重试 3 次
   (约 6 秒)就 `reconnect.exhausted` 永久放弃并销毁全部本地连接——把几秒的网络闪断/
   平台 devenvd 重启放大成"枢纽脑死亡 + 弹窗 + 十分钟恢复"。

上游事实(客户端无法预防,只能穿越):网络闪断(close 1006,约每天 1 次,常见于睡眠唤醒/早高峰)、
平台环境代理掉线(close 4500 "devenvd disconnected",约每天 1 次)、环境闲置自动关机。

## 文件说明

| 文件 | 作用 |
|---|---|
| `hub-keeper.ps1` | 外部守护(零侵入):每 15s 给"真正持有转发端口/锁"的枢纽喂心跳;击杀"已打印退出却仍占端口"的僵尸;对"占端口但无控制面"的进程三振出局;把锁文件纠正指向服役枢纽,让扩展复用而非增殖。支持 `-ExtraPorts` 测试参数 |
| `hub-patch-apply.ps1` | 四补丁应用(逐针幂等,可重复运行/增量应用;时间戳备份;锚点全失时不写文件) |
| `hub-patch-rollback.ps1` | 回滚到最近备份(连续运行两次可回到最初原版) |

## 四补丁

- **P1 反自杀**:看门狗 35s/10min → 10min/12h(空闲枢纽照常清理,服役枢纽不再中途被处决)
- **P2 让位止战**:收到 4401 时,无活跃连接的枢纽永久让位退出,有连接的枢纽保持快速重连
  (注意:朴素"抬高退避计数"方案是错的——原版 QP=3,计数≥3 触发"重连耗尽"并关闭全部连接)
- **P3 退出确定性**:退出前 `closeAllConnections()`(防御性)
- **P4 穿越中断**:重连上限 QP 3 → 30——上游中断后持续重试约 8 分钟,期间本地连接数据排队、
  WSS 恢复后续传,**隧道套接字不死**(T8 实测 90 秒全程中断零影响,恢复后 1.2 秒重连)

配合 `~/.ssh/config` 中 `ServerAliveInterval 15 / ServerAliveCountMax 12`(3 分钟静默容忍),
最终断连体验矩阵:

| 上游中断时长 | 体验 |
|---|---|
| < ~3 分钟 | 完全无感(多数闪断/devenvd 重启在此列) |
| 3 ~ 8 分钟 | 枢纽自动恢复,ssh 重握手一次(约 15 秒) |
| > 8 分钟 / 环境关机 | 网页重启环境,本地秒级重连 |

## 受控实验(隔离沙箱 + 伪造 WSS 服务器)

| 测试 | 结果 |
|---|---|
| T1 原版无心跳 | 精确 40.0s 自杀(35s 阈值 + 10s 检查粒度) |
| T2 P1 版无心跳 | 120s+ 存活 |
| T3 P2 版收 4401 | `preempted-yield` 干净让位,exit 0,锁释放 |
| T4 原版收 4401 | 12 秒 7 轮无限重连,`reconnect.success` 后 attempt 清零实证 |
| T5 keep-alive 挂起退出 | 未复现挂起(两版均 <1s)→ P3 定性为防御性 |
| T6 keeper 三振 | 1/3 → 2/3 → 击杀,节奏精确 |
| T7 12s 中断对照 | QP=3:+8.9s 套接字被销毁;QP=30:全程存活 |
| T8 90s 长中断(生产文件) | 套接字 130s 全程存活,恢复后 1.2s 重连 |

生产运行数据(5 天):旧三害导致的用户断连 **0 次**;4401 抢占 98.75% 以干净让位收场。

## 快速开始

```powershell
# 1. 常驻守护(建议加入开机自启)
powershell -ExecutionPolicy Bypass -File hub-keeper.ps1

# 2. 应用四补丁(应用后关闭所有 VSCode 窗口,让枢纽从新代码孵化)
powershell -ExecutionPolicy Bypass -File hub-patch-apply.ps1

# 回滚(运行一次回退 P4,连续运行回到原版)
powershell -ExecutionPolicy Bypass -File hub-patch-rollback.ps1
```

## 注意事项

- 插件升级会覆盖补丁文件,重新执行 `hub-patch-apply.ps1` 即可(逐针幂等);
- 同一环境保持**单窗口**使用(多窗口=多个扩展宿主=心跳错配与枢纽增殖的温床);
- 环境在平台侧休眠(envNotRunning / API 持续 400)不受本工具影响,到 CANN Lab 页面重新启动;
- 连接时卡 `Downloading with wget` = 容器直连微软 CDN 慢,用 `remote.SSH.localServerDownload: always`
  或手动预置 server 包;
- keeper 日志:`~/.atomgitdevenv/hub-keeper.log`。

## License

MIT
