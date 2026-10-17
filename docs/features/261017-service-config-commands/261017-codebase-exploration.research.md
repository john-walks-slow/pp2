# pp2 新增运行期配置命令（add/remove/set）— 代码现状探索

日期：2026-10-17
范围：`src/pp2/**`、`tests/**`、`build.ps1`、`.github/workflows/**`、`docs/**`
目的：为「新增运行期修改 services.json 的命令」摸清现有约定与改动点。

---

## 1. 配置读写路径

### 1.1 `Read-Pp2Config` 的加载与规范化

`src/pp2/Private/pp2-core.ps1:31-66`

```powershell
function Read-Pp2Config {
  $Path = $script:ConfigPath

  if (-not (Test-Path $Path)) {
    Set-Content -Path $Path -Value '{"settings":{},"services":{}}' -Encoding UTF8   # :44
  }

  $Raw = Get-Content $Path -Raw -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($Raw)) { $Raw = '{"settings":{},"services":{}}' } # :48

  try {
    $script:Config = $Raw | ConvertFrom-Json -ErrorAction Stop                       # :51
  }
  catch {
    throw "Invalid JSON in '$Path': $($_.Exception.Message)"                         # :54
  }

  if ($null -eq $script:Config) { $script:Config = [PSCustomObject]@{} }             # :57

  foreach ($Section in @('settings', 'services')) {                                  # :59-63
    $Value = $script:Config.PSObject.Properties[$Section]
    if ($Value -and $Value.Value -is [PSCustomObject]) { continue }
    $script:Config | Add-Member -MemberType NoteProperty -Name $Section -Value ([PSCustomObject]@{}) -Force
  }

  $script:ConfigLoaded = $true                                                        # :65
}
```

规范化语义（新增命令必须保持一致）：

- 文件不存在 → 落一个 `{"settings":{},"services":{}}`（**UTF8 带 BOM**，见下节注释）。
- 空文件 / 全空白 → 视为空配置，不报错。
- JSON 非法 → `throw "Invalid JSON in '<path>': ..."`（测试断言 `*Invalid JSON*`）。
- `settings` / `services` 两段缺失或类型不对 → `Add-Member -Force` 强制补成空 `PSCustomObject`（保证 StrictMode 下属性访问安全）。
- 结果缓存在 `$script:Config`，靠 `$script:ConfigLoaded` 做一次性加载。`Initialize-Pp2Config`（:68-70）是惰性入口。

### 1.2 现有的写回点

**结论：全仓库没有任何一处把 `$script:Config` 序列化回 `services.json`。**

对 `ConfigPath` / `services.json` 的写入只有一处：

- `pp2-core.ps1:44` — `Read-Pp2Config` 内部，仅在文件**不存在**时写默认骨架。用的是 `Set-Content -Encoding UTF8`（PowerShell 7 下**带 BOM**）。

`ConvertTo-Json` 在整个 `src/` 里只出现一次，且是**只读输出**：
- `pp2-core.ps1:850` — `Show-Status` 的 `-Format json` 分支。

其他 `Set-Content` 全部写的是**运行期状态文件**（`run/*.pid`、`run/*.healthy`、`run/watchdog.pid`、启动脚本 `run/<svc>.start.ps1`），不是配置：

| 位置 | 写入目标 |
| --- | --- |
| `pp2-core.ps1:289` | `run/<svc>.healthy` |
| `pp2-core.ps1:629` | `run/watchdog.pid.new` |
| `pp2-core.ps1:727-728` | 提权启动脚本 `run/<svc>.start.ps1` |
| `pp2-core.ps1:747,752,762,769` | `run/<svc>.elevated`、`run/<svc>.pid` |
| `lib/pp2-watchdog.ps1:64` | `run/watchdog.pid` |
| `lib/pp2-watchdog.ps1:134` | `run/<svc>.retry` |
| `build.ps1:91` | 打版时替换 staging 里的 `ModuleVersion` |

`Open-ConfigFile`（`pp2-core.ps1:124-143`）只是用 `& $Editor $script:ConfigPath` **打开编辑器**，自己不写文件——它是唯一让用户改配置的现有路径（`pp2 config`）。

