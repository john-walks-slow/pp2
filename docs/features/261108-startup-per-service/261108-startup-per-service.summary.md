# 按服务开机自启 + 随项目发布的 agent skill

日期：2026-11-08
范围：`src/pp2/**`、`tests/**`、`README*.md`、`CHANGELOG.md`、`skills/pp2/SKILL.md`
版本：1.2.0（仅发布到本机 `D:\psrepo` 本地仓库，未上 PSGallery）
检视：[261108-startup-per-service.review.md](261108-startup-per-service.review.md)

## 背景与诉求

1. 让 dsh 开机自启，且**只**自启 dsh。
2. 写一个教 agent 使用 pp2 的 skill，随本项目发布。

## 问题诊断

`pp2 startup-install` 有两个真实缺陷（均实测）：

- **假成功**：以 `-RunLevel Highest` 注册任务，非管理员会话下
  `Register-ScheduledTask` 报"拒绝访问"，但错误被 `-ErrorAction SilentlyContinue`
  吞掉，函数仍打印 `installed startup task`。实测任务列表为空。
- **范围过宽**：命令固定为 `pp2 start all`，会拉起配置里的全部服务。

进一步实测又暴露两个会让"只自启 dsh"失效的问题：

- **watchdog 复活无关服务**：watchdog 遍历全部 `autoRestart` 服务，只看
  `run/<name>.pid` 是否存在。上一会话残留的 PID 文件会让它把没人要求启动的服务
  拉起来（实测 15:04 启动 dsh 后，opencode、cpa 被一并复活）。
- **隐藏窗口挂死**：计划任务无控制台，`Read-Host` 在隐藏进程中不报错而是**永久阻塞**
  （实测 12 秒无退出）。端口被占用时会卡死整个登录启动。

## 决策

- `startup-install [name]`：不传名字=全部（向后兼容）；传名字=只启动这些。支持逗号
  列表，排序去重；任务名按集合派生（`pp2 Startup (dsh)`），不同子集可共存。
  `all` 与具体名字混用直接报错。多余的位置参数也报错，改为提示逗号语法。
- `startup-uninstall [name]`：不传=删除全部 `pp2 Startup*`；传=只删对应任务。
- 注册降为 `-RunLevel Limited`：普通会话即可注册；`elevated` 服务仍由 pp2 内部提权。
- 注册后 `Get-ScheduledTask` 复核，失败即 throw。
- 任务按**模块名**导入，升级后仍生效；用 `Get-Module -ListAvailable` 校验当前副本就是
  名称解析到的那份，源码树导入直接拒绝。
- watchdog 收窄：新增 `run/watchdog.services` 记录被监视集合；`stop` 时移除，避免
  停止后又被复活。裸 `pp2 watchdog-start` 仍覆盖全部 `autoRestart` 服务。
- 非交互探测（`Console.WindowWidth` 抛错即无控制台）跳过确认提示，不再阻塞。
- 任务设置 `-StartWhenAvailable`、取消 72h 执行上限、电池下继续运行。
- skill 放仓库顶层 `skills/pp2/SKILL.md`（分发副本）；README 说明如何 junction 到
  `~/.claude/skills/`。

## 验证

- 单元：`Startup.Tests.ps1` 15 项 + 既有 76 项，共 91 项全通过。
- 集成：`Watchdog.Tests.ps1` 5 项全通过，含新增两条回归用例
  （不复活未指定的残留服务、停止后不再被监视）。
- Lint：仅剩 6 条既有的 ThreadJob 告警。
- 实机：非提权注册成功；停 dsh 后手动触发任务，约 4 分钟后 4180 恢复监听，
  HTTP 401（dsh 自身认证页）；`watchdog.services` 只含 `dsh`。
- uninstall 按名/全部/重复、重新 install 均验证。

## 已知边界

- `skills/` 在仓库根，不进入模块包；随仓库发布，不随 `Install-Module` 分发。
- 指定子集不会连带启动 `dependsOn`；依赖未运行时该服务拒绝启动（已写入 README）。
- dsh 冷启动约 4 分钟才监听端口，属于 dsh 自身行为，与 pp2 无关。

## 顺带修正

- README 中 `Install-PSResource -Trusted` 是错误参数（`-Trusted` 属于
  `Register-PSResourceRepository`；`Install-PSResource` 的对应参数是
  `-TrustRepository`），删除该参数。
- README 中"直接模式无 PATH 查找"与实现不符：`& $command` 仍会经 PATH 解析。