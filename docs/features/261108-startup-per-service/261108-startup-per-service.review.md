# startup-per-service 代码检视报告

- 检视对象：`X:\Coding\pp2` 未提交改动（工作区 vs `HEAD`）
- 检视日期：2026-11-08
- 检视范围：`src/pp2/Private/pp2-core.ps1`、`src/pp2/Public/{pp2,Install-Pp2Startup,Uninstall-Pp2Startup}.ps1`、`src/pp2/pp2.psd1`、`src/pp2/en-US/about_pp2.help.txt`、`CHANGELOG.md`、`README*.md`、新增 `tests/Unit/Startup.Tests.ps1`、`skills/pp2/SKILL.md`
- 验证方式：逐行读 diff 与上下文；`pwsh` 与 `powershell.exe` 实测（参数绑定、模块根解析、计划任务通配、watchdog 复活、PSModulePath 误判、隐藏进程中的 `Read-Host`）；运行 `Startup.Tests.ps1` 与 PSScriptAnalyzer

## 准入结论

**不通过（1 项阻塞）**。

主路径实现基本正确：`-RunLevel Limited`、注册后校验、任务名派生、按名启动、按名/全量卸载、排序去重、服务名预校验都已落实，本机非提权注册也成功。剩余一个**阻塞**项是新增单测不隔离且实测失败；其余为设计与文档层面的建议项。

---

## 阻塞问题

### B1. 新增单测 `refuses to register a task when loaded from a source tree` 不隔离、依赖本机状态，实测失败

**位置**：`tests/Unit/Startup.Tests.ps1:138-148`

```powershell
It 'refuses to register a task when loaded from a source tree' {
    $TestHome = New-Pp2TestHome -Services ([ordered]@{ dsh = @{ command = 'pwsh' } })
    try {
        { pp2 startup-install dsh } | Should -Throw '*not on PSModulePath*'
        Get-ScheduledTask -TaskName 'pp2 Startup (dsh)' -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }
    finally { Remove-Pp2TestHome $TestHome }
}
```

**实测结果**（本机，2026-11-08）：

```
[-] refuses to register a task when loaded from a source tree
    Expected $null or empty, but got MSFT_ScheduledTask (TaskName = "pp2 Startup (dsh)", TaskPath = "\").
Tests Passed: 14, Failed: 1
```

三项缺陷：

1. **污染真实状态**：`Get-ScheduledTask` 未加 `-TaskPath '\'`，会读到真实根任务文件夹；本机确实已有 `pp2 Startup (dsh)`（正是本需求验收后的目标状态），用例因此失败。凡是按 README 装过 dsh 自启的机器，CI/本地都会红。
2. **断言没有证明力**：`startup-install` 本应在 `Assert-ModuleOnPSModulePath` 处抛错、根本走不到注册；断言「任务不存在」既可能是代码正确，也可能是任务本来就不存在（首次运行），无法区分。
3. **依赖环境的 `PSModulePath`**：该用例能通过的前提是当前进程的 `PSModulePath` 不含源码树。`tests/TestHelpers.ps1` 直接按路径导入模块，开发者若把源码目录加入 `PSModulePath`，用例会以完全不同的理由失败，CI 与本机结论不可复现。

**修复建议**：

- 单元测试不应触碰真实计划任务。用 `InModuleScope pp2 { Mock Register-ScheduledTask {}; Mock Get-ScheduledTask { $null } }` 断言「未调用 `Register-ScheduledTask`」，或断言抛错信息。
- 真正要覆盖的回归点是「失败时**不得**打印 `installed startup task`」。可 `Mock Write-Host` 后断言其未被调用，这比「任务不存在」直接得多。
- 若保留 OS 集成测试，放进 `tests/Integration`，并在 `BeforeEach` 记录基线、`AfterAll` 用唯一任务名清理。

---

## 建议问题

### S1. 按服务自启时，全局 watchdog 仍可能拉起用户未指定的服务

**位置**：`src/pp2/Private/pp2-core.ps1:1053-1058`（`Start-WatchdogIfNeeded` → `Start-WatchdogProcess`）、`src/pp2/lib/pp2-watchdog.ps1:83-108,148`

**实测复现**：

