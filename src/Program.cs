using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// OpenCode shell wrapper: guarantees pwsh stdout/stderr are UTF-8 so Chinese and emoji
// survive the pipe. OpenCode invokes: pwsh-utf8.exe -c "<command>".
// The command is passed to pwsh via -EncodedCommand (base64 UTF-16LE), which is immune
// to Windows command-line quoting issues (multi-line, quotes, special chars all safe).
// The TUI terminal invokes it with no -c (or other flags) -> plain interactive pwsh.

// Job object with KILL_ON_JOB_CLOSE: if this wrapper dies (timeout kill, etc.),
// the child pwsh dies with it — same semantics as OpenCode spawning pwsh directly.
const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
IntPtr job = Kernel32.CreateJobObject(IntPtr.Zero, null);

if (job != IntPtr.Zero)
{
    var info = new Kernel32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        BasicLimitInformation = new Kernel32.JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        },
    };
    int infoSize = Marshal.SizeOf<Kernel32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
    IntPtr infoPtr = Marshal.AllocHGlobal(infoSize);
    try
    {
        Marshal.StructureToPtr(info, infoPtr, false);
        Kernel32.SetInformationJobObject(job, 9 /* JobObjectExtendedLimitInformation */, infoPtr, (uint)infoSize);
    }
    finally
    {
        Marshal.FreeHGlobal(infoPtr);
    }
}

var argsList = Environment.GetCommandLineArgs();
var rest = argsList.Length > 1 ? argsList[1..] : [];

string pwshPath = ResolvePwsh();
var psi = new ProcessStartInfo(pwshPath) { UseShellExecute = false };

// pwsh parameter names are case-insensitive and allow abbreviation.
// Accept -c / -Command / --command (any case); OpenCode always sends lowercase -c.
bool isCommand = rest.Length >= 2 && IsCommandFlag(rest[0]);
if (isCommand)
{
    string command = rest[1];
    if (string.IsNullOrWhiteSpace(command)) return 0;

    string preamble =
        "$ErrorActionPreference='Continue'; " +
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
        "[Console]::InputEncoding=[System.Text.Encoding]::UTF8; " +
        "$OutputEncoding=[System.Text.Encoding]::UTF8; ";

    string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(preamble + command));
    MergeUserEnvironment(psi);
    psi.ArgumentList.Add("-NoProfile");
    psi.ArgumentList.Add("-EncodedCommand");
    psi.ArgumentList.Add(encoded);
    // Preserve any extra args instead of silently dropping them
    // (OpenCode currently passes none; pwsh binds them to $args).
    for (int i = 2; i < rest.Length; i++) psi.ArgumentList.Add(rest[i]);
}
else
{
    // Interactive or unknown flags (TUI terminal): plain pwsh; the user profile
    // (which sets UTF-8 console encoding) loads normally.
    MergeUserEnvironment(psi);
    foreach (var a in rest) psi.ArgumentList.Add(a);
}

Process? proc;
try
{
    proc = Process.Start(psi);
}
catch (System.ComponentModel.Win32Exception) when (pwshPath != "pwsh")
{
    // Absolute-path probe failed (e.g. Store version moved): fall back to PATH resolution.
    psi = new ProcessStartInfo("pwsh") { UseShellExecute = false };
    MergeUserEnvironment(psi);
    // Rebuild args identically on the fallback instance.
    if (isCommand)
    {
        string command = rest[1];
        string preamble =
            "$ErrorActionPreference='Continue'; " +
            "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; " +
            "[Console]::InputEncoding=[System.Text.Encoding]::UTF8; " +
            "$OutputEncoding=[System.Text.Encoding]::UTF8; ";
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(preamble + command));
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-EncodedCommand");
        psi.ArgumentList.Add(encoded);
        for (int i = 2; i < rest.Length; i++) psi.ArgumentList.Add(rest[i]);
    }
    else
    {
        foreach (var a in rest) psi.ArgumentList.Add(a);
    }
    proc = Process.Start(psi);
}
if (proc is null) return 127;
using (proc)
{
    if (job != IntPtr.Zero) Kernel32.AssignProcessToJobObject(job, proc.Handle);
    proc.WaitForExit();
    int code = proc.ExitCode;
    if (job != IntPtr.Zero) Kernel32.CloseHandle(job);
    return code;
}

