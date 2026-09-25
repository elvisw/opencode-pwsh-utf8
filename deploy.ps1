# deploy.ps1 — OpenCode V2 UTF-8 Shell 一键部署
# 用法: powershell -ExecutionPolicy Bypass -File .\deploy.ps1 [-ConfigDir <路径>] [-InstallProfile] [-SkipPythonEnv] [-SkipVerify]
param(
    [string]$ConfigDir = "$env:USERPROFILE\.config\opencode",
    [switch]$InstallProfile,
    [switch]$SkipPythonEnv,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$script:VerbosePreference = 'Continue'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ---------- 1. 复制 wrapper exe ----------
Write-Step "部署 pwsh-utf8.exe 到 $ConfigDir"
$srcExe = Join-Path $PSScriptRoot 'bin\pwsh-utf8.exe'
if (-not (Test-Path $srcExe)) { throw "找不到 bin\pwsh-utf8.exe，请确认包结构完整（或先运行 build.ps1 编译）" }
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
$destExe = Join-Path $ConfigDir 'pwsh-utf8.exe'
try {
    Copy-Item $srcExe $destExe -Force -ErrorAction Stop
    Write-Host "  已复制 -> $destExe"
} catch {
    throw "复制 exe 失败：$($_.Exception.Message)`n如果文件被占用，请先完全关闭 OpenCode（含 TUI 终端标签页）后重试。"
}

# ---------- 2. 更新 OpenCode 配置 ----------
Write-Step "更新 OpenCode 配置中的 shell 字段"
$cfgPath = Join-Path $ConfigDir 'opencode.jsonc'
if (-not (Test-Path $cfgPath)) {
    $cfgJson = Join-Path $ConfigDir 'opencode.json'
    if (Test-Path $cfgJson) { $cfgPath = $cfgJson }
}
$escaped = $destExe.Replace('\', '\\')
function Get-ShellLine([string]$escaped, [bool]$withComma) {
    if ($withComma) { return "  `"shell`": `"$escaped`"," }
    return "  `"shell`": `"$escaped`""
}
function Test-IsLastField([string[]]$lines, [int]$nextIndex) {
    for ($j = $nextIndex; $j -lt $lines.Count; $j++) {
        $t = $lines[$j].Trim()
        if ($t -eq '' -or $t.StartsWith('//')) { continue }
        return ($t.StartsWith('}') -or $t.StartsWith(']'))
    }
    return $true
}

if (Test-Path $cfgPath) {
    $lines = [System.IO.File]::ReadAllLines($cfgPath)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*"shell"\s*:') {
            # 尾逗号当且仅当后面还有字段（最后一个字段不加逗号）
            $isLast = Test-IsLastField $lines ($i + 1)
            $lines[$i] = Get-ShellLine $escaped (-not $isLast)
            $found = $true; break
        }
    }
    if (-not $found) {
        $insertAt = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '\$schema') { $insertAt = $i; break }
        }
        if ($insertAt -ge 0) {
            # 确保 $schema 行有尾逗号（后面新增字段），新 shell 行逗号取决于其后是否还有字段
            if ($lines[$insertAt] -notmatch ',\s*$') { $lines[$insertAt] = $lines[$insertAt] + ',' }
            $isLast = Test-IsLastField $lines ($insertAt + 1)
            $shellLine = Get-ShellLine $escaped (-not $isLast)
            $new = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -le $insertAt; $i++) { $new.Add($lines[$i]) }
            $new.Add($shellLine)
            for ($i = $insertAt + 1; $i -lt $lines.Count; $i++) { $new.Add($lines[$i]) }
            $lines = $new.ToArray()
        } else {
            # 没有 $schema 行：在第一个 { 之后插入
            $braceAt = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '\{') { $braceAt = $i; break } }
            if ($braceAt -lt 0) { throw "无法解析配置文件 $cfgPath（找不到大括号或 $schema 行）" }
            $isLast = Test-IsLastField $lines ($braceAt + 1)
            $shellLine = Get-ShellLine $escaped (-not $isLast)
            $new = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -le $braceAt; $i++) { $new.Add($lines[$i]) }
            $new.Add($shellLine)
            for ($i = $braceAt + 1; $i -lt $lines.Count; $i++) { $new.Add($lines[$i]) }
            $lines = $new.ToArray()
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($cfgPath, $lines, $utf8NoBom)
    Write-Host "  已更新 -> $cfgPath"
} else {
    $freshShell = Get-ShellLine $escaped $false
    $content = "{`n  `"`$schema`": `"https://opencode.ai/config.json`",`n$freshShell`n}`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($cfgPath, $content, $utf8NoBom)
    Write-Host "  已创建 -> $cfgPath"
}