1. 临时 `PP2_HOME` 定义 `dsh`、`cpa`，均 `autoRestart=true`；
2. 给 `cpa` 写入一个**已退出进程**的 PID 文件（模拟上次异常退出/休眠后的残留）；
3. 只执行 `pp2 start dsh`；
4. 约 15 秒后 `cpa` 被拉起：

```
watchdog started pid=31896 interval=2
cpa crashed, waiting 4 s before retry 1/3
auto-restarting cpa...
restart succeeded for cpa new_pid=32904
```

**根因**：`Start-WatchdogIfNeeded` 只判断「本次参数里是否有 `autoRestart` 服务」，随后启动的是**全局** watchdog；`pp2-watchdog.ps1` 遍历 `services.json` 的**全部**服务，只看 `run/<name>.pid` 是否存在。因此残留 PID 文件会把未指定的服务当作「崩溃待恢复」处理。

**影响**：本需求验收口径是「只自启 dsh，不要拉起全部服务」。dsh 单独启动没问题；但机器上只要有别的服务残留 PID 文件，就会额外拉起别的服务。这与验收目标存在条件性冲突。

**建议**（按成本排序）：

- 最低成本：README/CHANGELOG 如实写明该边界，让用户知道残留 PID 会导致额外启动。
- 中等成本：`pp2 start <names>` 启动 watchdog 时传入「本次服务集」，watchdog 只监视线程内集合（需在 watchdog 进程参数与循环中携带）。
- 更稳妥：启动前清理不属于本次集合的 PID 文件（风险较高，会误删正在运行的服务状态，不推荐）。

### S2. PSModulePath 校验是前缀匹配，可能误放行

**位置**：`src/pp2/Private/pp2-core.ps1:1592-1617`

```powershell
$Resolved.StartsWith("$EntryPath\", [StringComparison]::OrdinalIgnoreCase) -or
$Resolved.StartsWith("$EntryPath/", [StringComparison]::OrdinalIgnoreCase)
```

**实测**：把 `C:\...\psmp-xxxx` 加入 `PSModulePath`，对 `C:\...\psmp-xxxx\projects\pp2\src\pp2` 调用，函数**放行**；随后 `Import-Module pp2` 失败（PowerShell 只在 `PSModulePath` 项的直接子目录里按 `<name>/<version>/<name>.psd1` 查找）。

即校验证明的是「路径在某项之下」，而不是「`Import-Module pp2` 会加载它」。常见场景（源码树不在 `PSModulePath`）已被正确拦截，且已有单测；但嵌套目录的误放行会让任务在下次登录时静默失败。

**建议**：改为按模块发现规则验证，例如

```powershell
$Found = Get-Module -ListAvailable -Name $ModuleName |
  Where-Object { $_.Path -like "$ModuleRoot\*" }
if (-not $Found) { throw ... }
```

或要求 `$Resolved` 的父目录（`<root>/pp2`）本身是某个 `PSModulePath` 项的直接子目录。

### S3. `startup-install all,dsh` 静默退化为只启动 dsh

**位置**：`src/pp2/Private/pp2-core.ps1:1517-1533`

`Get-StartupServiceNames @('all','dsh')` 返回 `@('dsh')`，单测 `Startup.Tests.ps1:44` 固化了这一行为，但文档与 help 从未说明。用户写 `pp2 startup-install all,dsh` 的预期多半是「全部」，实际只启动 dsh，且无任何提示。

**建议**：把「`all` 与具体名字混用」视为参数错误并给出明确提示，或在 help/README 写明规则。注意 `remove` 把 `all` 当普通服务名（报 Unknown service），两条命令对 `all` 的处理不一致，统一更好。

### S4. `startup-install`/`startup-uninstall` 的多余位置参数被静默丢弃

**位置**：`src/pp2/Public/pp2.ps1:192-201`

`pp2 startup-install a b` 中 `b` 落入 `$Field`，dispatch 不校验直接忽略。实测 `pp2 startup-install nosuch other` 只按 `nosuch` 处理。而同文件对 `add/remove/set/show` 已明确拒绝多余参数（`pp2.ps1:58-64` 的注释与检查），此处不一致。

