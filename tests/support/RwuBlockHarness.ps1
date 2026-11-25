<#
    Runs labelled blocks of the shipped Reset_WindowsUpdate.cmd against stub tools.

    The child PATH holds only a stub directory, so the block under test cannot reach the real
    sc, net, reg, bitsadmin, regsvr32, ping or fltmc. A missing stub is "not recognized".

    Scenario keys (hashtable, all optional):
      state.<svc>          sc query state, or a comma list that is consumed one per query
                           (last value repeats); 0 = exit 1060, U = exit 5, X = unparsable
      label.state          text of the state label (default STATE)
      winexit.<svc>        text after WIN32_EXIT_CODE (default "0  (0x0)")
      start.<svc>          registry Start value; absent = reg exits 1
      netstop.<svc>        net stop exit code;  netstop.<svc>.sets  = "svc:state;svc:state"
      netstart.<svc>       net start exit code; netstart.<svc>.sets = same
      regsvr32.<dll>       regsvr32 exit code
      exit.<tool>          exit code for any other call of that tool
#>

$script:RwuTools = 'sc', 'net', 'reg', 'bitsadmin', 'regsvr32', 'ping', 'fltmc'
$script:RwuCmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$script:RwuWinPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$script:RwuStubSource = @'
using System; using System.Collections.Generic; using System.IO; using System.Text;
public class RwuStub {
    static Dictionary<string,string> d = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    static string file;
    static string Get(string k, string dflt) { string v; return d.TryGetValue(k, out v) ? v : dflt; }
    static int Code(string k) { return int.Parse(Get(k, "0")); }
    static void Save() {
        var sb = new StringBuilder();
        foreach (var p in d) sb.Append(p.Key).Append('=').Append(p.Value).Append('\n');
        File.WriteAllText(file, sb.ToString());
    }
    static void Apply(string sets) {
        foreach (var s in sets.Split(new[]{';'}, StringSplitOptions.RemoveEmptyEntries)) {
            int i = s.IndexOf(':'); d["state." + s.Substring(0, i)] = s.Substring(i + 1);
        }
        Save();
    }
    static int Main(string[] a) {
        string tool = Path.GetFileNameWithoutExtension(System.Reflection.Assembly.GetExecutingAssembly().Location).ToLowerInvariant();
        File.AppendAllText(Environment.GetEnvironmentVariable("RWU_STUB_LOG"), (tool + " " + string.Join(" ", a)).Trim() + "\n");
        file = Environment.GetEnvironmentVariable("RWU_STUB_SCENARIO");
        foreach (var l in File.ReadAllLines(file)) { int i = l.IndexOf('='); if (i > 0) d[l.Substring(0, i)] = l.Substring(i + 1); }
        string verb = a.Length > 0 ? a[0].ToLowerInvariant() : "";
        string svc = a.Length > 1 ? a[1] : "";
        if (tool == "sc" && verb == "query") {
            string v = Get("state." + svc, "1"); int c = v.IndexOf(',');
            if (c > 0) { d["state." + svc] = v.Substring(c + 1); Save(); v = v.Substring(0, c); }
            if (v == "0") { Console.WriteLine("[SC] EnumQueryServicesStatus:OpenService FAILED 1060:"); return 1060; }
            if (v == "U") { Console.WriteLine("[SC] OpenService FAILED 5:"); return 5; }
            if (v == "X") { Console.WriteLine("no state line here"); return 0; }
            string[] n = { "", "STOPPED", "START_PENDING", "STOP_PENDING", "RUNNING", "CONTINUE_PENDING", "PAUSE_PENDING", "PAUSED" };
            Console.WriteLine();
            Console.WriteLine("SERVICE_NAME: " + svc + " ");
            Console.WriteLine("        TYPE               : 20  WIN32_SHARE_PROCESS  ");
            Console.WriteLine("        " + Get("label.state", "STATE").PadRight(19) + ": " + v + "  " + n[int.Parse(v)] + " ");
            Console.WriteLine("                                (STOPPABLE, NOT_PAUSABLE, ACCEPTS_SHUTDOWN)");
            Console.WriteLine("        WIN32_EXIT_CODE    : " + Get("winexit." + svc, "0  (0x0)"));
            Console.WriteLine("        SERVICE_EXIT_CODE  : 0  (0x0)");
            Console.WriteLine("        CHECKPOINT         : 0x0");
            Console.WriteLine("        WAIT_HINT          : 0x0");
            return 0;
        }
        if (tool == "sc" && verb == "qc") { Console.WriteLine("        START_TYPE         : 3   DEMAND_START"); return 0; }
        if (tool == "net" && (verb == "stop" || verb == "start")) {
            int rc = Code("net" + verb + "." + svc);
            string sets = Get("net" + verb + "." + svc + ".sets", rc == 0 ? svc + ":" + (verb == "stop" ? "1" : "4") : "");
            Apply(sets);
            return rc;
        }
        if (tool == "reg" && verb == "query" && a.Length > 3 && a[3].ToLowerInvariant() == "start") {
            string s = a[1].Substring(a[1].LastIndexOf('\\') + 1); string v = Get("start." + s, "");
            if (v == "") { Console.Error.WriteLine("ERROR: The system was unable to find the specified registry key or value."); return 1; }
            Console.WriteLine(); Console.WriteLine(a[1]); Console.WriteLine("    Start    REG_DWORD    0x" + v); Console.WriteLine();
            return 0;
        }
        if (tool == "regsvr32") return Code("regsvr32." + a[a.Length - 1]);
        return Code("exit." + tool);
    }
}
'@

