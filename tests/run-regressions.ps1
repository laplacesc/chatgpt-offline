# Run with powershell.exe or pwsh -NoProfile -File tests\run-regressions.ps1.
# All child operations are isolated fixtures; this runner never deploys an application.
param([string]$EvidenceDir)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'test-support.ps1')
if (-not $EvidenceDir) { $EvidenceDir = Join-Path ([IO.Path]::GetTempPath()) ('chatgpt-regressions-' + [guid]::NewGuid().ToString('N')) }
$null = New-Item -ItemType Directory -Path $EvidenceDir -Force
$EvidenceDir = (Resolve-Path -LiteralPath $EvidenceDir).Path
$hostExe = (Get-Process -Id $PID).Path
$environment = [pscustomobject]@{
    PowerShellVersion = [string]$PSVersionTable.PSVersion; Edition = $PSVersionTable.PSEdition
    CLRVersion = [string]$PSVersionTable['CLRVersion']; FrameworkVersion = [string][Environment]::Version
    OS = [Environment]::OSVersion.VersionString; HostExe = $hostExe; PointerBytes = [IntPtr]::Size
    ConsoleInputEncoding = [Console]::InputEncoding.WebName; ConsoleOutputEncoding = [Console]::OutputEncoding.WebName
    PipelineEncoding = $OutputEncoding.WebName
}
[IO.File]::WriteAllText((Join-Path $EvidenceDir 'environment.json'), ($environment | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($true)))
$results = @(); $exitCode = 0
foreach ($name in @('source-validation','compatibility-regression','installer-regression','download-regression')) {
    $arguments = @()
    if ($name -in @('installer-regression','download-regression')) { $arguments = @('-EvidenceDir', (Join-Path $EvidenceDir $name)) }
    try {
        $result = Invoke-TestChild -HostExe $hostExe -EntryPath (Join-Path $PSScriptRoot ($name + '.ps1')) -Arguments $arguments
        Write-Host $result.Output
        if ($result.Code -ne 0 -or $result.ProcessCode -ne 0) { $exitCode = 1 }
        $results += [pscustomobject]@{ Name = $name; Result = $result }
    } catch {
        $exitCode = 1
        $results += [pscustomobject]@{ Name = $name; Error = (Get-TestErrorDetails $_) }
        Write-Host "$name failed: $((Get-TestErrorDetails $_) | ConvertTo-Json -Depth 16 -Compress)"
    }
}
[IO.File]::WriteAllText((Join-Path $EvidenceDir 'results.json'), (@{ ExitCode = $exitCode; Suites = $results } | ConvertTo-Json -Depth 28), (New-Object Text.UTF8Encoding($true)))
Write-Host "Evidence: $EvidenceDir"
exit $exitCode