**建议**：在两个 startup 分支加入与其他编辑命令一致的多余参数检查，提示改用逗号列表。

> 更正说明：`pp2 startup-install @('dsh','cpa')` 与 `pp2 startup-install a,b`（未加引号）都能正确绑定为数组，已分别在 pwsh 7 与 Windows PowerShell 5.1 实测确认。**数组传参本身没有问题**；问题仅在「空格分隔的多个名字」会被拆到 `$Field` 后静默丢弃。

### S5. `Install-Pp2Startup` / `Uninstall-Pp2Startup` 的数组参数传参可读性差（非缺陷）

**位置**：`src/pp2/Public/Install-Pp2Startup.ps1:5`、`Uninstall-Pp2Startup.ps1:5`

```powershell
pp2 startup-install $Name
```

实测 `Install-Pp2Startup -Name 'a','b'`、`Uninstall-Pp2Startup -Name @('zz1','zz2')` 均能正确把整个数组送到位置 1（输出 `pp2 Startup (zz1,zz2)`），**行为正确**。但依赖「数组变量作为单个位置参数传递」这一隐式规则，读者容易误以为会展开成多个位置参数。建议显式写成 `pp2 startup-install -Name $Name`，意图更清楚。

### S6. 计划任务默认设置的两个隐患：72 小时执行上限、错过触发不补跑

**位置**：`src/pp2/Private/pp2-core.ps1:1630`

```powershell
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
```

实测该 cmdlet 的默认值：`ExecutionTimeLimit=PT72H`、`StartWhenAvailable=False`、`MultipleInstances=IgnoreNew`。

- **72h 上限**：开机启动器不应该有执行时长上限；若启动流程因网络/sudo 卡住超过 72 小时会被强制终止。建议 `-ExecutionTimeLimit ([TimeSpan]::Zero)`。
- **`StartWhenAvailable=False`**：机器错过登录触发（休眠恢复、任务计划服务延迟）时不会补跑，可能出现「登录了但没自启」。建议加 `-StartWhenAvailable`。

### S7. Principal 与 Trigger 的用户标识格式不一致

**位置**：`src/pp2/Private/pp2-core.ps1:1628-1629`

```powershell
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" ...
```

本机注册后，Trigger 的 `UserId=JOHN_ASUS\John`，Principal 的 `UserId=John`。同一账号，功能可用；但在域账号、用户名与显示名不同、或 `USERDOMAIN` 未设置的机器上容易产生歧义。建议统一取 `[Security.Principal.WindowsIdentity]::GetCurrent().Name`（`DOMAIN\user`）两处共用。

### S8. `Get-StartupTaskBaseName` 借用 `$script:TaskName`，语义与跨 runspace 依赖不佳

**位置**：`src/pp2/Private/pp2-core.ps1:1536-1543`、`Initialize-Pp2Context`（`pp2-core.ps1:24`）

`$script:TaskName = 'pp2 Startup'` 是初始化写死的常量，`Get-StartupTaskBaseName` 却以变量查找方式读取并在缺失时回退到同一字面量。当前值一致所以不是 bug，但：

- `Invoke-ServiceBatch` 的 ThreadJob runspace 只复制 `ModuleRoot/Root/ConfigPath/RunDir/LogDir`，不复制 `TaskName`；在 runspace 里调用会走回退分支——靠「回退值与真实值相同」碰巧正确。
- 名字 `TaskName` 暗示完整任务名，实际是基名，与 `Get-StartupTaskName` 的返回值概念重叠，易误读。

**建议**：改为 `$script:StartupTaskBaseName`，或直接由 `Get-StartupTaskBaseName` 返回常量。

### S9. 隐藏窗口中的交互提示会让登录启动卡死

**位置**：`src/pp2/Private/pp2-core.ps1:1085`（`Read-Host 'Kill it? [y/N]'`，经 `Start-One:1114` → `Stop-LegacyOwners`）、`pp2-core.ps1:494`（`remove` 的运行中确认）、`pp2-core.ps1:358`

**实测**：在 `-WindowStyle Hidden` 的非控制台进程中执行 `Read-Host`，**10 秒内既不退出也不报错**（挂起），而非返回默认值或抛异常。

