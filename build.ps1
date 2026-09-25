# build.ps1 — 重新编译 pwsh-utf8.exe（需要 .NET 10+ SDK，首次编译需联网）
# 用法: .\build.ps1 [-Rid win-x64] [-Config Release]
param(
    [string]$Rid = 'win-x64',
    [string]$Config = 'Release'
)

$ErrorActionPreference = 'Stop'
$srcDir = Join-Path $PSScriptRoot 'src'
$proj = Join-Path $srcDir 'pwsh-utf8.csproj'
if (-not (Test-Path $proj)) { throw "找不到 $proj" }

Write-Host "==> 编译 pwsh-utf8 ($Rid / $Config)" -ForegroundColor Cyan
dotnet publish $proj -c $Config -r $Rid
if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败 (exit $LASTEXITCODE)" }

$out = Join-Path $srcDir "bin\$Config\net10.0\$Rid\publish\pwsh-utf8.exe"
if (-not (Test-Path $out)) { throw "未找到编译产物: $out" }

$binDir = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item $out (Join-Path $binDir 'pwsh-utf8.exe') -Force

Write-Host "==> 完成 -> $(Join-Path $binDir 'pwsh-utf8.exe')" -ForegroundColor Green
Write-Host "如需部署，运行 .\deploy.ps1（若目标机器已部署且 exe 被占用，先关闭 OpenCode 再更新）。"