> 因此：新增 add/remove/set 命令时，`Read-Pp2Config` 与新增的 `Save-Pp2Config` 之间的读写是**全新的一对**，没有既有写回代码可复用。写回需要考虑：BOM（现有文件带 BOM，`ConvertFrom-Json` 能读带 BOM 内容，但无 BOM 更干净）、`-Depth`（`ConvertTo-Json` 默认深度 2，services 是两层，字段数组会超深，测试助手用 `-Depth 10`，见 `tests/TestHelpers.ps1:51`）、以及注释/键序丢失（JSON 无注释，但键序会由 PSCustomObject 保持）。

### 1.3 `ConfigPath` 的解析链

- `Initialize-Pp2Context`（`pp2-core.ps1:16-29`）设置 `$script:ConfigPath = Join-Path $script:Root 'services.json'`（:21）。
- `pp2.ps1:28-31` 的 `-Config <path>` 覆盖 `$script:ConfigPath`，随后才 `Read-Pp2Config`（:32）。
- `lib/pp2-watchdog.ps1:11` 与 `lib/pp2-run-service.ps1:10-11` 也用同一套。
- `startup-install` 把当前 `$script:ConfigPath` 固化进计划任务命令行（`pp2-core.ps1:1064-1066`）。

---

## 2. 新增一个 `pp2 <action>` 子命令的完整清单

### 2.1 必改文件

| # | 文件 | 作用 | 具体位置 |
| --- | --- | --- | --- |
| 1 | `src/pp2/Public/pp2.ps1` | 调度器：动作白名单 + 分支 + help | `ValidateSet` :4-6；`switch` 分支 :34-113；help heredoc :36-77 |
| 2 | `src/pp2/Private/pp2-core.ps1` | 实际实现函数（私有，不导出） | 末尾追加，如 `:1064+` |
| 3 | `src/pp2/Public/<Verb>-Pp2< Noun>.ps1` | 薄包装（可选但为既有惯例） | 新建文件 |
| 4 | `src/pp2/pp2.psm1` | `Export-ModuleMember`（**只有加了包装函数才需要改**） | :16-29 |
| 5 | `src/pp2/pp2.psd1` | `FunctionsToExport`（与 #4 同步） | :23-36 |
| 6 | `src/pp2/en-US/about_pp2.help.txt` | 外部帮助主题的 COMMANDS 列表（**已过期**，见 3.3） | :21-30 |
| 7 | `tests/Unit/Module.Tests.ps1` | 硬编码的导出函数清单断言 | :19-25 |
| 8 | `README.md` / `README_CN.md` | 用户可见的命令列表与配置字段表 | 见 5.2 |

#### 关键：`pp2.psm1` 与 `pp2.psd1` 必须成对改

`pp2.psm1:12-14` 用 `Get-ChildItem Public/*.ps1` 全部 dot-source，但 `Export-ModuleMember`（:16-29）是**显式白名单**——不在名单里就不会导出。`pp2.psd1:23-36` 的 `FunctionsToExport` 又是第二份白名单。

`tests/Unit/Module.Tests.ps1:31-36` 会断言两者严格相等：

```powershell
It 'has a manifest whose exported functions match the module' {
    $Manifest = Test-ModuleManifest -Path (Join-Path $ModuleRoot 'pp2.psd1')
    $FromManifest = $Manifest.ExportedFunctions.Keys | Sort-Object
    $FromModule = (Get-Module pp2).ExportedFunctions.Keys | Sort-Object
    $FromManifest | Should -Be $FromModule
}
```

**只改一个 → CI 红。**

### 2.2 端到端范例：`pp2 startup-install`

```
[用户]  pp2 startup-install
          │
          ├─ 1. src/pp2/Public/pp2.ps1:4-6    ValidateSet 放行 'startup-install'
          ├─ 2. pp2.ps1:26                     Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
          ├─ 3. pp2.ps1:32                     Read-Pp2Config
          ├─ 4. pp2.ps1:111  switch 分支
          │      'startup-install' { Install-StartupTask `
          │            (Join-Path $script:ModuleRoot 'pp2.psd1') (Get-Pp2Root) $script:ConfigPath }
          ├─ 5. src/pp2/Private/pp2-core.ps1:1064-1072  Install-StartupTask
          │      拼命令串 → New-ScheduledTaskAction/-Trigger/-Principal → Register-ScheduledTask
          └─ 6. src/pp2/Private/pp2-core.ps1:151-157  Get-PwshPath（内部依赖）