# ---------- 3. Python 环境变量 ----------
# setx 在 System32 下；OpenCode 内 PATH 可能缺机器部分，用绝对路径回退
$setxExe = "$env:SystemRoot\System32\setx.exe"
if (-not (Test-Path $setxExe)) { $setxExe = 'setx' }
if (-not $SkipPythonEnv) {
    Write-Step "设置 Python UTF-8 环境变量（用户级）"
    & $setxExe PYTHONUTF8 1 | Out-Null
    & $setxExe PYTHONIOENCODING utf-8 | Out-Null
    Write-Host "  已设置 PYTHONUTF8=1、PYTHONIOENCODING=utf-8（新进程立即生效，OpenCode 内无需重启）"
} else {
    Write-Step "跳过 Python 环境变量设置（-SkipPythonEnv）"
}

# ---------- 4. PowerShell profile（可选） ----------
$profileBlock = @'
# >>> opencode-utf8-shell (UTF-8 console encoding)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# <<< opencode-utf8-shell
'@
if ($InstallProfile) { $doProfile = $true } else {
    $doProfile = $false
    if ($PSVersionTable.PSVersion.Major -ge 3) {
        $ans = Read-Host "是否安装 PowerShell profile UTF-8 设置？(y/N)"
        $doProfile = ($ans -match '^[yY]')
    }
}
if ($doProfile) {
    Write-Step "安装 profile UTF-8 设置"
    $prof = $PROFILE.CurrentUserAllHosts
    if (-not $prof) { $prof = $PROFILE }
    if (-not $prof) { $prof = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1' }
    $profDir = Split-Path $prof -Parent
    if ($profDir -and -not (Test-Path $profDir)) { New-Item -ItemType Directory -Force -Path $profDir | Out-Null }
    if (Test-Path $prof) {
        $existing = [System.IO.File]::ReadAllText($prof)
        if ($existing.Contains('>>> opencode-utf8-shell')) {
            Write-Host "  profile 已包含本方案的代码块，跳过"
        } else {
            Add-Content -Path $prof -Value $profileBlock -Encoding UTF8
            Write-Host "  已追加到 -> $prof"
        }
    } else {
        [System.IO.File]::WriteAllText($prof, $profileBlock, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "  已创建 -> $prof"
    }
}

# ---------- 5. 验证 ----------
if (-not $SkipVerify) {
    Write-Step "验证 UTF-8 输出"
    $oldConsole = [Console]::OutputEncoding
    $oldOutput = $OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $out = & $destExe -c 'Write-Output "中文测试：你好，世界！"; Write-Output "Emoji: 😀🎉✅"'
        $joined = $out -join "`n"
        if ($joined -match '你好' -and $joined -match '😀') {
            Write-Host "  [OK] 中文与 emoji 输出正常" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] 验证输出异常：$joined" -ForegroundColor Yellow
        }
    } finally {
        [Console]::OutputEncoding = $oldConsole
        $OutputEncoding = $oldOutput
    }
}

Write-Host ""
Write-Host "部署完成 ✅" -ForegroundColor Green
Write-Host "  - shell wrapper : $destExe"
Write-Host "  - OpenCode 配置 : $cfgPath"
if (-not $SkipPythonEnv) { Write-Host "  - Python 环境变量: 已设置" }
Write-Host "建议完全重启 OpenCode 以最稳妥生效。详情见 README.md。"
