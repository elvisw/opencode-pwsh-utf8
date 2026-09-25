# AGENTS.md — opencode-pwsh-utf8

> Guidance for AI coding agents working in this repo. Human docs live in README.md.

## What this is

A .NET NativeAOT `pwsh` wrapper (`pwsh-utf8.exe`) that fixes Chinese/emoji garbled
output from OpenCode V2 shell commands on Windows (GBK code page). OpenCode calls
`shell -c "<command>"`; the wrapper injects a UTF-8 preamble and forwards the
command via `pwsh -NoProfile -EncodedCommand <base64>`. Interactive calls
(no `-c`) are forwarded to `pwsh` untouched.

## Build

- Requires **.NET 10+ SDK** (`dotnet --list-sdks` must show 10.x).
- `.\build.ps1` (default `win-x64`) or `.\build.ps1 -Rid win-arm64`.
- Output: `bin\pwsh-utf8.exe` (self-contained, no runtime needed).
- CA1416 warnings about Registry APIs are expected (Windows-only tool).

## Test / verify (run inside an OpenCode session on Windows)

```powershell
Write-Output "中文测试：你好，世界！"; Write-Output "Emoji: 😀🎉🚀🔥👍"
python -c "print('Python中文测试：你好，世界！😀✅')"
& ~\.config\opencode\pwsh-utf8.exe -C 'Write-Output "大写C测试✅"'
& ~\.config\opencode\pwsh-utf8.exe -c 'exit 42'; $LASTEXITCODE  # must print 42
Get-Command setx.exe  # must resolve (proves machine PATH merge works)
```

`#< CLIXML` blobs in output are PowerShell stderr serialization under pipe
capture, not a wrapper bug — they appear only when the inner command errors.

## Key invariants (do not break)

- `src/Program.cs`: `-c`/`-Command`/`--command` matched **case-insensitively**;
  extra args after the command are forwarded, never dropped.
- `MergeUserEnvironment`: merges **HKLM + HKCU** registry environments,
  rebuilds `Path` as Machine+User (repairs services started with truncated PATH),
  expands `REG_EXPAND_SZ`. Never overwrite `Path` with the user-only value.
- `pwsh` resolution must not depend on a healthy PATH (absolute-path probes +
  `"pwsh"` fallback).
- Child `pwsh` stays on a `KILL_ON_JOB_CLOSE` job; wrapper forwards its exit code.
- `deploy.ps1`: `shell`-field insert/replace must keep JSONC comma rules
  (comma iff more fields follow). `setx` via `$env:SystemRoot\System32` absolute path.
- `uninstall.ps1`: removes `pwsh-utf8*.exe` (includes versioned copies) and truly
  deletes env vars (registry delete, not `setx ''`).

## Repo conventions

- **Never commit binaries**: `bin/` is git-ignored; prebuilt exe ships via GitHub Releases only.
- Binary/source changes → bump Release (tag `vX.Y.Z`, attach
  `opencode-pwsh-utf8-<ver>-win-x64.zip` + raw exe, include zip SHA256 in notes).
- README is Chinese-first; keep the `pwsh`-first deploy command
  (`powershell.exe` 5.1 is the fallback, not the default).
- Locked-exe upgrades: deploy as `pwsh-utf8-v2.exe`, repoint config, delete old
  file after OpenCode restart (see README FAQ).
