# 服务配置命令：show / add / set / remove

日期：2026-10-17
范围：`src/pp2/**`、`tests/**`、`README*.md`、`CHANGELOG.md`
提交：`2bf3bf4`（master，已合并）
调研：[261017-codebase-exploration.research.md](261017-codebase-exploration.research.md)

## 背景与诉求

用户诉求是"新增修改设置的命令（add、remove 一类的），参考 pp2 的 canonical 做法"。

改动前，`services.json` 是唯一事实来源，但**只有读路径**——全仓库唯一写配置的地方是
`Read-Pp2Config` 在文件缺失时落一个默认骨架（`pp2-core.ps1:44`）。用户改配置的唯一
入口是 `pp2 config`，即丢给编辑器：

- 每个字段都没有校验，写错的 `command`/`ports` 要等到下次 `pp2 start` 才暴露，
  而且是异步暴露（`Start-One` 靠 `Wait-ServiceStartup` 事后才发现）。
- 真实配置里 `env` 存着明文密钥（本机 `~/.pp2/services.json` 有 7 个服务），
  手改的出错代价不低。
- 本机已留有用户手工备份 `services.json.bak-20261014-remove-cloudflared`，说明
  "改坏了想回退"是真实发生过的。

"参考 canonical 做法"按 pm2 的语义落地：pm2 中配置集中在一处、通过命令编辑，
命令作用于"进程集合"这一抽象；且 pm2 本身没有函数 API，配置变更就是 `pm2 start`/
`pm2 delete` 这类 CLI 动作。

## 决策

### 1. 范围：只做 services.*，不做 settings.*

用户明确选择"仅服务增删改"。`settings.*`（全局项）继续手工编辑。

### 2. 生效时机：默认只落盘，`-Restart` 显式生效

用户明确选择。理由：改名/改 command 而忘了重启，会造成"状态与实际不符"；
但自动重启又可能意外中断正在跑的服务。折中做法是落盘为默认，把生效交给显式开关，
并在目标正在运行时提示"进程仍使用启动时的设置"。

### 3. 只加 `pp2` 子动作，不加 PowerShell 包装函数

本项目 `list`/`config`/`monit`/`help` 等本就没有包装函数（`pp2.psm1` 导出白名单里
没有它们）。加包装函数需要同步三处白名单，而 `Module.Tests.ps1` 会断言
`pp2.psm1` 与 `pp2.psd1` 严格相等，漏一处 CI 红。pm2 也没有函数 API。
因此本次不动 `pp2.psm1`/`pp2.psd1` 的导出列表。

### 4. 写回保真度（实测确认，非推断）

| 项 | 结论 |
| --- | --- |
| BOM | 现有文件无 BOM；PS7 的 `Set-Content -Encoding UTF8` 也是无 BOM，一致 |
| 换行 | 现有文件 CRLF；`ConvertTo-Json` 输出 CRLF，一致 |
| 缩进 | 均为 2 空格 |
| 尾换行 | 现有文件无尾换行 → 写入用 `-NoNewline` |
| 键序 | `ConvertFrom-Json` → `ConvertTo-Json` 保留键序 |
| 非 ASCII | CJK 原样保留，不转 `\uXXXX` |
| **`-Depth`** | **必须显式给足**。默认 `-Depth 2` 会把嵌套的 `env` 截断成字符串 `"System.Collections.Specialized.OrderedDictionary"` 并告警——一次编辑就会写坏配置 |

写入走临时文件 + `Move-Item`，中断时保留上一版而非写坏。

## 实现

### 命令面

```
pp2 show <name>                # 单服务定义（-Format json 输出 JSON）
pp2 add  <name> -Field @{...}  # 新增（-Force 覆盖同名）
pp2 set  <name> <field> <value># 改单字段
pp2 remove <name>[,<name>]     # 移除（-Purge 连带删状态与日志）
```

`-Restart` 重启本次编辑涉及的服务；`-Force` 跳过"目标正在运行"的确认。

### 类型强制（关键设计）

命令行传来的一切都是字符串。若不强制类型，`set web maxRetries 5` 会写入 `"5"`，
而下游是 `(Get-ServiceProperty $S 'maxRetries' 3)` 这类与数字比较的代码。

`Get-ServiceFieldType` + `ConvertTo-FieldValue` 按字段名决定类型：布尔接受
`true/false/1/0/yes/no/on/off`；数字走 `TryParse`；数组接受逗号分隔或 JSON 数组；
对象（`env`）接受 JSON。未知字段默认按 JSON 解析，需要 `-Force` 才允许写入
（不拒绝，因为 pp2 会忽略它不认识的字段，拒绝反而会挡住手工加的字段）。

### 写入前校验

新增 `Test-ServiceDefinition` 集中校验：`command` 必填、`ports` 为 1-65535、
`ephemeral` 必须配 `shutdownCommand`、`dependsOn` 不能指向不存在的服务、不能自指。
错误全部收集后一次性返回，而不是抛第一个。

> 注：仓库原有两处重复的 ephemeral 校验（`Start-One`、`Stop-One`）本次**未动**，
> 它们仍在启动/停止路径上做运行时检查。写路径的校验是新增的一道前置闸门。

