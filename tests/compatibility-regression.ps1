# Isolated harness contracts; no Windows deployment APIs are called.
param([string]$SourceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = if ($SourceRoot) { $SourceRoot } else { Split-Path -Parent $PSScriptRoot }
$hostExe = (Get-Process -Id $PID).Path
$passed = 0; $failed = 0
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.GetType().FullName): $($_.Exception.Message)" }
}
$support = Join-Path $repo 'tests/test-support.ps1'
if (Test-Path -LiteralPath $support) { . $support }
Test-Case 'test entry defaults do not depend on PSScriptRoot during parameter binding' {
    foreach ($name in @('installer-regression.ps1','download-regression.ps1','compatibility-regression.ps1','run-regressions.ps1')) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo "tests/$name"), [ref]$null, [ref]$null)
        if ($ast.ParamBlock) {
            foreach ($p in $ast.ParamBlock.Parameters) {
                Assert-True (-not $p.DefaultValue -or $p.DefaultValue.Extent.Text -notmatch '\$PSScriptRoot') "$name binds PSScriptRoot too early"
            }
        }
    }
}
Test-Case 'archive dependencies are explicitly loaded before fixture and manifest parsing' {
    foreach ($name in @('scripts/common.ps1','tests/installer-regression.ps1','tests/download-regression.ps1')) {
        $text = [IO.File]::ReadAllText((Join-Path $repo $name))
        Assert-True ($text -match 'Add-Type -AssemblyName System\.IO\.Compression\b(?:[^\r\n]*)-ErrorAction Stop') "$name lacks explicit Compression dependency"
    }
}
Test-Case 'every complete BAT invocation uses the console-isolated native runner' {
    foreach ($name in @('installer-regression.ps1','risk-regression.ps1')) {
        $text = [IO.File]::ReadAllText((Join-Path $repo "tests/$name"))
        Assert-True ($text -notmatch '& \$env:ComSpec') "$name attaches CMD to the suite console"
        Assert-True ($text -match 'Invoke-TestNative') "$name lacks isolated CMD execution"
    }
}
Test-Case 'structured child results preserve Unicode arguments, output and explicit exit codes' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir
    try {
        $entry = Join-Path $dir 'child.ps1'
        [IO.File]::WriteAllText($entry, 'param($Value) Write-Host ("中文：" + $Value); exit 7', (New-Object Text.UTF8Encoding($true)))
        $r = Invoke-TestChild -HostExe $hostExe -EntryPath $entry -Arguments @('-Value', "引号's & ! [test]")
        Assert-True ($r.Code -eq 7 -and $r.ProcessCode -eq 7) "child exit mismatch: $($r | ConvertTo-Json -Depth 8)"
        Assert-True ($r.Output -match [regex]::Escape("中文：引号's & ! [test]")) "Unicode output lost: $($r | ConvertTo-Json -Depth 8)"
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
Test-Case 'structured child diagnostics retain exception types, inner exception and PowerShell stack' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir
    try {
        $entry = Join-Path $dir 'child.ps1'
        [IO.File]::WriteAllText($entry, 'function Fail-Fixture { throw (New-Object InvalidOperationException("outer failure", (New-Object IO.IOException("inner failure")))) }; Fail-Fixture', (New-Object Text.UTF8Encoding($true)))
        $r = Invoke-TestChild -HostExe $hostExe -EntryPath $entry
        $details = $r.Errors | ConvertTo-Json -Depth 12
        Assert-True ($r.Code -ne 0 -and $details -match 'InvalidOperationException' -and $details -match 'IOException' -and $details -match 'Fail-Fixture') "exception evidence lost: $($r | ConvertTo-Json -Depth 12)"
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force }
}
if ($env:OS -eq 'Windows_NT') {
    Test-Case 'isolated CMD code-page changes cannot alter the parent console, including failure' {
        $before = Get-TestConsoleState
        try {
            foreach ($command in @('chcp 65001 >nul & exit /b 0', 'chcp 437 >nul & exit /b 3')) {
                $null = Invoke-TestNative -FilePath $env:ComSpec -Arguments ('/d /c "' + $command + '"')
                $after = Get-TestConsoleState
                Assert-True (($before | ConvertTo-Json -Compress) -eq ($after | ConvertTo-Json -Compress)) 'CMD changed parent console state'
            }
        } finally { Restore-TestConsoleState -State $before }
    }
} else { Write-Host 'SKIP native CMD console isolation (requires Windows)' }
Write-Host "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
