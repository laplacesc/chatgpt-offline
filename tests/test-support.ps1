# Shared test boundaries. Child output is UTF-8 JSON, independent of a shared console code page.
function Get-TestErrorDetails {
    param([Management.Automation.ErrorRecord]$Record)
    $chain = @(); $exception = $Record.Exception
    while ($null -ne $exception) {
        $chain += [pscustomobject]@{ Type = $exception.GetType().FullName; Message = $exception.Message; HResult = $exception.HResult; StackTrace = $exception.StackTrace }
        $exception = $exception.InnerException
    }
    $details = if ($Record.ErrorDetails) { $Record.ErrorDetails.Message } else { '' }
    [pscustomobject]@{ Exceptions = $chain; RecordMessage = $Record.ToString(); ErrorDetails = $details; ErrorId = $Record.FullyQualifiedErrorId; Category = [string]$Record.CategoryInfo; Position = $Record.InvocationInfo.PositionMessage; ScriptStackTrace = $Record.ScriptStackTrace }
}
function Invoke-TestNative {
    param([string]$FilePath, [string]$Arguments, [hashtable]$Environment = @{})
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath; $start.Arguments = $Arguments
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    foreach ($key in $Environment.Keys) { $start.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [pscustomobject]@{ Code = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result; Output = $stdout.Result + $stderr.Result }
    } finally { $process.Dispose() }
}
function Invoke-TestChild {
    param([string]$HostExe, [string]$EntryPath, [string[]]$Arguments = @(), [hashtable]$Environment = @{})
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-test-child-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir
    $recorder = Get-Item -LiteralPath Function:Record-Call -ErrorAction SilentlyContinue
    if ($recorder) { & $recorder.ScriptBlock 'HarnessScratch' $dir }
    try {
        $requestPath = Join-Path $dir 'request.json'; $responsePath = Join-Path $dir 'response.json'
        $request = @{ EntryPath = $EntryPath; Arguments = @($Arguments); ResponsePath = $responsePath }
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($true)))
        $runner = @'
param($RequestPath)
$ErrorActionPreference = 'Stop'
$request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json
$lines = New-Object 'Collections.Generic.List[string]'
$errors = @(); $code = 1
try {
    $global:LASTEXITCODE = 0
    $entryArguments = @{}
    $metadata = Get-Command -Name $request.EntryPath -ErrorAction Stop
    for ($i = 0; $i -lt $request.Arguments.Count; $i++) {
        $token = [string]$request.Arguments[$i]
        if ($token -notmatch '^-(?<Name>[A-Za-z][A-Za-z0-9]*)(?::(?<Bool>\$?(?:true|false)))?$') { throw "Unsupported fixture parameter token: $token" }
        $name = $Matches.Name; $bool = $Matches.Bool
        if (-not $metadata.Parameters.ContainsKey($name)) { throw "Unknown fixture parameter: $name" }
        if ($metadata.Parameters[$name].ParameterType -eq [Management.Automation.SwitchParameter]) {
            $entryArguments[$name] = (-not $bool -or $bool.TrimStart('$') -ieq 'true')
        } else {
            $i++
            if ($i -ge $request.Arguments.Count) { throw "Missing fixture value: $name" }
            $entryArguments[$name] = $request.Arguments[$i]
        }
    }
    & $request.EntryPath @entryArguments *>&1 | ForEach-Object {
        $lines.Add([string]$_)
        if ($_ -is [Management.Automation.ErrorRecord]) { $script:errors += Get-TestErrorDetails $_ }
    }
    $code = $LASTEXITCODE
} catch {
    $errors += Get-TestErrorDetails $_
    $lines.Add(($_ | Out-String))
    $code = 1
} finally {
    $result = @{ Code = $code; Output = ($lines -join [Environment]::NewLine); Errors = @($errors) }
    [IO.File]::WriteAllText($request.ResponsePath, ($result | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($true)))
}
exit $code
'@
        $runner = 'function Get-TestErrorDetails {' + ${function:Get-TestErrorDetails}.ToString() + "}`r`n" + $runner.Replace('param($RequestPath)', '')
        $runnerPath = Join-Path $dir 'runner.ps1'
        [IO.File]::WriteAllText($runnerPath, ('$RequestPath = ''' + $requestPath.Replace("'", "''") + "'`r`n" + $runner), (New-Object Text.UTF8Encoding($true)))
        $command = "& '" + $runnerPath.Replace("'", "''") + "'; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $native = Invoke-TestNative -FilePath $HostExe -Arguments ('-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + $encoded) -Environment $Environment
        if (-not [IO.File]::Exists($responsePath)) {
            throw "Child wrote no structured response. ProcessExit=$($native.Code); stdout=$($native.Stdout); stderr=$($native.Stderr)"
        }
        $response = [IO.File]::ReadAllText($responsePath) | ConvertFrom-Json
        if ($response.Code -ne $native.Code) {
            throw "Child response/process exit mismatch: response=$($response | ConvertTo-Json -Depth 20 -Compress); ProcessExit=$($native.Code); stdout=$($native.Stdout); stderr=$($native.Stderr)"
        }
        [pscustomobject]@{ Code = $response.Code; ProcessCode = $native.Code; Output = $response.Output; Errors = @($response.Errors); NativeStdout = $native.Stdout; NativeStderr = $native.Stderr }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
function Get-TestConsoleState {
    if (-not ('ChatGptTest.ConsoleCodePage' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace ChatGptTest {
    public static class ConsoleCodePage {
        [DllImport("kernel32.dll")] public static extern uint GetConsoleCP();
        [DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
        [DllImport("kernel32.dll")] public static extern bool SetConsoleCP(uint value);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleOutputCP(uint value);
    }
}
'@ -ErrorAction Stop
    }
    [pscustomobject]@{ InputCodePage = [ChatGptTest.ConsoleCodePage]::GetConsoleCP(); OutputCodePage = [ChatGptTest.ConsoleCodePage]::GetConsoleOutputCP(); InputEncoding = [Console]::InputEncoding; OutputEncoding = [Console]::OutputEncoding; PipelineEncoding = $global:OutputEncoding }
}
function Restore-TestConsoleState {
    param($State)
    [Console]::InputEncoding = $State.InputEncoding
    [Console]::OutputEncoding = $State.OutputEncoding
    $global:OutputEncoding = $State.PipelineEncoding
    if ($State.InputCodePage -ne 0) { $null = [ChatGptTest.ConsoleCodePage]::SetConsoleCP($State.InputCodePage) }
    if ($State.OutputCodePage -ne 0) { $null = [ChatGptTest.ConsoleCodePage]::SetConsoleOutputCP($State.OutputCodePage) }
}
