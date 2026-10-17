# 简化安装路径：移除自建安装器，改用本地 PSResource 仓库

日期：2026-10-17
范围：`install.ps1`、`pp2.ps1`、`build.ps1`、`README.md`、`README_CN.md`

## 背景

v1.0.0 已发布到 PSGallery，主安装路径 `Install-Module pp2` 成立。但仓库里同时存在
两条自建的副路径：`install.ps1`（复制到 PSModulePath）和 `pp2.ps1`（源码树转发脚本）。
用户诉求是"副路径希望最简单而不增加维护成本"。

## 问题诊断

### 1. install.ps1 制造扁平布局，与 Gallery 安装互斥（阻塞）

`install.ps1` 把模块复制到 `Modules/pp2/`（manifest 直接位于模块根），而
`Install-Module`/`Install-PSResource` 使用版本化布局 `Modules/pp2/1.0.0/`。

受控实验（`PSModulePath` 指向同一 module root）：

```
扁平 1.0.0 + 版本化 9.9.9   → 只发现 9.9.9，扁平那份完全不可见
仅扁平 1.0.0                → 发现 1.0.0
```

即：同一 module root 下**版本化子目录优先于扁平 manifest，与版本号高低无关**。
用户机器上实测正是该状态：

```
D:\Data\PowerShell\Modules\pp2\        ← install.ps1 装的扁平副本（已过期）
D:\Data\PowerShell\Modules\pp2\1.0.0\  ← Gallery 装的（实际生效）
```

`Get-Module -ListAvailable pp2` 只返回后者，扁平副本是死重量。

两个后果（沙箱实测）：

- 不加 `-Force`：`$Existing` 命中 Gallery 副本 → 打印"已安装"后返回，扁平副本永远追不上。
- 加 `-Force`：`Remove-Item $Existing.ModuleBase` 删掉 **Gallery 管理的那份**，
  换成扁平副本。`PSGetModuleInfo.xml` 一并消失，此后 `Update-PSResource` 报"未安装"。
  它静默卸载了 Gallery 安装。

### 2. Get-UserModulePath 兜底路径错误

```powershell
$DocsPath = Join-Path $HOME 'Documents\PowerShell\Modules'
```

微软文档明确不能假设 `Documents` 位于 `$HOME` 下（OneDrive / 组策略重定向），
须用 `[Environment]::GetFolderPath('MyDocuments')`。本机 `MyDocuments` = `D:\Data`，
走兜底会写到 `C:\Users\John\Documents\...`（不在 PSModulePath 上）。
另外 `-match 'Program Files|Windows|system32'` 为模糊正则，"取第一个可写目录"
会把 pp2 塞进第三方 prepend 的目录。

### 3. 重复的 staging 逻辑

`install.ps1` 与 `build.ps1` 逐字重复同一份 `$ExcludeFiles` 列表与拷贝循环，
且 `install.ps1` 不更新 manifest 版本号，两份必然漂移。

### 4. pp2.ps1 的缺陷

- 首行 `# <#` 把 `<#` 注释掉了，`.SYNOPSIS` 块不生效，`Get-Help .\pp2.ps1` 返回空。
- catch 分支不可达：`Read-Pp2Config` 在配置缺失时会自动创建 `services.json`，
  "Please create services.json" 永不打印。
- 功能上与 `Import-Module .\src\...` 完全等价（实测导出同样 12 个函数），
  但每次调用起新子进程，且无 tab 补全/Get-Help 等真实模块语义。

### 5. 零测试覆盖

`grep install.ps1 tests/` 无命中，而该脚本会 `Remove-Item -Recurse -Force`。

## 决策

**删除 `install.ps1` 与 `pp2.ps1`，把"不走 Gallery 的持久安装"交给 PSResourceGet
的本地仓库机制。**

取舍依据：两者都只值"省一行手打"，却各带一份需要维护的代码和一个真实缺陷
（扁平布局冲突 / 静默卸载 Gallery 副本）。而官方 canonical 的本地仓库路径能同时
满足"持久安装"与"不走 Gallery"两个诉求，且 `build.ps1 -Build` 产出的
`output/pp2/` 已可直接发布。

### build.ps1 的唯一阻塞点

```powershell
if (-not $NuGetApiKey) { throw "NuGetApiKey is required for publishing." }
```

本地文件夹仓库无需凭据，此守卫使 `-Publish` 无法用于本地仓库。

## 实施

### build.ps1 Step-Publish

- 校验目标仓库已注册，未注册给出明确提示。
- 以 `$Target.Uri.IsFile` 判定本地仓库（实测：本地为 `file:///` scheme `file`，
  远端为 `https`）。
- 本地仓库放行无 ApiKey；远端仓库仍要求 ApiKey。
- 去重守卫（`Find-PSResource` 已发布则跳过）**仅对远端生效**：
  实测本地仓库重复发布同一版本会静默覆盖（不报错），保留守卫会错误地阻止本地重发。
- ApiKey 仅在有值时传入，避免向本地仓库传空值。

### 删除

- `install.ps1`（99 行）、`pp2.ps1`（32 行）。确认二者未被任何 CI、测试或代码引用，
  仅在 README 中各出现一次。

### README（EN/CN）

- "From source / 从源码安装" 小节重写为两节：
  - **Without the Gallery / 不走 Gallery 安装**：folder repository 完整流程。
  - **Development / 开发调试**：`Import-Module .\src\pp2\pp2.psd1 -Force`，
    并说明其会话级特性。

## 验证

| 用例 | 结果 |
| --- | --- |
| 本地仓库发布，无 ApiKey | 通过，生成 `pp2.9.9.1.nupkg` |
| 本地仓库重复发布同一版本 | 通过，未被跳过（正确覆盖） |
| 从本地仓库 Save/Install | 通过，布局为版本化 `\pp2\9.9.1\`，12 个函数，无开发文件 |
| 远端仓库无 ApiKey | 正确拒绝，提示需 ApiKey |
| 未注册仓库名 | 正确拒绝，提示注册方式 |
| `build.ps1 -Lint` | 通过（既有 warning 属他人并发改动） |

清理：所有测试仓库注册已注销，`Get-PSResourceRepository` 仅剩 `PSGallery`。

## 影响与遗留

- `src/pp2/*` 的三个文件在本工作期间由其他 agent 并发修改，本次未触碰。
- 后续若需要"给不想用 Gallery 的用户一条最简单的命令"，可在本地仓库基础上
  再考虑包装，但当前三步（Register → Publish → Install）已是 canonical 做法，
  不建议再引入自定义脚本。