### PowerShell 数组展开陷阱（本次踩到三次）

单元素数组在若干场景会被 PowerShell 展开成标量，导致"写入的是标量、别处写的是数组"
这种不一致。三处均已修复并各带测试：

1. **函数返回值**：`return @($x)` 会展开 → 用 `return , @($x)`。否则
   `set web ports 8080` 写 `8080`，而 `add` 写 `[8080]`。
2. **if 表达式赋值**：`$v = if (...) { $arr } else { $null }` 会展开 → 改成分支内
   赋值。这使 `set` 的回显把 `[8080]` 打成 `8080`。
3. **`ConvertTo-Json` 管道**：`$arr | ConvertTo-Json` 会枚举 → 用
   `ConvertTo-Json -InputObject $arr`。否则单元素数组渲染成裸元素。

### 位置参数约束（实测）

PowerShell 的 `[string[]]` 位置参数**最多只绑定一个参数**。因此：

- `pp2 remove a b` 无法表达两个服务——`b` 会落进 `$Field` 被静默忽略。
  故 `remove` 采用逗号分隔（`pp2 remove a,b`），并在检测到 `-Field` 被绑定时
  明确报错而不是只删一半。
- 同理，各动作显式声明接受的参数，多余的第二个位置参数报错而非静默丢弃
  （`add web extra -Field ...` 中的 `extra` 会落进 `$Value`）。

## 顺带修复：watchdog 自动重启完全失效（回归）

调研中发现 `lib/pp2-watchdog.ps1:5` 声明了 `param([string]$Config)`，而该脚本作用域
同时持有 pp2-core 的 `$script:Config`（解析后的配置对象）——**二者是同一个变量，
且参数绑定优先于赋值**。因此 `$script:Config` 始终是路径字符串，
`$Config.services` 在 `Set-StrictMode -Version Latest` 下抛
`PropertyNotFoundException`。

受控实验确认（新脚本 + core 的两文件最小复现）：

```
declare param([string]$Config)  → $script:Config 类型 = String → Get-Thing() THROWS
不声明该参数                     → $script:Config 类型 = PSCustomObject → 正常
```

**故障形态之所以隐蔽**：抛错点在 `foreach ($n in $Config.services.PSObject...)` 的
**头部**，异常使循环体整体跳过，而循环本身继续空转。表现是：watchdog 进程存活、
PID 文件有效、日志只有 `watchdog started` 一行、**没有任何服务被检查过**。

修复前后对比（同一崩溃服务，`autoRestart=true`）：

| | 自动重启行为 |
| --- | --- |
| master（未修复） | 无 `crashed` 行、无重试计数 —— 循环空转 |
| 修复后 | `crashed → waiting 4s → retry 1/2 → restart succeeded → retry 2/2` |

该参数更名为 `-ConfigPath`（调用点 `pp2-core.ps1:1027` 同步）。

> 归因：`git log --follow` 显示该参数由 `2c09833`（"repair post-refactor
> regressions"）引入，属发布回归。

## 验证

| 用例 | 结果 |
| --- | --- |
| 全量测试（unit + integration） | **89 / 89 通过**（改动前 50；本次新增 39 = 36 单元 + 3 集成） |
| PSScriptAnalyzer | 6 条 warning，与 master 基线一字不差（0 Error） |
| `build.ps1 -Version 1.1.0 -Lint -Build` | 通过，staging 模块可正常加载并执行新命令 |
| 新增用例的实际防护力 | 三处 watchdog 测试在"把参数名改回 `$Config`"时**全部失败**；数组形状测试在移除逗号时失败。均已用"重新引入 bug"反向验证 |

覆盖到的行为：写入往返与 JSON 类型（`Int64`/`Boolean`/`Int64[]`）、嵌套 `env` 不被
截断、无 BOM/无尾换行、其他服务与 `settings` 不受影响、13 类校验拒绝、
`-Force` 覆盖与确认提示、`-Restart` 确实替换进程（不带则 PID 不变）、
`remove` 停止运行中的服务、逗号多选、以及各类多余参数被拒绝。

## 影响与遗留

- 版本：`1.1.0`（新功能，minor）。`CHANGELOG.md` 新增 `[1.1.0]` 段；
  `pp2.psd1` 的 `ModuleVersion` 原停留在 `1.0.0`（落后于已发布的 1.0.1），
  本次一并更新为 `1.1.0`，`ReleaseNotes` 同步。
- 合并时 master 已推进 3 个提交（monit 的 Ctrl+C 修复、1.0.2、导出列表漂移测试），
  已在 worktree 中变基合并；CHANGELOG 冲突取两边共存（1.0.2 在上，1.1.0 在下）。
  两套改动均完整保留。
- 已知未处理：`about_pp2.help.txt` 此前已漏 `list`/`config`/`watchdog-status` 等
  命令（本次补齐了新命令，但历史遗漏的仍以本次列出的为准）。
- 已知未处理：`README` 配置字段表列出的 `displayName` 在源码中从未被读取
  （`Show-Status` 用的是 `description`）。
- 环境副作用：排查 watchdog 时启动过若干临时 watchdog 进程，均已停止；
  测试用临时目录已清理。