static bool IsCommandFlag(string s) =>
    s.Equals("-c", StringComparison.OrdinalIgnoreCase) ||
    s.Equals("-command", StringComparison.OrdinalIgnoreCase) ||
    s.Equals("--command", StringComparison.OrdinalIgnoreCase);

// Resolve pwsh without depending on a possibly-truncated PATH.
// Prefer PATH lookup; fall back to well-known absolute locations.
static string ResolvePwsh()
{
    try
    {
        string? pathEnv = Environment.GetEnvironmentVariable("Path")
            ?? Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrEmpty(pathEnv))
        {
            foreach (var dir in pathEnv.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    string candidate = Path.Combine(dir.Trim().Trim('"'), "pwsh.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
        }
    }
    catch { }

    string[] probes =
    [
        @"C:\Program Files\PowerShell\7\pwsh.exe",
        @"C:\Program Files (x86)\PowerShell\7\pwsh.exe",
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\WindowsApps\pwsh.exe"),
    ];
    foreach (var p in probes)
    {
        try { if (!string.IsNullOrEmpty(p) && File.Exists(p)) return p; }
        catch { }
    }
    // Final fallback: let the OS resolve (App execution alias / App Paths).
    return "pwsh";
}

// The OpenCode service inherits its environment at startup, so user-level env vars
// set afterwards (e.g. via setx) never reach shell children — even after a service
// restart spawned from the old service. Pull the current machine+user environment
// from the registry so new vars apply immediately (and repair a service process
// whose PATH lost the machine portion).
static void MergeUserEnvironment(ProcessStartInfo psi)
{
    try
    {
        var merged = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? machinePath = null;
        string? userPath = null;

        // Machine first, then user overrides (Windows semantics; Path concatenates).
        using (var lm = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"))
        {
            if (lm is not null)
            {
                foreach (var name in lm.GetValueNames())
                {
                    if (name.Equals("Path", StringComparison.OrdinalIgnoreCase))
                    {
                        machinePath = ReadRegString(lm, name);
                        continue;
                    }
                    string? v = ReadRegString(lm, name);
                    if (v is not null) merged[name] = v;
                }
            }
        }
        using (var cu = Microsoft.Win32.Registry.CurrentUser.OpenSubKey("Environment"))
        {
            if (cu is not null)
            {
                foreach (var name in cu.GetValueNames())
                {
                    if (name.Equals("Path", StringComparison.OrdinalIgnoreCase))
                    {
                        userPath = ReadRegString(cu, name);
                        continue;
                    }
                    string? v = ReadRegString(cu, name);
                    if (v is not null) merged[name] = v;
                }
            }
        }

        foreach (var kv in merged) SetEnv(psi, kv.Key, kv.Value);

        // Path: always rebuild as Machine + User so a truncated service PATH is repaired.
        // If registry is unreadable, leave the inherited Path untouched.
        if (machinePath is not null || userPath is not null)
        {
            string combined = string.Join(";",
                new[] { machinePath, userPath }.Where(s => !string.IsNullOrWhiteSpace(s)));
            if (!string.IsNullOrWhiteSpace(combined)) SetEnv(psi, "Path", combined);
        }
    }
    catch { }
}

static string? ReadRegString(Microsoft.Win32.RegistryKey key, string name)
{
    try
    {
        // GetValue expands REG_EXPAND_SZ by default; ExpandEnvironmentVariables
        // covers values read without expansion on some runtimes.
        var raw = key.GetValue(name) as string;
        if (raw is null) return null;
        try { return Environment.ExpandEnvironmentVariables(raw); }
        catch { return raw; }
    }
    catch { return null; }
}

static void SetEnv(ProcessStartInfo psi, string name, string value)
{
    // ProcessStartInfo.Environment is case-insensitive on Windows, but handle
    // case variations explicitly for safety across runtimes.
    string? existingKey = null;
    foreach (var k in psi.Environment.Keys)
    {
        if (k.Equals(name, StringComparison.OrdinalIgnoreCase)) { existingKey = k; break; }
    }
    if (existingKey is not null) psi.Environment[existingKey] = value;
    else psi.Environment[name] = value;
}

static class Kernel32
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInformationClass, IntPtr lpJobObjectInformation, uint cbJobObjectInformationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    internal struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }
}