计划任务不带 `-Force`。若开机时某服务的端口被其他进程占用（`ports` 配置命中），`Stop-LegacyOwners` 会走到 `Read-Host`，登录启动就会永久挂起（直到任务计划超时/重启）。其余服务也不会启动（同一并行批次里会各自阻塞）。

**建议**：

- 计划任务的命令追加 `-Force`：`pp2 start ... -Force`（需确认这是期望语义——它会替用户结束占用端口的旧进程）。
- 或让 `Start-One` 在非交互宿主（`[Environment]::UserInteractive -eq $false` 或无控制台）时自动按 `N` 处理并记录警告。
- 至少应在 README 的 Startup 部分说明这一限制。

### S10. 文档/版本一致性

- **README 状态未同步**：`README.md:11` 与 `README_CN.md:11` 仍写 `v1.1.0`，而 `pp2.psd1` 已 1.2.0、CHANGELOG 已有 1.2.0 条目。发布前必须更新，否则 Gallery 页面与 README 自相矛盾。
- **夹带无关修改**：`README.md:56` / `README_CN.md:54` 删除了 `Install-PSResource ... -Trusted`。经核对，`Install-PSResource` 的正确参数是 `-TrustRepository`，`-Trusted` 是 `Register-PSResourceRepository` 的参数——删除是**修正**，本身正确；但它与本需求无关，建议单独提交或在 PR 说明中注明。
- **CHANGELOG 分类**：「The task no longer stops when the laptop switches to battery power」放在 `Fixed` 下，实际更接近 `Changed`。
- **help 未写逗号语法**：`pp2 help` 与 `about_pp2.help.txt` 都只写 `startup-install [name]`，未说明支持逗号列表（实现支持），也未说明 `all` 的覆盖语义（S3）。

### S11. skill 的事实性

对照实现逐条核对：

| SKILL.md 断言 | 结论 |
|---|---|
| `monit`、`-Watch`、`logs -Watch` 会阻塞 | 正确 |
| Task 以普通完整性级别运行 | 正确（`RunLevel Limited`） |
| 子集不连带 `dependsOn` | 正确（`Test-Dependencies` 只在已运行/端口开放时放行） |
| 退出码不代表服务健康 | 正确（`Start-One` 用 `Wait-ServiceStartup` 判定） |
| `pp2 config` 打开编辑器 | 基本正确；无 `EDITOR` 且找不到 VS Code/notepad 时只打印提示，未提条件 |
| `ephemeral` 必须配 `shutdownCommand` | 正确 |

未发现硬性事实错误。建议补两句：`monit` 在重定向输出/非交互宿主下不可用（对应 `Show-MonitDashboard` 的 `$cursorUsable` 分支）；`pp2 config` 依赖 `EDITOR` 或已安装编辑器。

---

## 非阻塞问题（已核对，实现正确）

### N1. 卸载通配不会误删

**位置**：`src/pp2/Private/pp2-core.ps1:1664-1665`

```powershell
Get-ScheduledTask -TaskName "$Prefix*" -TaskPath '\' ... |
    Where-Object { $_.TaskName -eq $Prefix -or $_.TaskName -like "$Prefix (*)" }
```

实测二次过滤：

```
pp2 Startup                  match=True
pp2 Startup (dsh)            match=True
pp2 Startup (dsh) extra      match=False
pp2 StartupX                 match=False
pp2 Startup (backup)         match=True
```

`pp2 Startup (backup)` 会被删除——这是设计意图（所有 `pp2 Startup*` 任务归 pp2 管理），且 `$Prefix` 是常量不含通配符。误删风险低。

### N2. 失败可见性确实修复

**位置**：`src/pp2/Private/pp2-core.ps1:1631-1647`

`-ErrorAction Stop`、`catch { throw }`、注册后 `Get-ScheduledTask` 校验三条路径都会抛出；`pp2` 顶层 `$ErrorActionPreference='Stop'`，错误能到用户终端。「注册成功但任务不存在」的假成功已被消除。

### N3. 任务名幂等与覆盖

`Register-ScheduledTask -Force` 覆盖同名任务；`Get-StartupTaskName` 排序去重保证 `dsh,cpa` 与 `cpa,dsh` 得到同一任务名。符合设计。