```

PowerShell 侧等价入口：`src/pp2/Public/Install-Pp2Startup.ps1:1-3`

```powershell
function Install-Pp2Startup {
    pp2 startup-install
}
```
→ `pp2.psm1:27` 显式导出 → `pp2.psd1:34` 声明 → `Module.Tests.ps1:24` 断言。

### 2.3 第二个范例：`pp2 logs`（带参数的包装）

- `Public/Watch-Pp2Logs.ps1:1-7` → `pp2 logs $Name -Watch`
- `Public/Get-Pp2Logs.ps1:1-7` → `pp2 logs $Name -Tail $Tail`
- `Public/pp2.ps1:101-105` 分支，参数从位置参数 `$Name` / `$Tail` / `$Watch` 取
- `Private/pp2-core.ps1:863-867` `Show-Logs` → 外部脚本 `lib/pp2-watch-logs.ps1`
- 同样在 `pp2.psm1:22-23`、`pp2.psd1:29-30` 各有一份

> 规律：**一个动作最多一个包装函数**；需要参数时包装函数收窄成 `Mandatory` + 少量具名参数，再转调位置参数。

### 2.4 需要注意但不必改的

- `pp2.ps1:19` 已有 `[string]$Config` 参数，但**没有 `-Force` 之外的状态参数**。若新命令要接受服务名字段值，需要新增参数（如 `[hashtable]$Property` 或按位置/命名传 `-Command`、`-Ports` 等）——这会改动 `pp2` 的公共签名，是最需要设计的部分。
- `$Force`（`pp2.ps1:17`）已存在，语义是「跳过确认提示」（当前仅 `Start-Many` 用），新命令的「覆盖已有服务」提示可以复用它。

---

## 3. 文件与目录布局约定

### 3.1 Public/ 一函数一文件

`src/pp2/Public/` 下 11 个 `.ps1`（`pp2.ps1` 除外）严格一函数一文件，函数名 = 文件名（含 `.ps1` 后缀前的完整名词动词形式）：

| 文件 | 函数 | 行数 |
| --- | --- | --- |
| `Get-Pp2Logs.ps1` | `Get-Pp2Logs` | 8 |
| `Get-Pp2Status.ps1` | `Get-Pp2Status` | 8 |
| `Get-Pp2WatchdogStatus.ps1` | `Get-Pp2WatchdogStatus` | 3 |
| `Install-Pp2Startup.ps1` | `Install-Pp2Startup` | 3 |
| `Restart-Pp2Service.ps1` | `Restart-Pp2Service` | 7 |
| `Start-Pp2Service.ps1` | `Start-Pp2Service` | 8 |
| `Start-Pp2Watchdog.ps1` | `Start-Pp2Watchdog` | 3 |
| `Stop-Pp2Service.ps1` | `Stop-Pp2Service` | 7 |
| `Stop-Pp2Watchdog.ps1` | `Stop-Pp2Watchdog` | 3 |
| `Uninstall-Pp2Startup.ps1` | `Uninstall-Pp2Startup` | 3 |
| `Watch-Pp2Logs.ps1` | `Watch-Pp2Logs` | 7 |
| `pp2.ps1` | `pp2` | 114 |

唯一例外是 `pp2.ps1`：它是顶层调度器，函数名就是模块名 `pp2`，不符合 Verb-Noun（`PSScriptAnalyzerSettings.psd1:11` 关了 `PSUseSingularNouns`，但动词规则靠 `pp2` 不在 `FunctionsToExport` 之外……实际上 `pp2` 确实在导出列表首位）。

命名规律：动词用 `ApproveVerb` 标准动词（Get/Start/Stop/Restart/Install/Uninstall/Watch），名词前缀统一 `Pp2`，服务类用 `Pp2Service`。**新增命令的包装函数建议 `Add-Pp2Service` / `Remove-Pp2Service` / `Set-Pp2Service`。**

> 注意：`Private/` 是**单文件多函数**——`pp2-core.ps1` 一个文件装了全部 ~40 个内部函数（1077 行）。新实现函数应追加到此文件，不必新建文件。

### 3.2 help 文本格式

`pp2.ps1:36-77` 是一个 heredoc（`@'...'@`，单引号不插值），通过 `| Write-Host` 输出。格式：

```
Usage: pp2 <action> [name] [options]

