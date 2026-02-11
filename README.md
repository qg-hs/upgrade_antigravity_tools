# Antigravity Tools 一键安装/更新脚本

跨平台自动更新脚本，从 GitHub Releases 获取最新版本并完成安装。

---

## 📁 文件说明

| 文件          | 平台    | 运行环境              |
| ------------- | ------- | --------------------- |
| `mac.sh`      | macOS   | Terminal / zsh / bash |
| `linux.sh`    | Linux   | bash                  |
| `windows.ps1` | Windows | PowerShell 5.1+       |

---

## 🚀 使用方法

### 方式一：一键远程执行（推荐）

#### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/qg-hs/upgrade_antigravity_tools/refs/heads/main/mac.sh | bash
```

#### Linux

```bash
# 用户级安装（默认）
curl -fsSL https://raw.githubusercontent.com/qg-hs/upgrade_antigravity_tools/refs/heads/main/linux.sh | bash

# 系统级安装（需要 sudo）
curl -fsSL https://raw.githubusercontent.com/qg-hs/upgrade_antigravity_tools/refs/heads/main/linux.sh | sudo bash -s -- --system
```

#### Windows

以 **管理员身份** 打开 PowerShell：

```powershell
iex(iwr -UseBasicParsing https://raw.githubusercontent.com/qg-hs/upgrade_antigravity_tools/refs/heads/main/windows.ps1)
```

---

### 方式二：本地执行

#### macOS

```bash
chmod +x mac.sh
./mac.sh
```

> 安装过程中可能需要输入管理员密码（用于移除 Gatekeeper 隔离标志）。

#### Linux

```bash
chmod +x linux.sh

# 用户级安装（默认，安装到 ~/.local/share）
./linux.sh

# 系统级安装（安装到 /opt，需要 sudo）
./linux.sh --system
```

#### Windows

以 **管理员身份** 打开 PowerShell：

```powershell
# 若策略限制脚本执行，先临时放行
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

.\windows.ps1
```

---

## ⚙️ 功能特性

### 通用功能（三端一致）

- 🔎 自动获取 GitHub Releases 最新版本
- 📋 显示版本更新日志（Release Notes）
- ⚖️ 本地版本 vs 远程版本自动比较，已是最新则跳过
- ⬇️ 下载失败自动重试（最多 3 次）
- 🧹 异常退出自动清理临时文件
- 💾 磁盘空间预检查（默认 500MB 阈值）
- 🛡️ 安装前用户确认提示

### macOS 特性

| 项目         | 说明                                           |
| ------------ | ---------------------------------------------- |
| 架构检测     | Apple Silicon (arm64) / Intel (x86_64)         |
| 包格式优先级 | `.app.tar.gz` > `.dmg`                         |
| 版本读取     | `Info.plist` CFBundleShortVersionString        |
| 应用发现     | `/Applications` → `~/Applications` → Spotlight |
| 安全处理     | 自动移除 Gatekeeper 隔离标志 (`xattr -rd`)     |
| JSON 解析    | 原生 `plutil` 解析，grep/sed 回退              |

### Linux 特性

| 项目         | 说明                                            |
| ------------ | ----------------------------------------------- |
| 架构检测     | x86_64 / aarch64 / armv7                        |
| 发行版检测   | 自动识别 Debian / RedHat / Arch 系列            |
| 包格式优先级 | Debian 系: `.deb` > `.AppImage` > `.tar.gz`     |
|              | RedHat 系: `.rpm` > `.AppImage` > `.tar.gz`     |
|              | 其他: `.AppImage` > `.tar.gz` > `.deb` > `.rpm` |
| 安装模式     | `--user`（用户级）/ `--system`（系统级）        |
| 桌面集成     | 自动创建 `.desktop` 快捷方式                    |
| JSON 解析    | `jq` 优先，grep/sed 回退                        |

### Windows 特性

| 项目         | 说明                                       |
| ------------ | ------------------------------------------ |
| 架构检测     | x64 / x86 / ARM64（自动回退 x64）          |
| 包格式优先级 | `-setup.exe` (NSIS) > `.msi` > `.zip`      |
| 版本读取     | 注册表卸载信息 → 文件版本属性 → 多目录扫描 |
| 下载方式     | BITS 传输（支持断点续传）→ WebClient 回退  |
| TLS          | 强制 TLS 1.2                               |
| 进程管理     | 自动关闭运行中的应用后再安装               |

---

## 📦 支持的 Release 资源

以 v4.1.13 为例，脚本会根据平台与架构自动匹配：

### macOS

```
Antigravity.Tools_universal.app.tar.gz      ← arm64/x64 通用优先
Antigravity.Tools_4.1.13_universal.dmg
Antigravity.Tools_aarch64.app.tar.gz        ← Apple Silicon
Antigravity.Tools_4.1.13_aarch64.dmg
Antigravity.Tools_x64.app.tar.gz            ← Intel
Antigravity.Tools_4.1.13_x64.dmg
```

### Linux

```
Antigravity.Tools_4.1.13_amd64.deb          ← Debian/Ubuntu x64
Antigravity.Tools_4.1.13_arm64.deb          ← Debian/Ubuntu ARM
Antigravity.Tools-4.1.13-1.x86_64.rpm       ← Fedora/RHEL x64
Antigravity.Tools-4.1.13-1.aarch64.rpm      ← Fedora/RHEL ARM
Antigravity.Tools_4.1.13_amd64.AppImage     ← 通用 x64
Antigravity.Tools_4.1.13_aarch64.AppImage   ← 通用 ARM
```

### Windows

```
Antigravity.Tools_4.1.13_x64-setup.exe      ← NSIS 安装包
Antigravity.Tools_4.1.13_x64_en-US.msi      ← MSI 安装包
```

---

## 🔧 配置项

脚本顶部可修改以下常量：

| 常量                | 默认值                       | 说明                   |
| ------------------- | ---------------------------- | ---------------------- |
| `REPO`              | `lbjlaq/Antigravity-Manager` | GitHub 仓库地址        |
| `CURL_TIMEOUT`      | `30`                         | API 请求超时（秒）     |
| `MIN_FREE_SPACE_MB` | `500`                        | 最低磁盘空间要求（MB） |

---

## ❓ 常见问题

### macOS: `permission denied`

```bash
chmod +x mac.sh
```

### Linux: `jq: command not found`

脚本会自动回退到 grep/sed 解析，无需安装 jq。如需安装：

```bash
sudo apt install jq    # Debian/Ubuntu
sudo dnf install jq    # Fedora/RHEL
```

### Windows: `无法加载文件...因为在此系统上禁止运行脚本`

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 所有平台: `网络请求失败`

- 检查网络连接，确认能访问 `api.github.com`
- 若处于代理环境，设置 `https_proxy` 环境变量
