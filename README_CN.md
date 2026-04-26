# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

[English](README.md) | [中文](README_CN.md)

基于 PowerShell7，更适合 Windows 的服务管理器。一站式管理后台运行的命令行程序。

## 安装

### PowerShell Gallery（推荐）

从 PowerShell Gallery 安装：

```pwsh
Install-Module pp2 -Scope CurrentUser
```

安装后，`pp2` 命令自动在 PowerShell 中可用。

更新：

```pwsh
Update-Module pp2
```

卸载：

```pwsh
Uninstall-Module pp2
```

### 一行命令安装（备选）

在 PowerShell 7 中运行：

```pwsh
irm https://raw.githubusercontent.com/john-walks-slow/pp2/main/install.ps1 | iex
```

### 安装脚本功能

- ✅ 从 GitHub 下载 pp2
- ✅ 检查前置要求（PowerShell 7+ 必需）
- ✅ 可选通过 winget 安装缺失组件
- ✅ 将 `pp2` 别名添加到 PowerShell profile
- ✅ 添加 `pp2-uninstall` 函数用于清理

### 手动安装

如果你喜欢手动配置：

```pwsh
git clone https://github.com/john-walks-slow/pp2.git D:\pp2
Add-Content $PROFILE "Set-Alias pp2 'D:\pp2\pp2.ps1'"
```

### 卸载

```pwsh
pp2-uninstall
```

### WinGet（未来）

WinGet 包即将推出。目前请使用上面的一行安装脚本。

## 功能特性

- **没有 Bullshit**：只要能通过命令行启动，就能通过 pp2 管理，没有奇怪的适配问题。支持环境变量注入和启动目录配置
- **自动重启**：Watchdog 监控，服务崩溃时自动重启
- **日志查看**：集中管理运行日志，支持 Windows Terminal 分栏监控
- **端口检查**：检查端口健康，处理端口占用
- **Windows 启动集成**：设置服务随用户登录自动启动
- **权限提升**：支持 Sudo for Windows 为服务提权

## 快速开始

```pwsh
# 显示服务状态
pp2 status

# 启动所有服务
pp2 start all

# 停止所有服务
pp2 stop all

# 多窗格日志监控（需要 Windows Terminal）
pp2 monit

# 开机自启
pp2 startup-install
```

## 配置说明

在同目录创建 `services.json`：