Core Actions:        ← 分组标题，左侧动作名 + 右侧对齐说明
  status [name]              Show status table (-Format json for JSON output)
  ...

Options:             ← 选项说明段
  -Watch                     Live monitoring mode (for status/logs)
  ...

Examples:            ← 示例段
  pp2 start cloudflared
```

分组：「Core Actions」/「Utility Actions」/「Watchdog Control」/「Startup Control」/「Options」/「Examples」。新命令应插到合适的组（如 Utility 组或新开「Config Actions」组），并同步 Options 段（若引入新参数）与 Examples 段。

### 3.3 `en-US/about_pp2.help.txt`

`src/pp2/en-US/about_pp2.help.txt:21-30` 里有一份**独立的 COMMANDS 列表**，目前已经**落后于实际**——没有 `list`、`config`、`watchdog-status`、`startup-uninstall`、`restart` 的 `-Force`，也缺 `help`。格式为纯文本的 `TOPIC` / `SHORT DESCRIPTION` / `LONG DESCRIPTION` / `SEE ALSO`（about_* 主题约定）而非 `Get-Help` 的 MAML。

**结论**：该文件不是 CI 校验项（无测试引用 `about_pp2.help.txt`），但出于一致性应同步；它是 `Get-Help about_pp2` 的内容来源。

---

## 4. 测试设施

### 4.1 `tests/TestHelpers.ps1`

- `Get-Pp2ModuleRoot`（:15）→ `$script:Pp2ModuleRoot`，由 `$PSCommandPath` 上溯得到 `<repo>/src/pp2`（:12-13）。用 `$PSCommandPath` 而非 `$PSScriptRoot`，因为后者指向 dot-source 发起方。
- `Get-Pp2TestsRoot`（:16）。
- **`New-Pp2TestHome`（:24-54）** — 核心助手：

  ```powershell
  param([hashtable]$Services = @{}, [hashtable]$Settings = @{})
  ```
  行为：
  1. 模块未加载则 `Import-Module ... -Force`（:37-39）。
  2. 在 `[IO.Path]::GetTempPath()` 下建 `pp2-test-<8位guid>` 目录（:41-42）。
  3. 组装 `settings`（默认 `startupVerifyWait=500; portCheckTimeout=300; watchdogInterval=2`）+ `services`，`ConvertTo-Json -Depth 10 | Set-Content services.json -Encoding UTF8`（:44-51）。
  4. `$env:PP2_HOME = $Home_`（:52）——**进程级全局副作用**。
  5. `return $Home_`（:53）。
  
  `-Services` / `-Settings` 都是 hashtable，值可以是嵌套 hashtable / `[ordered]@{}`。

- `Remove-Pp2TestHome -Path`（:56-78）：先杀该 home 的 `run/*.pid` 指向的进程（**保护 `$PID` 与其父进程**，:63-68），再 `Remove-Item -Recurse -Force`。
- `New-Pp2LongRunningService -Extra`（:80-92）：返回一个 `pwsh -NoProfile -Command "while($true){Start-Sleep 1}"` 的服务定义。
- `Wait-Pp2ProcessExit -ProcessId -TimeoutSeconds`（:94-106）：轮询进程消失。

### 4.2 `tests/run-tests.ps1`

- `-Scope Unit|Integration|All`（:8-9、:16-20），`-Detailed`（:10、:25）。
- 用 `New-PesterConfiguration` 编程式配置（:22-27），`Run.PassThru = $true`。
- 打印 `Passed/Failed/Skipped` 并逐条列出失败 Describe/It（:29-36）。
- `exit $(if ($Result.FailedCount) { 1 } else { 0 })`（:38）——CI 依赖此退出码。
- **筛选粒度 = 目录**（`tests/Unit` / `tests/Integration`），没有 Tag 筛选。

### 4.3 `tests/Unit/*.Tests.ps1` 风格

Pester **5.x**（`build.ps1:57` 要求 `Pester >= 5.5.0`；`New-PesterConfiguration` 亦为 v5 API）。

固定骨架（`Config.Tests.ps1:6-13`、`Module.Tests.ps1:6-14`、`Process.Tests.ps1:11-19`）：

```powershell
BeforeAll {
    . (Join-Path $PSScriptRoot '..\TestHelpers.ps1')
    Import-Module (Join-Path (Get-Pp2ModuleRoot) 'pp2.psd1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module pp2 -Force -ErrorAction SilentlyContinue }
Describe '<能力域>' {
    BeforeEach { $TestHome = New-Pp2TestHome [-Services ...] [-Settings ...] }
    AfterEach  { Remove-Pp2TestHome $TestHome }
    It '<第三人称动词开头的英文描述>' { ... }
}
```

Describe 命名：能力域短语，如 `'Configuration loading'`、`'Dependency ordering'`、`'Module structure'`、`'Path resolution'`、`'Script-host compatibility'`、`'Process tracking'`。

**从模块作用域调用私有函数**是标准做法（`& (Get-Module pp2) { ... }`）：

```powershell
$Layers = & (Get-Module pp2) {
    Initialize-Pp2Context -ScriptRoot (Get-Pp2Root)
    Read-Pp2Config
    Get-DependencyLayers @('db', 'api', 'web')
}
$Layers.Count | Should -Be 3
```
（`Config.Tests.ps1:104-113`）

要点与陷阱（`Process.Tests.ps1:5-7` 有明文注释）：
- **`Should` 在模块作用域内不可用**——断言必须留在测试作用域，模块块内只做计算并 `return` 值。
- 每个模块块要**自己先调 `Initialize-Pp2Context` + `Read-Pp2Config`**，因为新开的调用不共享 `$script:` 状态（`Config.Tests.ps1:78-80、:104-106`）。
- 捕获模块内 `Write-Warning` 用 `3>&1`（`Config.Tests.ps1:151-155`）。

现成的配置读写测试可直接扩展：`Config.Tests.ps1:15-91` 的 `Describe 'Configuration loading'` 覆盖了「默认配置生成」「空文件」「非法 JSON」「缺失 -Config 文件」「缺 section 的规范化」「-Config 覆盖」「禁用服务不可见」「未知名报错」「settings 覆盖读取」共 9 个 It——新增 add/remove/set 的往返（write → 重新 read → 断言）测试应加在这里。

---

## 5. 文档与 CI 约束

### 5.1 CI

`.github/workflows/ci.yml`（push/PR 到 master|main，`windows-latest`）：

| 步骤 | 命令 | 内容 |
| --- | --- | --- |
| Lint | `.\build.ps1 -Lint` | PSScriptAnalyzer |
| Test | `.\build.ps1 -Test` | 经 `tests/run-tests.ps1 -Scope All` |
| Build | `.\build.ps1 -Build` | 仅冒烟：staging + manifest 可解析 |

`.github/workflows/publish.yml`（tag `v*`）：Ensure PSResourceGet → Lint → Test → 从 tag 解析版本并 `.\build.ps1 -Version <v> -Build -Publish`。版本号 regex `^\d+(\.\d+){1,3}$`（:42-44），非法 tag 直接抛错。

### 5.2 PSScriptAnalyzer 配置

`src/pp2/PSScriptAnalyzerSettings.psd1`：

```powershell
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                    # pp2 是 CLI，Write-Host 是刻意的
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSReviewUnusedParameter'
    )
}
```

`build.ps1:37` 以 `-Severity Warning` + 该 settings 跑 `Invoke-ScriptAnalyzer -Path $ModuleRoot -Recurse`；**只有 Error 会让构建失败**（:49），Warning 仅打印表格（:45-48）。

> 对新增命令的影响：
> - `Add-Pp2Service` / `Set-Pp2Service` 等动词会被 `PSUseApprovedVerbs` 校验——`Add`/`Set`/`Remove` 都是批准动词，安全。
> - `PSUseShouldProcessForStateChangingFunctions` 已排除，不必加 `-WhatIf`/`-Confirm`（但设计上仍可考虑）。
> - `Write-Host` 可用（符合现有风格）。

### 5.3 `build.ps1` 的步骤（哪些会让新命令需要同步）

- `Step-Lint`（:33-53）— 见上。
- `Step-Test`（:55-71）— 调 `tests/run-tests.ps1 -Scope All`，非零退出即失败。**因此 `Module.Tests.ps1` 的导出清单断言是硬门禁。**
- `Step-Build`（:73-98）：
  - 复制 `src/pp2` → `output/pp2`，排除 `PSScriptAnalyzerSettings.psd1`、`services.example.json`（:79-85）。**没有「帮助文件自动生成」步骤**，`en-US/about_pp2.help.txt` 是手工维护的。
  - 正则替换 staging 里的 `ModuleVersion`（:90-91）。
  - `Test-ModuleManifest`（:94）——只验证 manifest 自身有效，**不校验 FunctionsToExport 与实际导出的一致性**（那由单元测试兜底）。
- `Step-Publish`（:100-156）— 从 `output/` 发布，重复版本视为 no-op。

**注意**：`Step-Build` 的 `-Exclude` 列表引用了 `services.example.json`，但该文件在仓库中**并不存在**（`ls src/pp2/*.json` 为空）——是历史残留，无害。

---

## 6. CHANGELOG 与版本约定

`CHANGELOG.md` 采用 **Keep a Changelog 1.1.0 + SemVer 2.0.0**（文件头 :5-6 明文声明）。

当前状态：

- 最新条目 `## [1.0.1] - 2026-10-17`，含一个 `### Fixed` 段（4 条）。
- 之前是 `## [1.0.0] - 2026-10-17`。

格式（严格）：

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added        ← 新功能用这个段标题
- 一句话，行宽 ~72 字符换行，可用反引号包代码标识符。

### Fixed
- ...

### Changed
- ...
```

条目正文是**英文**（现有 4 条 Fixed 全英文），带空行分隔的多行段落、72 字符软换行，必要处缩进续行（对齐 `- ` 后两个字）。

**新增功能应如何记录**：新增一个 `## [1.1.0] - <日期>`（minor bump，符合 SemVer 的「向后兼容的新功能」）段，标题 `### Added`，描述新命令及用法。同时：

- `.github/workflows/publish.yml:41` 从 **git tag** 取版本号，tag 形如 `v1.1.0`。
- `src/pp2/pp2.psd1:3` 的 `ModuleVersion` 也需同步（当前是 `'1.0.0'`，**已落后于 CHANGELOG 的 1.0.1**；`build.ps1` 只改 staging 副本，源文件靠手改）。
- `pp2.psd1:45` 的 `ReleaseNotes` 当前停留在「Initial release...」。

---

## 7. 现有配置校验

### 7.1 结论：没有集中的校验层

全仓库**没有** `Test-ServiceDefinition` / `Assert-*` 之类的校验函数。搜索 `Validate` / `Assert` 在 `src/` 下只命中 `ValidateSet`（参数面）和注释文字。

现有的「校验」全部是**在使用点分散触发的即时检查**：

| 校验 | 位置 | 形式 |
| --- | --- | --- |
| 未知服务 | `pp2-core.ps1:101`（`Get-ServiceNames`）、`:113`（`Get-ServiceConfig`） | `throw "Unknown service: $Name"` |
| 服务被禁用 | `pp2-core.ps1:104` | `throw "Service is disabled: $Name"` |
| 非法 JSON | `pp2-core.ps1:54` | `throw "Invalid JSON in '<path>': ..."` |
| -Config 文件不存在 | `pp2.ps1:29` | `throw "Config file not found: $Config"` |
| **ephemeral 必须有 shutdownCommand** | 见下 | `Write-Host "ERROR: ..."` + `return` |

### 7.2 `ephemeral` → `shutdownCommand` 校验的位置

**两处重复，逻辑相同但一次在 start、一次在 stop：**

```powershell
# src/pp2/Private/pp2-core.ps1:703-707  （Start-One 内）
  # Validate ephemeral service configuration
  if ($IsEphemeral -and -not (Get-ServiceProperty $Service 'shutdownCommand')) {
    Write-Host "ERROR: ephemeral service $ServiceName requires shutdownCommand"
    return $false
  }
```

```powershell
# src/pp2/Private/pp2-core.ps1:474-478  （Stop-One 内）
  if ($ProcessOrEphemeral -eq 'ephemeral') {
    if (-not (Get-ServiceProperty $Service 'shutdownCommand')) {
      Write-Host "ERROR: ephemeral service $ServiceName requires shutdownCommand"
      return
    }
```

对应的集成测试：`tests/Integration/Service.Tests.ps1:171-175`，断言 `pp2 start eph` 输出匹配 `'requires shutdownCommand'`。

注意其性质：**不是 throw，是 `Write-Host` + `return`**（走「操作失败」而非「异常」通道），退出码不改。

### 7.3 其他字段校验的缺失

- **`command`（README 标注为唯一 required）没有任何校验**。`lib/pp2-run-service.ps1:32` 直接 `$Command = Get-ServiceProperty $Service 'command'`，缺失时得到 `$null`，会在 `:45` / `:50` 处以模糊的方式失败（且是**异步**失败——`Start-One` 靠 `Wait-ServiceStartup` 事后才发现）。
- **`ports` 无类型 / 范围校验**。`pp2-core.ps1:378`、`:664`、`:743`、`:822` 直接把 `ports` 里的值喂给 `Test-Port [int]$Port` 和 `Get-NetTCPConnection -LocalPort`——非数字会在此处抛类型转换错误。
- **`arguments` / `dependsOn` / `shutdownArguments` 无类型校验**，靠 `@(...)` 包裹容错。
- **`dependsOn` 不校验被依赖者是否存在**：`Test-Dependencies`（`:370-386`）会走 `Get-ServiceConfig $Dep`，未知名会在此抛 `Unknown service`（间接校验，非显式）。
- **`dependsOn` 环**只在 `Get-DependencyLayers`（`:445-449`）打 `Write-Warning "Circular dependency detected among: ..."` 并继续。
- **`maxRetries` / `autoRestart` / `shell` / `elevated` 等布尔与数值字段无校验**，仅在各自使用点用 `(Get-ServiceProperty $Service 'x' $default) -eq $true` 做宽松判断。

> **对新增命令的启示**：运行期写配置意味着错误的字段值会**持久化**，而现在所有校验都是「启动时才由 `pp2 start` 发现」的延迟校验。新增 add/set 命令若不在写入前做一次集中校验（至少：`command` 非空、`ports` 为正整数数组、`ephemeral ⇒ shutdownCommand`、`dependsOn` 指向已存在的服务），就会把现在能靠 `pp2 start` 立即暴露的错误推迟到下次启动。建议把 §7.2 那两处重复的 ephemeral 检查提炼成一个 `Test-ServiceDefinition` 之类的私有函数，写入路径与启动路径共用。

---

## 8. 附：探索中发现的现存不一致（供决策参考）

1. **`pp2.psd1:3` 的 `ModuleVersion = '1.0.0'` 落后于 `CHANGELOG.md` 的 1.0.1**（源文件从不自动同步版本）。
2. **`en-US/about_pp2.help.txt:21-30` 的命令列表已过期**，缺 `list` / `config` / `restart` / `watchdog-status` / `startup-uninstall`。
3. **`build.ps1:81` 排除的 `services.example.json` 在仓库中不存在**。
4. **`README.md:139-157` 的配置字段表列出了 `displayName` / `env` / `inheritEnv` 等字段**，但源码中 `displayName` 从未被读取（`Show-Status` 用的是 `description`，`pp2-core.ps1:846`）。