function Initialize-RwuStubs {
    # One C# program, compiled once per run, copied under every stubbed tool name.
    if ($global:RwuStubDir -and (Test-Path $global:RwuStubDir)) { return $global:RwuStubDir }
    $dir = Join-Path ([IO.Path]::GetTempPath()) "rwu_stub_${PID}_$(Get-Random)"
    New-Item -ItemType Directory $dir -Force | Out-Null
    $src = Join-Path $dir 'stub.cs'
    $exe = Join-Path $dir 'stub-master.exe'
    Set-Content -LiteralPath $src -Value $script:RwuStubSource -Encoding utf8
    & $script:RwuWinPS -NoProfile -Command "Add-Type -Path '$src' -OutputType ConsoleApplication -OutputAssembly '$exe'" | Out-Null
    if (-not (Test-Path $exe)) { throw 'stub compilation failed' }
    foreach ($t in $script:RwuTools) { Copy-Item $exe (Join-Path $dir "$t.exe") }
    Remove-Item $src, $exe
    Copy-Item (Join-Path $env:SystemRoot 'System32\findstr.exe') $dir
    $global:RwuStubDir = $dir
    $dir
}

function Remove-RwuStubs {
    foreach ($d in $global:RwuStubDir, $global:RwuSeamDir) {
        if ($d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $global:RwuStubDir = $global:RwuSeamDir = $null
}

function Get-RwuScriptText {
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\Reset_WindowsUpdate.cmd'))
}

function Get-RwuLabelBlock {
    # Steps: from the label to the next top-level step label.
    # Helpers: to the next label whose name does not start with the helper's own name.
    # Nothing when the label is absent.
    param([string[]]$Lines, [string]$Label)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^:$Label\s*$") { $start = $i; break }
    }
    if ($start -lt 0) { return }
    $topLevel = '^(Step\d+|StepDone|FixDISM|FixSFC|FixCHKDSK|FixProxy)$'
    $end = $Lines.Count
    for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^:([A-Za-z]\w*)\s*$') {
            $name = $Matches[1]
            if ($Label -match $topLevel) {
                if ($name -match $topLevel) { $end = $i; break }
            } elseif (-not $name.StartsWith($Label)) { $end = $i; break }
        }
    }
    $Lines[$start..($end - 1)]
}

