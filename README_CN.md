# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

[English](README.md) | [中文](README_CN.md)

基于 PowerShell7，更适合 Windows 的服务管理器。一站式管理后台运行的命令行程序。

**pp2 = PowerShell × pm2**

## 安装

### 前置要求

- **PowerShell 7+**: 必需 (`winget install Microsoft.PowerShell`)
- **Windows Terminal**: 可选，用于 `monit` 命令 (`winget install Microsoft.WindowsTerminal`)
- **sudo for Windows**: 可选，用于 `elevated` 选项 (`winget install gerardog.gsudo`)

### 本地安装

```pwsh
git clone https://github.com/john-walks-slow/pp2.git
cd pp2
.\install.ps1
```

安装后，`pp2` 命令自动可用。

重新安装：`.\install.ps1 -Force`

卸载：`.\install.ps1 -Uninstall`

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

# 多窗格日志监控（需要 Windows Terminal）
pp2 monit

# 开机自启
pp2 startup-install
```

## 配置示例

在 pp2 配置目录的 `services.json` 中定义服务。（默认位置：`$HOME/.pp2`，可用 `PP2_HOME` 覆盖）

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

| 模式           | `shell` | 执行方法            | 适用场景                              |
| -------------- | ------- | ------------------- | ------------------------------------- |
| **直接执行**   | `false` | `& $command $args`  | 原生可执行文件；精确参数传递          |
| **Shell 执行** | `true`  | `Invoke-Expression` | CLI 工具；需要 shell 特性 |

**直接模式 (`shell: false`)** - 默认：

- 每个参数作为独立 token 传递，参数边界精确
- shell 功能无效（无管道、重定向、通配符、PATH）
- 建议用于直接可执行文件

**Shell 模式 (`shell: true`)**：

- 命令拼接成字符串后，通过 pwsh 执行
- 参数会被适当引号包裹和转义
- 建议用于 CLI 工具和 `npx`、`uvx`、`pipx` 等包运行器

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
-Config <path>                 # 使用指定的 services.json 文件
```

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