### N4. 生成的命令在 pwsh 7 与 Windows PowerShell 5.1 下均可正确绑定

**更正**：检视初期我曾怀疑 `pp2 start @('dsh')` 在 Windows PowerShell 5.1 的参数模式下会被当成字符串。经实测（pwsh 7 与 `powershell.exe` 5.1 各跑一次），`@('dsh')` 与 `@('dsh','cpa')` 都正确绑定为数组，`Name` 分别为 `dsh`、`dsh|cpa`，`Field` 为空。该命令形状**没有问题**。

补充：`pp2.psd1` 声明 `PowerShellVersion = '7.0'`、`CompatiblePSEditions = @('Core')`，实际上只支持 pwsh 7+；`Get-PwshPath` 的 `powershell.exe` 降级分支对 pp2 本身无意义，但不构成缺陷。

### N5. 服务名预校验位置正确

`pp2.ps1:192-198` 在触碰任务计划之前调用 `Get-ServiceNames`，未知/禁用服务会先报错；单测 `Startup.Tests.ps1:151` 覆盖。`Get-ServiceNames` 同时拒绝 `enable=false` 的服务，符合「注册时即失败」的设计。

### N6. 配置路径处理

`New-StartupTaskAction` 仅在 `-Config` 不同于 `$StateRoot/services.json` 时固化路径，避免任务绑死当前 shell 的相对路径。默认路径比较做了大小写不敏感与首尾分隔符归一化，正确。

### N7. PSScriptAnalyzer

对 `pp2-core.ps1` 运行分析器，仅 6 条既有 `PSUseUsingScopeModifierInNewRunspaces` 告警（`pp2-core.ps1:976`，ThreadJob 块），与本次改动无关。与需求描述一致。

### N8. 打包与发布

`skills/` 位于仓库根，不在 `src/pp2` 下，因此**不进入模块包**：这与「随项目发布（仓库）」一致，但与「随模块发布」不同。README 提供了 junction 安装方式；实测 junction 在目标存在、父目录不存在时会自动创建父目录，命令可用。若将来希望 skill 随 `Install-Module` 分发，需要把 `skills/` 放进 `src/pp2` 并调整 `build.ps1` 的包含规则——当前不需要，记录为已知边界。

### N9. `Startup.Tests.ps1` 其余 14 个用例

覆盖命名、排序去重、`all` 覆盖、自定义/默认 `-Config`、隐藏窗口、PSModulePath 正反例与同级前缀误匹配，粒度合适。建议补充（对应上文）：失败时不打印 success、跳过 `Register-ScheduledTask` 的断言、`all` 混用行为。

---

## 建议修复顺序

1. **B1**（阻塞）：用 Mock 重写源码树用例，去掉对真实计划任务和本机 `PSModulePath` 的依赖。
2. **S1**：至少补文档说明 watchdog 对未指定服务的残留影响；条件允许再做 watchdog 服务集收窄。
3. **S9**：处理隐藏任务中的 `Read-Host`（加 `-Force` 或非交互降级），这是会真正卡死登录启动的路径。
4. **S2/S6/S7**：收紧模块发现校验、补 `-StartWhenAvailable`/取消执行上限、统一账号格式。
5. **S10**：同步 README 的 v1.2.0 状态；拆分无关的 `-Trusted` 修改。
6. **S3/S4/S5/S8/S11**：参数语义、命名与文档收尾。

---

## 附：检视过程的环境操作记录（透明化）

为验证边界，检视时进行了以下操作：

- 曾误调用不带名字的 `Uninstall-Pp2Startup`，删除了本机已注册的 `pp2 Startup (dsh)`；随后立即用已安装的 pp2 1.2.0 执行 `pp2 startup-install dsh` 恢复，已确认任务状态 `Ready`、`RunLevel=Limited`、动作为 `pp2 start @('dsh')`。
- 临时创建 `PP2_HOME` 测试目录与测试服务，验证后已清理 PID、日志与目录。
- 一次端到端命令复现因服务常驻而超时，遗留的子进程与临时目录已全部终止并删除。
- 未修改仓库任何源码或文档；本报告为唯一新增文件。