```json
{
  "services": {
    "my-service": {
      "displayName": "我的服务",
      "description": "状态显示的描述",
      "workingDirectory": "C:/path/to/workdir",
      "command": "C:/path/to/executable.exe",
      "arguments": ["--port", "8080"],
      "ports": [8080],
      "autoRestart": true,
      "maxRetries": 3,
      "dependsOn": ["another-service"],
      "elevated": false,
      "env": {
        "ENV_VAR": "value"
      },
      "shell": true,
      "shutdownCommand": "C:/path/to/shutdown.exe",
      "shutdownArguments": ["--stop"]
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
| `shell`             | boolean | no          | ⚠️ **运行模式 - 关键设置**（默认：false）         |
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

⚠️ **`shell` 选项是关键设置 - 设置错误可能导致服务无法启动！**

`shell` 选项控制命令的执行方式：

| 模式           | `shell` | 执行方法            | 适用场景                              |
| -------------- | ------- | ------------------- | ------------------------------------- |
| **直接执行**   | `false` | `& $command $args`  | 原生可执行文件，精确参数传递          |
| **Shell 执行** | `true`  | `Invoke-Expression` | CLI 工具（npx, uvx），需要 shell 特性 |

**直接模式 (`shell: false`)** - 默认：

- 参数作为独立 token 传递，边界保持精确
- 无 shell 解释（无管道、重定向、通配符）
- 示例：`["--port", "8080"]` → 两个精确参数

**Shell 模式 (`shell: true`)**：

- 命令作为字符串通过 PowerShell shell 执行
- 启用 shell 特性：PATH 解析、管道、重定向
- 参数会被适当引号包裹/转义
- 示例：`npx my-package` → 通过 PATH 解析，在 shell 中执行

**何时使用 `shell: true`:**

- `npx`、`uvx`、`pipx` 等包运行器（需要 PATH 解析）
- 需要 shell 特性的命令（`node script.js | tee log.txt`）
- 包含需要 shell 解释的特殊字符的命令

**何时使用 `shell: false`:**

- 直接可执行文件路径（`C:/path/to/service.exe`）
- 需要精确参数边界
- 参数包含空格（避免 shell 引号问题）

### Ephemeral 服务（启动器模式）

某些服务是**启动器脚本**，启动其他进程后立即退出。例如：

- 启动后台守护进程的包装脚本（`nohup my-daemon &`）
- 启动服务后退出的 CLI 工具（如某些模式下的 `cloudflared tunnel run`）
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

**行为说明：**

- PID 文件包含 `'ephemeral'` 标记而非真实 PID
- Watchdog **跳过进程监控**（无自动重启）
- `pp2 stop` 调用 `shutdownCommand` 清理生成的进程
- 状态显示 `Running (ephemeral)`，PID = `-`

**要求：**

- `shutdownCommand` 对 ephemeral 服务是**必需的**
- `autoRestart` 自动禁用（无法监控 ephemeral 进程）

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

| 字段                | 类型   | 默认值 | 说明                     |
| ------------------- | ------ | ------ | ------------------------ |
| `watchdogInterval`  | number | 60     | Watchdog 检查间隔（秒）  |
| `portCheckTimeout`  | number | 200    | 端口检查超时（毫秒）     |
| `startupVerifyWait` | number | 2500   | 启动验证等待时间（毫秒） |
| `shutdownTimeout`   | number | 5000   | 关闭进程退出超时（毫秒） |

## 命令参考

### 核心操作

```pwsh
pp2 status [name]              # 显示状态表格（-Format json 输出 JSON）
pp2 status -Watch              # 实时状态仪表盘（-Interval 5）
pp2 start [name]               # 启动服务（autoRestart 为 true 则同时启动 watchdog）
pp2 stop [name]                # 停止服务
pp2 restart [name]             # 重启服务
pp2 logs <name> [-Tail 80]     # 查看日志
pp2 logs <name> -Watch         # 实时日志监控
```

### 工具命令

```pwsh
pp2 monit [name] [-Cols 3]     # Windows Terminal 多窗格日志
pp2 list                       # 列出服务名称
```

### Watchdog 控制

```pwsh
pp2 watchdog-start             # 启动自动重启监控
pp2 watchdog-stop              # 停止自动重启监控
pp2 watchdog-status            # 检查 watchdog 状态
```

### 启动集成

```pwsh
pp2 startup-install            # 添加到 Windows 启动（任务计划程序）
pp2 startup-uninstall          # 从 Windows 启动移除
```

### 参数选项

```pwsh
-Format json|table             # status 输出格式
-Interval 5                    # watch 刷新间隔（秒）
-Tail 80                       # 显示日志行数
-Cols 3                        # monit 最大列数
-Force                         # 跳过确认提示
```

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

## 日志管理

日志存储在 `logs/` 目录：

- `logs/<service>.out.log` - 标准输出
- `logs/<service>.err.log` - 标准错误

PID 跟踪在 `run/` 目录：

- `run/<service>.pid` - 进程 ID
- `run/<service>.elevated` - 提权服务标记
- `run/watchdog.pid` - Watchdog 进程 ID

## 配置示例

### Node.js 服务（npx）

```json
{
  "my-app": {
    "command": "npx",
    "arguments": ["my-package", "--port", "3000"],
    "ports": [3000],
    "shell": true,
    "autoRestart": true
  }
}
```

### 提权服务

```json
{
  "privileged-service": {
    "command": "C:/path/to/service.exe",
    "elevated": true,
    "autoRestart": true
  }
}
```

### 自定义关闭命令

```json
{
  "graceful-service": {
    "command": "C:/path/to/server.exe",
    "shutdownCommand": "C:/path/to/server.exe",
    "shutdownArguments": ["--shutdown"]
  }
}
```

## 故障排查

**服务无法启动：**

- 检查 `logs/<service>.err.log`
- 验证端口是否被占用：`netstat -ano | findstr :<port>`

**服务无法自动重启：**

- 运行 `pp2 watchdog-status` 检查状态
- 手动启动：`pp2 watchdog-start`

**提权服务失败：**

- 确认已安装 sudo
