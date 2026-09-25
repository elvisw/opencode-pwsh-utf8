# OpenCode V2 UTF-8 Shell 修复包

[![Release](https://img.shields.io/github/v/release/elvisw/opencode-pwsh-utf8)](https://github.com/elvisw/opencode-pwsh-utf8/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

让 **OpenCode V2**（Windows）的命令行与 Python 脚本能够**正常输出中文、emoji 及其他 Unicode 字符**的一键部署方案。

> **下载使用**：普通用户直接从 [Releases](https://github.com/elvisw/opencode-pwsh-utf8/releases) 下载 `opencode-pwsh-utf8-*-win-x64.zip`（内含预编译 exe + 部署脚本），解压后看下方“快速部署”。
> 开发者 `git clone` 本仓库后需先自行编译（见“重新编译”），因为预编译二进制只随 Release 发布，不进 git。

## 背景：为什么会乱码

中文版 Windows 的系统 ANSI 代码页（ACP）是 **GBK（936）**。当 OpenCode 的 shell 工具通过管道捕获命令输出时：

| 组件 | 现象 | 原因 |
|------|------|------|
| PowerShell (pwsh) | 中文变乱码 `���Ĳ���`，emoji 变 `?` | 输出重定向后 `[Console]::OutputEncoding` 回退为 GBK |
| Python | `UnicodeEncodeError: 'gbk' codec can't encode '\U0001f600'` | Python 的 stdout 默认使用系统代码页 GBK |

而 OpenCode 无法直接配置"给 shell 加启动参数"——`shell` 配置项只能填一个**可执行文件路径**，且调用方式固定为 `shell -c "<命令>"`。PowerShell 的 profile 也不会被 shell 工具加载（相当于 `-NoProfile`）。因此需要一个"入口程序"来注入 UTF-8 设置。

## 方案架构

```
OpenCode shell 工具
   └─ spawn:  <config-dir>\pwsh-utf8.exe -c "<命令>"     ← 配置项 shell 指向这个 exe
                │
                ├─ 1. 合并注册表 HKLM+HKCU\Environment 到子进程环境（Path 按机器+用户重建）
                │      （setx 设置的用户环境变量立即生效，无需重启 OpenCode 服务；顺带修复 PATH 缺机器部分）
                ├─ 2. 组装前导 + 原命令，经 base64(-EncodedCommand) 传给 pwsh
                │      前导: [Console]::OutputEncoding/InputEncoding = UTF8
                │            $OutputEncoding = UTF8
                ├─ 3. 子进程挂 Job Object（KILL_ON_JOB_CLOSE）
                │      （wrapper 被超时杀掉时，pwsh 子进程同步退出，不残留孤儿进程）
                └─ 交互模式（无 -c 参数，如 TUI 终端）：直接转发给 pwsh
                       （正常加载用户 profile，行为与原生一致）
```

配套的两层配置：

- **Python**：用户级环境变量 `PYTHONUTF8=1` + `PYTHONIOENCODING=utf-8`（对所有 Python 进程生效）。
- **用户自己的 PowerShell 终端**（可选）：在 `$PROFILE` 中设置 UTF-8 控制台编码（OpenCode 不加载它，但用户自己开的终端会加载）。

### 为什么用编译型 exe 而不是脚本

- `.ps1` 脚本**不能**作为进程直接启动（Windows 只能直接启动 PE 可执行文件）；
- `.cmd`/`.bat` 可以被 CreateProcess 自动交给 cmd.exe 执行，但实测 cmd.exe 会**截断多行命令**、破坏含花括号/引号/括号的复杂命令——不可接受；
- 因此用 .NET NativeAOT 编译成原生 exe：接收 argv 无任何改写，启动快（毫秒级）、零运行时依赖；
- 命令传递用 `-EncodedCommand`（base64 UTF-16LE）而非拼接命令行，彻底规避 Windows 命令行引号/换行转义问题。

## 目录结构

```
opencode-pwsh-utf8/
├── README.md           本文档
├── LICENSE             MIT 许可证
├── deploy.ps1          一键部署脚本
├── uninstall.ps1       回滚脚本
├── build.ps1           重新编译脚本（需要 .NET 10+ SDK）
├── bin/
│   └── pwsh-utf8.exe   预编译的 wrapper（win-x64，自包含，无需 .NET 运行时；仅随 Release 发布，git 不跟踪）
└── src/
    ├── Program.cs      wrapper 源码
    └── pwsh-utf8.csproj 项目文件（net10.0 + NativeAOT）
```

## 快速部署（3 步）

在**目标机器**上打开 PowerShell：

```powershell
# 1. 解压 Release 压缩包（假设解压到 D:\opencode-pwsh-utf8）
# 2. 执行部署脚本（右键"使用 PowerShell 运行"亦可）
cd D:\opencode-pwsh-utf8
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# 若机器上只有 PowerShell 7（无 powershell.exe），改用：
# pwsh -ExecutionPolicy Bypass -File .\deploy.ps1

# 3. 重启 OpenCode（关闭并重新打开 TUI/桌面应用；后台服务会自动跟随配置）
```

> **无需重启后台服务**：wrapper 从注册表实时读取用户环境变量，配置文件的 `shell` 字段会被 OpenCode 热加载。重启 OpenCode 只是最稳妥的保险。

### 部署脚本做了什么

1. 把 `bin\pwsh-utf8.exe` 复制到 `~\.config\opencode\`；
2. 在 `~\.config\opencode\opencode.jsonc`（或 `.json`）中设置/更新 `"shell"` 字段（保留其他配置与注释）；
3. `setx PYTHONUTF8 1`、`setx PYTHONIOENCODING utf-8`；
4. （交互询问）安装 PowerShell profile 的 UTF-8 编码块；
5. 自动验证：运行 wrapper 输出中文/emoji 并校验结果。

### 脚本参数

```powershell
.\deploy.ps1 [-ConfigDir <路径>] [-InstallProfile] [-SkipPythonEnv] [-SkipVerify]
```

| 参数 | 说明 |
|------|------|
| `-ConfigDir` | OpenCode 配置目录，默认 `~\.config\opencode` |
| `-InstallProfile` | 不询问，直接安装 profile |
| `-SkipPythonEnv` | 跳过 Python 环境变量设置 |
| `-SkipVerify` | 跳过部署后的自动验证 |

## 手动部署（不想用脚本时）

1. 复制 `bin\pwsh-utf8.exe` 到 `C:\Users\<你>\.config\opencode\pwsh-utf8.exe`；
2. 编辑 `C:\Users\<你>\.config\opencode\opencode.jsonc`，添加一行
   （Windows 路径中的 `\` 需写成 `\\`）：
   ```jsonc
   {
     "$schema": "https://opencode.ai/config.json",
     "shell": "C:\\Users\\<你>\\.config\\opencode\\pwsh-utf8.exe"
   }
   ```
3. 打开 PowerShell 执行：
   ```powershell
   setx PYTHONUTF8 1
   setx PYTHONIOENCODING utf-8
   ```
4. （可选）把以下内容追加到 `$PROFILE`（用 `echo $PROFILE` 查看路径）：
   ```powershell
   [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
   [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
   $OutputEncoding = [System.Text.Encoding]::UTF8
   ```

## 验证

在 OpenCode 会话中执行（**不要**带任何手动编码设置）：

```powershell
Write-Output "中文测试：你好，世界！"; Write-Output "Emoji: 😀🎉🚀🔥👍"
python -c "print('Python中文测试：你好，世界！😀✅')"
```

预期：中文与 emoji 全部正常显示。

## 重新编译（可选）

预编译的 `bin\pwsh-utf8.exe`（随 Release 发布）适用于 **win-x64** 机器。其他平台（如 ARM64）或需要修改源码时，用 .NET 10+ SDK 重新编译：

```powershell
# 需要: .NET 10 或更高版本 SDK（https://dotnet.microsoft.com/download）
.\build.ps1                  # 默认 win-x64
.\build.ps1 -Rid win-arm64   # ARM64
```

产物输出到 `bin\pwsh-utf8.exe`。首次编译需联网（自动下载 NativeAOT 编译组件），约 1~2 分钟。

> 注意：更新运行中的 `pwsh-utf8.exe` 时文件会被占用（Windows 无法覆盖正在运行的 exe）。
> 如需就地更新，先复制为新文件名、把配置切过去，再覆盖旧文件（详见 README"常见问题"）。

## 卸载 / 回滚

```powershell
.\uninstall.ps1
```

会：移除配置中的 `shell` 字段（仅当指向 pwsh-utf8）、删除 exe、删除 `PYTHONUTF8`/`PYTHONIOENCODING` 环境变量、移除 profile 中本方案添加的代码块。

## 常见问题（FAQ）

**Q：部署后 OpenCode 里仍乱码？**
先完全关闭并重新打开 OpenCode（配置热加载偶有延迟）。再检查 `~\.config\opencode\opencode.jsonc` 中 `shell` 字段是否指向正确的绝对路径、exe 是否在该位置。

**Q：某些命令输出里出现 `#< CLIXML ...` 文本？**
无害。PowerShell 重定向 stderr 时会把进度/错误记录序列化为 CLIXML，harness 原样显示而已，不影响功能。

**Q：为什么不需要重启 OpenCode 后台服务？**
其他方案用 `setx` 后需要重启服务（子进程继承服务启动时的旧环境）。本方案的 wrapper 每次启动都会从注册表 `HKLM`+`HKCU\Environment` 读取**当前**机器+用户环境变量（`Path` 按机器+用户重建，`REG_EXPAND_SZ` 展开）并覆盖子进程环境，所以任何 `setx` 立即生效，且能修复服务进程 PATH 缺机器部分的问题。

**Q：TUI 内置终端会受影响吗？**
不会。wrapper 对无 `-c` 参数的交互式调用直接转发给 pwsh（正常加载 profile）。如果你部署时选择了安装 profile，TUI 终端也会因此获得 UTF-8 编码。

**Q：这个 wrapper 有性能开销吗？**
NativeAOT 单文件 exe，启动 <10ms，每条命令只增加一次进程切换，可忽略。

**Q：更新 exe 时提示“文件被占用”？**
Windows 无法覆盖正在运行的 exe（TUI 终端标签页会一直持有 wrapper）。做法：把新版复制为 `pwsh-utf8-v2.exe` 放到配置目录，把配置中 `shell` 字段指向新文件名，重启 OpenCode 后再删除旧文件。`uninstall.ps1` 会一并清理 `pwsh-utf8*.exe`。

**Q：支持非 Windows 机器吗？**
不支持也不需要——本方案只针对 Windows 的 GBK 代码页问题。macOS/Linux 的 shell 默认 UTF-8。

## 工作原理补充

- **命令传递**：OpenCode 调用 `shell -c "<命令>"`。wrapper 将 `前导; 原命令` 编码为 base64（UTF-16LE）后以 `pwsh -NoProfile -EncodedCommand <b64>` 执行，多行、引号、花括号、emoji 均无损。
- **UTF-8 前导**（每次 shell 命令执行前自动运行）：
  ```powershell
  $ErrorActionPreference='Continue';
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8;
  [Console]::InputEncoding  = [System.Text.Encoding]::UTF8;
  $OutputEncoding = [System.Text.Encoding]::UTF8;
  ```
- **进程生命周期**：子 pwsh 挂到 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Job Object 上，wrapper 退出/被杀时子进程同步终止，等价于 OpenCode 直接 spawn pwsh 的语义。
- **退出码**：wrapper 原样转发子 pwsh 的退出码（`exit 42` → 42；与默认 `pwsh -c` 行为一致）。

## 许可证

MIT，见 [LICENSE](LICENSE)。欢迎提 Issue / PR。
