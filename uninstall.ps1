# uninstall.ps1 — 回滚 OpenCode V2 UTF-8 Shell 部署
# 用法: powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 [-ConfigDir <路径>]
param(
    [string]$ConfigDir = "$env:USERPROFILE\.config\opencode"
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ---------- 1. 移除配置中的 shell 字段（仅当指向 pwsh-utf8） ----------
$cfgPath = Join-Path $ConfigDir 'opencode.jsonc'
if (-not (Test-Path $cfgPath)) {
    $cfgJson = Join-Path $ConfigDir 'opencode.json'
    if (Test-Path $cfgJson) { $cfgPath = $cfgJson }
}
if (Test-Path $cfgPath) {
    $lines = [System.IO.File]::ReadAllLines($cfgPath)
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*"shell"\s*:' -and $line -match 'pwsh-utf8') {
            $removed = $true
            continue
        }
        $kept.Add($line)
    }
    if ($removed) {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($cfgPath, $kept.ToArray(), $utf8NoBom)
        Write-Step "已从配置移除 shell 字段: $cfgPath"
    } else {
        Write-Step "配置中未发现指向 pwsh-utf8 的 shell 字段，跳过"
    }
} else {
    Write-Step "未找到配置文件，跳过"
}

# ---------- 2. 删除 wrapper exe（含版本化副本，如 pwsh-utf8-v2.exe） ----------
Write-Step "删除 pwsh-utf8.exe"
$destExe = Join-Path $ConfigDir 'pwsh-utf8.exe'
$exeFiles = @( $destExe ) + @( Get-ChildItem -Path $ConfigDir -Filter 'pwsh-utf8*.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName )
$exeFiles = $exeFiles | Select-Object -Unique
$deletedAny = $false
foreach ($f in $exeFiles) {
    if (-not (Test-Path $f)) { continue }
    try {
        Remove-Item $f -Force -ErrorAction Stop
        Write-Host "  已删除 -> $f"
        $deletedAny = $true
    } catch {
        Write-Warning "删除失败（可能正被占用）：$($_.Exception.Message)"
        Write-Host "  请完全关闭 OpenCode 后手动删除: $f"
    }
}
if (-not $deletedAny -and -not (Test-Path $destExe)) {
    Write-Host "  文件不存在，跳过"
}

# ---------- 3. 移除 Python 环境变量 ----------
Write-Step "移除 PYTHONUTF8 / PYTHONIOENCODING 用户环境变量"
foreach ($name in @('PYTHONUTF8', 'PYTHONIOENCODING')) {
    $cur = [Environment]::GetEnvironmentVariable($name, 'User')
    if ($cur -ne $null) {
        # setx 空值不会真正删除变量，用注册表删除 + .NET 清除
        try { [Environment]::SetEnvironmentVariable($name, $null, 'User') } catch { }
        try { Remove-ItemProperty -Path HKCU:\Environment -Name $name -ErrorAction Stop } catch { }
        Write-Host "  已移除 $name"
    } else {
        Write-Host "  $name 未设置，跳过"
    }
}

# ---------- 4. 移除 profile 代码块 ----------
Write-Step "移除 PowerShell profile 中本方案的代码块"
$prof = $PROFILE.CurrentUserAllHosts
if (-not $prof) { $prof = $PROFILE }
if (-not $prof) { $prof = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1' }
if (Test-Path $prof) {
    $text = [System.IO.File]::ReadAllText($prof)
    $pattern = '(?m)[\r\n]*# >>> opencode-utf8-shell.*?# <<< opencode-utf8-shell[\r\n]*'
    $newText = [System.Text.RegularExpressions.Regex]::Replace($text, $pattern, "`r`n", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($newText -ne $text) {
        [System.IO.File]::WriteAllText($prof, $newText, (New-Object System.Text.UTF8Encoding($true)))
        Write-Host "  已从 profile 移除代码块 -> $prof"
    } else {
        Write-Host "  profile 中未找到本方案的代码块，跳过"
    }
} else {
    Write-Host "  未找到 profile，跳过"
}

Write-Host ""
Write-Host "回滚完成。已新开的进程立即生效；正在运行的程序需重启。" -ForegroundColor Green