function Invoke-RwuProcess {
    # Runs cmd.exe /d with an empty stdin, a replaced environment and a time limit.
    param([string]$CommandLine, [hashtable]$Env = @{}, [string]$Cwd, [int]$TimeoutSec = 90)
    $psi = [Diagnostics.ProcessStartInfo]::new($script:RwuCmdExe, "/d /s /c `"$CommandLine`"")
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($Cwd) { $psi.WorkingDirectory = $Cwd }
    [void]$psi.Environment.Remove('NoDefaultCurrentDirectoryInExePath')
    $psi.Environment['PATHEXT'] = '.COM;.EXE;.BAT;.CMD'
    foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $p.Kill($true)
        throw "timeout after ${TimeoutSec}s: $CommandLine"
    }
    $p.WaitForExit()
    @{ ExitCode = $p.ExitCode; Output = $o.Result + $e.Result }
}

function Assert-RwuPreflight {
    # AC-1: every stubbed name must resolve, under the child PATH, to the stub directory.
    param([string]$StubDir, [string]$ChildPath, [string]$Cwd)
    $names = ($script:RwuTools | ForEach-Object { "$_.exe" }) -join ' '
    $r = Invoke-RwuProcess -CommandLine "for %T in ($names) do @echo %T=%~`$PATH:T" -Env @{ PATH = $ChildPath } -Cwd $Cwd
    foreach ($t in $script:RwuTools) {
        if ($r.Output -notmatch "(?m)^$t\.exe=(.*?)\r?$") { throw "preflight: no answer for $t.exe" }
        $got = $Matches[1].Trim()
        if ($got -ne (Join-Path $StubDir "$t.exe")) { throw "preflight: $t.exe resolves to '$got', not the stub directory" }
        if (Test-Path (Join-Path $Cwd "$t.exe")) { throw "preflight: $t.exe exists in the working directory" }
    }
    $r.Output
}

function Invoke-RwuBlock {
    param(
        [string[]]$Steps = @(),              # e.g. Step2, Step11 (concatenated in this order)
        [string[]]$Entry,                    # lines to run instead of 'goto :<first step>'
        [hashtable]$Scenario = @{},
        [hashtable]$Vars = @{},              # batch variables, set before EnableDelayedExpansion
        [hashtable]$Env = @{},
        [string]$ExtraPath,
        [string]$Text = (Get-RwuScriptText), # the shipped text, or a mutant of it
        [string[]]$Dll = @(),                # files to create in the fake system32
        [string]$StubDir,
        [int]$TimeoutSec = 90
    )
    if (-not $StubDir) { $StubDir = Initialize-RwuStubs }
    $dir = Join-Path ([IO.Path]::GetTempPath()) "rwu_block_$(Get-Random)"
    $sys32 = Join-Path $dir 'win\system32'
    $work = Join-Path $dir 'work'
    New-Item -ItemType Directory $sys32, $work -Force | Out-Null
    try {
        foreach ($f in $Dll) { Set-Content (Join-Path $sys32 $f) 'x' }
        $calls = Join-Path $dir 'calls.txt'
        $scen = Join-Path $dir 'scenario.txt'
        [IO.File]::WriteAllText($calls, '')
        [IO.File]::WriteAllText($scen, (($Scenario.Keys | ForEach-Object { "$_=$($Scenario[$_])" }) -join "`n") + "`n")

        $childPath = $StubDir
        if ($ExtraPath) { $childPath += ";$ExtraPath" }
        try { [void](Assert-RwuPreflight -StubDir $StubDir -ChildPath $childPath -Cwd $work) }
        catch { throw "$($_.Exception.Message); calls=<$([IO.File]::ReadAllText($calls))>" }

        $v = @{
            LOGFILE = (Join-Path $dir 'log.txt'); DEBUGLOG = (Join-Path $dir 'debug.log'); DESKTOP = $dir
            WARN_COUNT = 0; FAIL_COUNT = 0; DIAG_FINDINGS = 0; DEBUG = 0; _TESTMODE = 0; _CLI_MODE = 1
            _STOP_AFTER = 'Step14'; _RUN_LABEL = 'harness'; TIMESTAMP = '20260101-000000'; ver = '0.0.0'; _SP = 0; _STOPPED_BY_RUN = ' '; _BITS_RESET_PENDING = 0
        }
        foreach ($k in $Vars.Keys) { $v[$k] = $Vars[$k] }

        # Step blocks in order, then the closure of the helper labels they reference.
        $lines = $Text -split '\r?\n'
        $marker = '^(Step\d+|MainMenu|\w+Menu|ShowHelp)$'
        $ui = 'Spin', 'SpinDone', 'Trace', 'BlankScreen', 'DebugInit'
        $body = [Collections.Generic.List[string]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $queue = [Collections.Generic.Queue[string]]::new()
        $refRx = [regex]'(?i)\b(?:call|goto)\s*:([A-Za-z]\w*)'
        $addRefs = { param($ls) foreach ($l in $ls) { foreach ($m in $refRx.Matches($l)) { $queue.Enqueue($m.Groups[1].Value) } } }
        foreach ($s in $Steps) {
            $b = @(Get-RwuLabelBlock -Lines $lines -Label $s)
            if (-not $b.Count) { throw "label :$s not found" }
            [void]$seen.Add($s)
            $body.AddRange([string[]]$b)
            & $addRefs $b
        }
        $body.Add('goto :StepDone')
        if (-not $Entry) { $Entry = @("goto :$($Steps[0])") }
        & $addRefs $Entry
        while ($queue.Count) {
            $n = $queue.Dequeue()
            if ($n -eq 'StepDone' -or -not $seen.Add($n)) { continue }
            if ($body -match "^:$n\s*$") { continue }
            if ($ui -contains $n) { $body.AddRange([string[]]@(":$n", 'exit /b 0')); continue }
            if ($n -match $marker) { $body.AddRange([string[]]@(":$n", "echo HARNESS-GOTO $n", 'goto :StepDone')); continue }
            $b = @(Get-RwuLabelBlock -Lines $lines -Label $n)
            if ($b.Count) {
                $body.AddRange([string[]]$b)
                $body.Add('echo HARNESS-FELL-THROUGH & exit /b 97')
                & $addRefs $b
            }
        }

        $varsFile = Join-Path $dir 'vars.txt'
        $cwdFile = Join-Path $dir 'cwd.txt'
        $cmd = @('@echo off', 'setlocal DisableDelayedExpansion') +
            ($v.Keys | ForEach-Object { "set `"$_=$(([string]$v[$_]).Replace('%', '%%'))`"" }) +
            @('setlocal EnableDelayedExpansion') + $Entry + @('goto :StepDone') + $body +
            @(':StepDone', "cd > `"$cwdFile`"", "set > `"$varsFile`"", 'exit /b 0')
        $file = Join-Path $dir 'block.cmd'
        [IO.File]::WriteAllText($file, ($cmd -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)

        $e = @{
            PATH = $childPath; windir = (Join-Path $dir 'win'); TEMP = $dir; TMP = $dir
            RWU_STUB_LOG = $calls; RWU_STUB_SCENARIO = $scen
        }
        foreach ($k in $Env.Keys) { $e[$k] = $Env[$k] }
        $r = Invoke-RwuProcess -CommandLine "`"$file`"" -Env $e -Cwd $work -TimeoutSec $TimeoutSec
        if ($r.Output -match 'HARNESS-FELL-THROUGH') { throw "a helper fell through: $($r.Output)" }
        $outVars = @{}
        if (Test-Path $varsFile) {
            foreach ($l in [IO.File]::ReadAllLines($varsFile)) {
                $i = $l.IndexOf('=')
                if ($i -gt 0) { $outVars[$l.Substring(0, $i)] = $l.Substring($i + 1) }
            }
        }
        $files = @(Get-ChildItem $dir -Recurse -File -Filter '*.txt' | Where-Object Name -Like '*log.txt')
        [pscustomobject]@{
            ExitCode = $r.ExitCode
            Output   = $r.Output
            Log      = (@($files | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join '')
            LogFiles = @($files | ForEach-Object { $_.FullName.Substring($dir.Length + 1) })
            Vars     = $outVars
            Calls    = @([IO.File]::ReadAllLines($calls))
            Cwd      = $(if (Test-Path $cwdFile) { [IO.File]::ReadAllText($cwdFile).Trim() })
            Work     = $work
        }
    } finally {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -- TLS_SEAM: a loopback HTTP(S) server, and a powershell.exe that trusts it ------------------

$script:RwuProbeHttps = 'https://fe2cr.update.microsoft.com/v6/ClientWebService/client.asmx'
$script:RwuProbeHttp = 'http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/disallowedcertstl.cab'

$script:RwuServerSource = @'
using System; using System.IO; using System.Net; using System.Net.Security; using System.Net.Sockets;
using System.Security.Cryptography; using System.Security.Cryptography.X509Certificates; using System.Text; using System.Threading;
public class RwuServer {
    TcpListener l; X509Certificate2 cert; string[] replies;
    public int Port, Connections, Requests;
    // dn: empty = plain HTTP. replies: one per connection, the last one repeats: "drop", "garbage" (not HTTP),
    // or "<status>|<content type>".
    public RwuServer(string dn, string[] replies) {
        this.replies = replies;
        if (!string.IsNullOrEmpty(dn)) {
            using (var k = RSA.Create(2048)) {
                var q = new CertificateRequest(dn, k, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                using (var t = q.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddDays(1)))
                    cert = new X509Certificate2(t.Export(X509ContentType.Pfx));
            }
        }
        l = new TcpListener(IPAddress.Loopback, 0); l.Start(); Port = ((IPEndPoint)l.LocalEndpoint).Port;
        var th = new Thread(Serve); th.IsBackground = true; th.Start();
    }
    public string Uri { get { return (cert != null ? "https" : "http") + "://127.0.0.1:" + Port + "/"; } }
    public void Stop() { l.Stop(); }
    void Serve() {
        while (true) {
            TcpClient c;
            try { c = l.AcceptTcpClient(); } catch (Exception) { return; }
            string reply = replies[Math.Min(Connections, replies.Length - 1)];
            Connections++;
            try {
                using (c) {
                    Stream s = c.GetStream();
                    if (cert != null) { var x = new SslStream(s); x.AuthenticateAsServer(cert); s = x; }
                    var b = new byte[4096];
                    if (s.Read(b, 0, b.Length) > 0) Requests++;
                    if (reply == "drop") continue;
                    if (reply == "garbage") { s.Write(new byte[] { 88, 89, 90, 13, 10, 13, 10 }, 0, 7); s.Flush(); continue; }
                    var p = reply.Split('|');
                    var o = Encoding.ASCII.GetBytes("HTTP/1.1 " + p[0] + " Test\r\nContent-Type: " + p[1] +
                        "\r\nLocation: /elsewhere\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
                    s.Write(o, 0, o.Length); s.Flush();
                }
            } catch (Exception) { }
        }
    }
}
'@

$script:RwuSeamSource = @'
using System; using System.Diagnostics; using System.IO; using System.Net;
public class RwuSeam {
    // Called inside the real PowerShell, by the prologue below.
    public static void On() {
        ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
        WebRequest.DefaultWebProxy = null;
    }
    static int Main() {
        string c = Environment.CommandLine;
        int i = c.IndexOf("-Command \"", StringComparison.OrdinalIgnoreCase);
        if (i < 0) return 97;
        string self = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string head = c.Substring(0, i + 10);
        head = head.Substring(head.IndexOf(" -") + 1);
        string pro = Environment.GetEnvironmentVariable("RWU_SEAM_PROLOGUE") == "0" ? "" :
            "[void][Reflection.Assembly]::LoadFrom('" + self + "');[RwuSeam]::On();";
        var p = new ProcessStartInfo(Environment.GetEnvironmentVariable("RWU_REAL_PS"), head + pro + c.Substring(i + 10));
        p.UseShellExecute = false;
        var r = Process.Start(p); r.WaitForExit();
        File.AppendAllText(Environment.GetEnvironmentVariable("RWU_SEAM_LOG"), r.ExitCode + "\n");
        return r.ExitCode;
    }
}
'@

function Initialize-RwuSeam {
    if ($global:RwuSeamDir -and (Test-Path $global:RwuSeamDir)) { return $global:RwuSeamDir }
    if (-not ('RwuServer' -as [type])) {
        $refs = 'Sockets', 'Security', 'Primitives' | ForEach-Object { "System.Net.$_" }
        $refs += 'System.Security.Cryptography', 'System.Threading.Thread', 'System.Threading', 'System.Security.Principal',
        'System.Security.Principal.Windows', 'System.Collections.NonGeneric', 'Microsoft.Win32.Primitives', 'System.Linq',
        'System.ComponentModel.Primitives', 'System.Runtime'
        Add-Type -ReferencedAssemblies $refs -IgnoreWarnings -CompilerOptions '-nowarn:SYSLIB0057' -TypeDefinition $script:RwuServerSource
    }
    $dir = Join-Path ([IO.Path]::GetTempPath()) "rwu_seam_${PID}_$(Get-Random)"
    New-Item -ItemType Directory $dir -Force | Out-Null
    $src = Join-Path $dir 'seam.cs'
    Set-Content -LiteralPath $src -Value $script:RwuSeamSource -Encoding utf8
    & $script:RwuWinPS -NoProfile -Command "Add-Type -Path '$src' -OutputType ConsoleApplication -OutputAssembly '$dir\powershell.exe'" | Out-Null
    Remove-Item $src
    if (-not (Test-Path "$dir\powershell.exe")) { throw 'seam compilation failed' }
    $global:RwuSeamDir = $dir
    $dir
}

function Invoke-RwuStep13 {
    # Runs the shipped Step 13 with both probe literals replaced by loopback servers.
    # HttpsDn: issuer of the https server; '' = that server speaks plain HTTP.
    param(
        [string]$HttpsDn = 'CN=Microsoft Update Test, O=Microsoft Corporation, C=US',
        [string[]]$HttpsReply = '200|text/html',
        [string[]]$HttpReply = '200|application/vnd.ms-cab-compressed',
        [string]$Text = (Get-RwuScriptText),
        [switch]$NoPrologue
    )
    $seam = Initialize-RwuSeam
    foreach ($lit in $script:RwuProbeHttps, $script:RwuProbeHttp) {
        $n = [regex]::Matches($Text, [regex]::Escape($lit)).Count
        if ($n -ne 1) { throw "TLS_SEAM: '$lit' occurs $n times, not 1" }
    }
    $https = [RwuServer]::new($HttpsDn, $HttpsReply)
    $http = [RwuServer]::new('', $HttpReply)
    $codes = Join-Path ([IO.Path]::GetTempPath()) "rwu_codes_$(Get-Random).txt"
    [IO.File]::WriteAllText($codes, '')
    try {
        $t = $Text.Replace($script:RwuProbeHttps, $https.Uri).Replace($script:RwuProbeHttp, $http.Uri)
        $r = Invoke-RwuBlock -Steps Step13 -Text $t -ExtraPath $seam -Vars @{ _STOP_AFTER = 'Step13' } -TimeoutSec 180 -Env @{
            RWU_REAL_PS = $script:RwuWinPS; RWU_SEAM_LOG = $codes; RWU_SEAM_PROLOGUE = $(if ($NoPrologue) { '0' } else { '1' })
        }
        $r | Add-Member -NotePropertyMembers @{
            ProbeExits = @([IO.File]::ReadAllLines($codes) | ForEach-Object { [int]$_ })
            Https      = $https
            Http       = $http
            Findings   = [regex]::Matches($r.Log, 'FINDING: WU connectivity check failed').Count
        }
        $r
    } finally {
        $https.Stop(); $http.Stop()
        Remove-Item $codes -ErrorAction SilentlyContinue
    }
}
