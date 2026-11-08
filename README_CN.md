# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

[English](README.md) | [中文](README_CN.md)

基于 PowerShell7，更适合 Windows 的服务管理器。一站式管理后台运行的命令行程序。

**pp2 = PowerShell × pm2**

> **当前状态**：v1.2.0 已发布到
> [PowerShell Gallery](https://www.powershellgallery.com/packages/pp2)。
> 直接用 `Install-Module pp2` 安装，需要 PowerShell 7+。

## 安装

### 前置要求

- **PowerShell 7+**: 必需 (`winget install Microsoft.PowerShell`)
- **Windows Terminal**: 可选
- **sudo for Windows**: 可选，用于 `elevated` 选项 (`winget install gerardog.gsudo`)

### PowerShell Gallery（推荐）

```pwsh
Install-Module -Name pp2 -Repository PSGallery -Scope CurrentUser
Import-Module pp2
```

验证安装结果：

```pwsh
Get-Module pp2 -ListAvailable | Select-Object Name, Version, Path
pp2 help
```

如果 `Install-Module` 以 "unable to install... not trusted" 拒绝安装，
先把 Gallery 标记为受信任（它默认不受信任）：

```pwsh
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
```

若要为所有用户安装，去掉 `-Scope CurrentUser` 并在管理员会话中执行。

### 不走 Gallery 安装

若不想从公开 Gallery 拉取，可在本地打包后从文件夹安装。`build.ps1` 支持发布到
任意已注册的仓库，而文件夹仓库无需任何凭据：

```pwsh
git clone https://github.com/john-walks-slow/pp2.git
cd pp2
.\build.ps1 -Build
Register-PSResourceRepository -Name pp2local -Uri D:\psrepo -Trusted
.\build.ps1 -Build -Publish -Repository pp2local
Install-PSResource -Name pp2 -Repository pp2local
```

后续升级使用 `Update-PSResource -Name pp2 -Repository pp2local`。

### 开发调试

若要在 pp2 上改代码，直接从源码树导入即可——无需安装步骤，改动在下次
`-Force` 导入时生效：

```pwsh
git clone https://github.com/john-walks-slow/pp2.git
cd pp2
Import-Module .\src\pp2\pp2.psd1 -Force
pp2 help
```

修改模块文件后重新执行这行 `Import-Module`。该方式仅在当前会话有效；若要把
工作副本持久安装，请使用上面的文件夹仓库方式。

## 快速开始

```pwsh
# 显示服务状态
pp2 status

# 启动所有服务
pp2 start all

# 停止服务
pp2 stop my-service

# 查看运行日志
pp2 logs my-service

# 多窗格日志监控仪表盘
pp2 monit

# 开机自启
pp2 startup-install
```

## 配置示例

在 pp2 配置目录的 `services.json` 中定义服务。

| 路径                       | 解析方式                                       |
| -------------------------- | ---------------------------------------------- |
| `$PP2_HOME` 环境变量       | 直接使用                                       |
| 默认（无环境变量）         | Windows / Linux / macOS 上均为 `$HOME/.pp2`    |

每次 `pp2` 调用都会重新读取 `PP2_HOME`，因此切换环境变量无需重新导入模块。
`-Config <path>` 可在单次命令中临时使用其它 `services.json`。

```json
{
  "services": {
    "http-server": {
      "displayName": "Simple Http Server",
      "description": "a simple http server",
      "workingDirectory": "D:/path/to/website",
      "command": "npx",
      "arguments": ["-y", "http-server"],
      "shell": true,
      "env": {
        "PORT": 1234
      },
      "ports": [1234],
      "autoRestart": true,
      "maxRetries": 3
    }
  }
}
```

### 配置字段说明

| 字段                | 类型    | 必需        | 说明                                            |
| ------------------- | ------- | ----------- | ----------------------------------------------- |
| `displayName`       | string  | no          | 显示名称                                        |
| `description`       | string  | no          | 服务描述                                        |
| `workingDirectory`  | string  | no          | 进程工作目录                                    |
| `command`           | string  | **yes**     | 可执行文件路径或命令                            |
| `arguments`         | array   | no          | 命令参数                                        |
| `shell`             | boolean | no          | ⚠ **运行模式 - 关键，见下文**（默认：false）      |
| `ports`             | array   | no          | 服务端口（用于端口健康检查，空数组禁用）        |
| `ephemeral`         | boolean | no          | 启动器模式 - 进程启动后立即退出（默认：false）  |
| `autoRestart`       | boolean | no          | 崩溃时自动重启（默认：false，ephemeral 时忽略） |
| `maxRetries`        | number  | no          | 最大重启尝试次数（默认：3）                     |
| `dependsOn`         | array   | no          | 依赖的服务（影响启动顺序）                      |
| `elevated`          | boolean | no          | 是否通过 sudo 提升权限                          |
| `env`               | object  | no          | 要注入的环境变量                                |
| `inheritEnv`        | boolean | no          | 是否继承系统环境变量（默认：true）              |
| `shutdownCommand`   | string  | conditional | 自定义关闭命令（**ephemeral 时必需**）          |
| `shutdownArguments` | array   | no          | shutdownCommand 的参数                          |
| `legacyProcessName` | string  | no          | 清理遗留进程时需额外清理的进程名                |

### Shell 模式 vs 直接执行

`shell` 选项控制命令的执行方式：

| 模式           | `shell` | 执行方法              | 适用场景                              |
| -------------- | ------- | --------------------- | ------------------------------------- |
| **直接执行**   | `false` | `& $command @arguments` | 原生可执行文件；精确参数传递          |
| **Shell 执行** | `true`  | `pwsh -Command $fullLine` | CLI 工具；需要 shell 特性            |

**直接模式 (`shell: false`)** - 默认：

- 每个参数作为独立 token 传递，参数边界精确
- shell 功能无效（无管道、重定向、通配符）；裸命令名仍会经 PATH 解析
- 建议用于直接可执行文件

**Shell 模式 (`shell: true`)**：

- 命令与参数拼成单行字符串，通过 `pwsh -NoProfile -NonInteractive -Command` 执行
- 适合 CLI 工具与包运行器（`npx`、`uvx`、`pipx`、`dotnet tool`）
- 命令执行前会写入 `<service>.out.log`，便于审计实际调用

### Ephemeral 服务（启动器模式）

某些服务是**启动器脚本**，启动其他进程后立即退出。例如：

- 启动后台守护进程的包装脚本（`nohup my-daemon &`）
- 启动服务后退出的 CLI 工具
- 生成子进程的进程管理脚本

对于这种情况，使用 `ephemeral: true`：

```json
{
  "services": {
    "my-launcher": {
      "displayName": "我的启动器",
      "command": "pwsh",
      "arguments": ["-File", "launch-background.ps1"],
      "ephemeral": true,
      "shutdownCommand": "pwsh",
      "shutdownArguments": ["-File", "stop-background.ps1"]
    }
  }
}
```

**说明：**

- `shutdownCommand` 对 ephemeral 服务是**必需的**
- `autoRestart` 不适用于ephemeral 服务
- PID 文件包含 `'ephemeral'` 标记而非真实 PID


### 全局设置

在 `services.json` 的 `settings` 中配置：

```json
{
  "settings": {
    "watchdogInterval": 60,
    "portCheckTimeout": 200,
    "startupVerifyWait": 2500,
    "shutdownTimeout": 5000
  }
}
```

| 字段                | 类型   | 默认值 | 说明                                                       |
| ------------------- | ------ | ------ | ---------------------------------------------------------- |
| `watchdogInterval`  | number | 60     | Watchdog 检查间隔（秒）                                    |
| `portCheckTimeout`  | number | 200    | 端口检查超时（毫秒）                                       |
| `startupVerifyWait` | number | 20000  | 启动检测最长等待时间（毫秒），超时判定为已启动             |
| `startupSettleWait` | number | 3000   | 启动脚本写完横幅后，再等多久确认进程未立即退出（毫秒）     |
| `shutdownTimeout`   | number | 5000   | 关闭进程退出超时（毫秒）                                   |
| `shutdownWaitDelay` | number | 2000   | 执行 shutdownCommand 后再等待（毫秒）                      |
| `healthCheckGrace`  | number | 30     | 判定服务稳定、清空重启计数前需连续存活的秒数               |
| `restartTimeout`    | number | 120    | Watchdog 等待自身重启子进程的最大秒数                      |

## 命令参考

### 核心操作

```pwsh
pp2 status [name]              # 显示状态表格（-Format json 输出 JSON）
pp2 status -Watch              # 实时状态仪表盘（-Interval 5）
pp2 start [name]               # 启动服务（autoRestart 为 true 则同时启动 watchdog）
pp2 stop [name]                # 停止服务
pp2 restart [name]             # 重启服务
pp2 logs <name> [-Tail 80]     # 实时日志监控（默认，Ctrl+C 退出）
pp2 logs <name> -Watch:\$false  # 静态日志查看
```

### 工具命令

```pwsh
pp2 monit [name] [-Cols 3]     # 多窗格日志仪表盘（Ctrl+C 退出）
pp2 list                       # 列出服务名称
```

### 编辑服务

```pwsh
pp2 show <name>                # 查看单个服务定义（-Format json）
pp2 add <name> -Field @{...}   # 新增服务（同名加 -Force 覆盖）
pp2 set <name> <field> <value> # 修改单个字段
pp2 remove <name>[,<name>]     # 从配置中移除服务
```

```pwsh
pp2 add web -Field @{command='npx'; arguments=@('-y','http-server'); ports=@(8080)}
pp2 set web autoRestart true
pp2 set web ports 9000,9001
pp2 remove web
pp2 remove web,old-api -Purge
```

`remove` 接受逗号分隔的多个服务名；其余命令只作用于单个服务。多余的第二个
位置参数会被拒绝，而不是被静默忽略。

这些命令只改写 `services.json`，不会影响已经在运行的进程——它仍使用启动时的
参数。加 `-Restart` 可顺带重启受影响的服务；目标正在运行时默认会先确认，加
`-Force` 跳过。`-Purge` 会连带删除该服务的状态文件与日志。

值按字段应有的类型写入：`pp2 set web maxRetries 5` 写入数字，
`pp2 set web shell true` 写入布尔值。数组字段支持逗号分隔或 JSON 数组；
`env` 这类对象字段使用 JSON：

```pwsh
pp2 set web env '{"PORT":"3000"}'
```

写入前会校验服务定义：缺少 `command`、`ports` 含非数字、`ephemeral` 未配
`shutdownCommand`、`dependsOn` 指向不存在的服务，都会当场报错，而不是存下来
留给 `pp2 start` 之后才发现。

### Watchdog 控制

```pwsh
pp2 watchdog-start             # 启动自动重启监控
pp2 watchdog-stop              # 停止自动重启监控
pp2 watchdog-status            # 检查 watchdog 状态
```

### 启动集成

注册一个登录时运行的任务计划任务。之后的 `pp2 start` 不受影响：任务只负责启动服务，
不会让 pp2 常驻。

```pwsh
pp2 startup-install              # 登录时启动全部服务
pp2 startup-install dsh          # 只启动 dsh（任务名 "pp2 Startup (dsh)"）
pp2 startup-install dsh,cpa      # 启动指定的一组服务
pp2 startup-uninstall dsh        # 删除该任务
pp2 startup-uninstall            # 删除所有 "pp2 Startup*" 任务
```

说明：

- 任务以当前用户的普通权限运行，无需管理员终端即可注册。定义里写了
  `elevated: true` 的服务，由 pp2 在启动时自行提权。
- 任务按模块名导入 pp2，因此后续 `Update-PSResource` 升级后仍然生效。
  若当前是从源码树导入 pp2，则拒绝注册——请先安装 pp2，让任务加载同一份副本。
- 任务在电池供电时不会停止。
- 指定服务子集时不会连带启动其 `dependsOn` 依赖。依赖未运行时该服务会拒绝启动，
  需要一起启动就把依赖也列进去（如 `dsh,db`）。
- 任务拉起的 watchdog 只监视这个子集，因此上次会话残留的 PID 文件不会把未指定的
  服务复活。
- 端口已被其它进程占用时，服务会被跳过：登录时没有控制台可以回答"是否结束该进程"。
  需要接管时，手工执行 `pp2 start <name> -Force`。

### 参数选项

```pwsh
-Format json|table             # status 输出格式
-Interval 5                    # watch 刷新间隔（秒）
-Tail 80                       # 显示日志行数
-Cols 3                        # monit 仪表盘最大列数
-Force                         # 跳过确认提示
-Restart                       # 顺带重启本次编辑涉及的服务
-Purge                         # （remove）连带删除状态文件与日志
-Config <path>                 # 使用指定的 services.json 文件
```

## Agent Skill

[`skills/pp2/SKILL.md`](skills/pp2/SKILL.md) 教编码 agent 何时以及如何调用 pp2：
哪些命令可以无人值守运行、如何读状态与日志、`services.json` 中真正重要的字段，
以及"改了配置不生效""自动重启没反应"这类高频坑。

Claude Code 只自动发现 `.claude/skills/<name>/` 下的 skill，所以仓库里这份是分发副本，
需要安装一次。装到个人 skills 目录后所有项目都能用：

```pwsh
# Windows：目录联接，仓库内修改立即生效
New-Item -ItemType Junction -Path "$HOME\.claude\skills\pp2" `
  -Target (Resolve-Path .\skills\pp2)
```

只在某个项目里用时，也可以把项目级 skill 目录指过去：

```pwsh
New-Item -ItemType Junction -Path .\.claude\skills -Target (Resolve-Path .\skills)
```

其他平台用符号链接（`ln -s`）。该 skill 就是一份标准 `SKILL.md`，同样适用于
其他支持此格式的 agent 宿主。

## 日志管理

日志存储在配置目录下的 `logs/` 子目录：

- `logs/<service>.out.log` - 标准输出
- `logs/<service>.err.log` - 标准错误

PID 跟踪在配置目录下的 `run/` 子目录：

- `run/<service>.pid` - 进程 ID
- `run/<service>.elevated` - 提权服务标记
- `run/watchdog.pid` - Watchdog 进程 ID

## 依赖处理

带 `dependsOn` 的服务按正确顺序启动。停止操作使用反向依赖顺序：

```json
{
  "database": { ... },
  "api": {
    "dependsOn": ["database"]
  },
  "web": {
    "dependsOn": ["api"]
  }
}
```

- **启动顺序**：database → api → web
- **停止顺序**：web → api → database

## 故障排查

**服务无法启动：**

- 检查 `logs/<service>.err.log`
- 验证端口是否被占用：`netstat -ano | findstr :<port>`

**服务无法自动重启：**

- 运行 `pp2 watchdog-status` 检查状态
- 手动启动：`pp2 watchdog-start`

## 发布

版本历史：[CHANGELOG.md](CHANGELOG.md)。已发布版本：

| 版本  | 渠道                                                          |
| ----- | ------------------------------------------------------------- |
| 1.2.0 | [PSGallery](https://www.powershellgallery.com/packages/pp2)    |
| 1.1.0 | [PSGallery](https://www.powershellgallery.com/packages/pp2)    |
| 1.0.2 | [PSGallery](https://www.powershellgallery.com/packages/pp2)    |
| 1.0.1 | [PSGallery](https://www.powershellgallery.com/packages/pp2)    |
| 1.0.0 | [PSGallery](https://www.powershellgallery.com/packages/pp2)    |

GitHub 标签发布在
[github.com/john-walks-slow/pp2/releases](https://github.com/john-walks-slow/pp2/releases)。
推送 `v*` 标签会触发
[`.github/workflows/publish.yml`](.github/workflows/publish.yml)，
依次执行 lint、测试，并把构建产物发布到 Gallery。