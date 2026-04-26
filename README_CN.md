# pp<super>2</super> - PowerShell Process Manager

> Inspired by [pm2](https://pm2.keymetrics.io/) — the Node.js process manager.

使用 PowerShell7 编写，更适合 Windows 的服务管理器。一站式管理后台运行的命令行程序。

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

| 字段                | 类型    | 必需    | 说明                                     |
| ------------------- | ------- | ------- | ---------------------------------------- |
| `displayName`       | string  | no      | 显示名称                                 |
| `description`       | string  | no      | 服务描述                                 |
| `workingDirectory`  | string  | no      | 进程工作目录                             |
| `command`           | string  | **yes** | 可执行文件路径或命令                     |
| `arguments`         | array   | no      | 命令参数                                 |
| `ports`             | array   | no      | 服务端口（用于端口健康检查，空数组禁用） |
| `autoRestart`       | boolean | no      | 崩溃时自动重启（默认：false）            |
| `maxRetries`        | number  | no      | 最大重启尝试次数（默认：3）              |
| `dependsOn`         | array   | no      | 依赖的服务（影响启动顺序）               |
| `elevated`          | boolean | no      | 是否通过 sudo 提升权限                   |
| `env`               | object  | no      | 要注入的环境变量                         |
| `inheritEnv`        | boolean | no      | 是否继承系统环境变量（默认：true）       |
| `shell`             | boolean | no      | 是否通过 pwsh 运行（默认：true）         |
| `shutdownCommand`   | string  | no      | 自定义关闭命令（省略则强制停止进程）     |
| `shutdownArguments` | array   | no      | shutdownCommand 的参数                   |
| `legacyProcessName` | string  | no      | 清理遗留进程时需额外清理的进程名         |

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
