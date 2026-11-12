# Run with: powershell -NoProfile -File tests\download-regression.ps1
# -SourceRoot can point at a saved baseline. No external requests or real signatures are used.
[CmdletBinding()]
param([string]$SourceRoot, [string]$EvidenceDir)
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $PSScriptRoot 'test-support.ps1')
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$hostExe = (Get-Process -Id $PID).Path
$passed = 0
$failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $script:lastFixtureDiagnostic = $null
        & $Body
        $script:passed++
        Write-Host "PASS $Name"
    } catch {
        $script:failed++
        Write-Host "FAIL $Name : $((Get-TestErrorDetails $_) | ConvertTo-Json -Depth 12 -Compress)"
        if ($script:lastFixtureDiagnostic) { Write-Host ($script:lastFixtureDiagnostic | ConvertTo-Json -Depth 20) }
    }
}
function New-FixturePackage {
    param([string]$Path, [string]$Version = '2.0.0.0', [string]$Name = 'OpenAI.Codex',
        [string]$Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B', [string]$Architecture = 'x64')
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $zip.CreateEntry('AppxManifest.xml', [IO.Compression.CompressionLevel]::NoCompression)
        $writer = New-Object IO.StreamWriter($entry.Open())
        try {
            $writer.Write(('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="{0}" Version="{1}" ProcessorArchitecture="{2}" Publisher="{3}"/><Properties><DisplayName>ChatGPT fixture</DisplayName></Properties></Package>' -f $Name, $Version, $Architecture, $Publisher))
        } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}
function Assert-ExpectedDownloadFailure {
    param($Result, [ValidateSet('transfer','size','signature')][string]$Kind)
    $expected = @{ transfer = 'fixture interrupted transfer'; size = '文件大小不符'; signature = '数字签名' }[$Kind]
    Assert-True ($Result.Runs.Count -eq 2 -and @($Result.Runs.RunId | Select-Object -Unique).Count -eq 2) 'retry runs must have distinct identities'
    foreach ($run in $Result.Runs) {
        Assert-True ($run.Code -eq 1 -and $run.ProcessCode -eq 1) "wrong $Kind exit status in $($run.RunId)"
        Assert-True (@($run.Calls | Where-Object { $_.RunId -ne $run.RunId }).Count -eq 0 -and @($run.Errors | Where-Object { $_.RunId -ne $run.RunId }).Count -eq 0) 'calls or errors belong to another run'
        $friendly = @($run.Errors | Where-Object { $_.Source -eq 'FriendlyError' })
        $stage = @{ transfer = 'stage:transfer:failed'; size = 'stage:transfer:complete'; signature = 'signature' }[$Kind]
        Assert-True ($friendly.Count -eq 1 -and $friendly[0].RecordMessage -match $expected -and $friendly[0].Stage -eq $stage) "wrong structured $Kind error or execution stage in $($run.RunId)"
        Assert-True ($friendly[0].Exceptions.Count -gt 0 -and $friendly[0].Exceptions[0].Type -eq 'System.Management.Automation.RuntimeException' -and $friendly[0].Exceptions[0].Message -match $expected) 'expected validation error type or exception message was replaced'
        Assert-True ($run.Output -match $expected -and @($run.Errors | Where-Object { $_.Source -ne 'FriendlyError' }).Count -eq 0) 'unexpected host or initialization error accompanied the retry'
        $values = @($run.Calls | ForEach-Object { $_.Value })
        Assert-True (@($values | Where-Object { $_ -like 'transfer:*' }).Count -eq 1) 'this run did not perform exactly one transfer'
        $completed = @($values | Where-Object { $_ -eq 'stage:transfer:complete' }).Count
        $failedTransfer = @($values | Where-Object { $_ -eq 'stage:transfer:failed' }).Count
        $manifest = @($values | Where-Object { $_ -eq 'manifest:ok' }).Count
        $signature = @($values | Where-Object { $_ -eq 'signature' }).Count
        if ($Kind -eq 'transfer') { Assert-True ($failedTransfer -eq 1 -and $completed -eq 0 -and $manifest -eq 0 -and $signature -eq 0) 'interrupted transfer reached validation' }
        elseif ($Kind -eq 'size') { Assert-True ($completed -eq 1 -and $failedTransfer -eq 0 -and $manifest -eq 0 -and $signature -eq 0) 'size failure occurred at another validation boundary' }
        else { Assert-True ($completed -eq 1 -and $failedTransfer -eq 0 -and $manifest -eq 1 -and $signature -eq 1) 'signature failure did not follow completed transfer and manifest parsing' }
        Assert-True ($run.Files.Count -eq 0) 'this failed run left published or partial bytes'
    }
    Assert-True ($Result.Files.Count -eq 0) 'failed download left published or partial bytes'
}
function Invoke-DownloadFixture {
    param([hashtable]$Scenario = @{}, [string[]]$Arguments = @(), [int]$Runs = 1)
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $scripts = Join-Path $tempDir 'scripts'
    $outDir = Join-Path $tempDir "output's [packages]"
    $null = New-Item -ItemType Directory -Path $scripts, $outDir
    try {
        Copy-Item (Join-Path $SourceRoot 'scripts/download-chatgpt-msix.ps1') $scripts
        $remote = Join-Path $tempDir 'remote.msix'
        $local = Join-Path $outDir 'ChatGPT-x64.msix'
        $defaults = @{
            Existing = ''; Engine = 'curl'; HeadFails = $false; TransferFails = $false
            RemoteInvalid = $false; SizeDelta = 0; Name = 'OpenAI.Codex'; Architecture = 'x64'
            Publisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
            Signer = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
            LicenseFails = $false; LicenseMalformed = $false; ExistingLicense = ''; InitFails = $false
        }
        foreach ($key in $Scenario.Keys) { $defaults[$key] = $Scenario[$key] }
        New-FixturePackage -Path $remote -Name $defaults.Name -Publisher $defaults.Publisher -Architecture $defaults.Architecture
        $remoteHash = (Get-FileHash -LiteralPath $remote -Algorithm SHA256).Hash
        $trustedHashes = @($remoteHash)
        switch ($defaults.Existing) {
            'partial-old' {
                $old = Join-Path $tempDir 'old.msix'
                New-FixturePackage -Path $old -Version '1.0.0.0'
                $bytes = [IO.File]::ReadAllBytes($old)
                [IO.File]::WriteAllBytes($local, $bytes[0..([int]($bytes.Length / 2))])
            }
            'same-size-corrupt' {
                [IO.File]::WriteAllBytes($local, (New-Object byte[] (Get-Item -LiteralPath $remote).Length))
            }
            'signature-corrupt' {
                New-FixturePackage -Path $local -Version '1.0.0.0'
            }
            'valid' {
                Copy-Item -LiteralPath $remote -Destination $local
            }
            'valid-old' {
                New-FixturePackage -Path $local -Version '1.0.0.0'
                $trustedHashes += (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            }
        }
        $originalHash = if (Test-Path -LiteralPath $local) { (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash } else { '' }
        if ($defaults.ExistingLicense) { [IO.File]::WriteAllText((Join-Path $outDir 'ChatGPT-License.xml'), $defaults.ExistingLicense) }
        if ($defaults.RemoteInvalid) { $trustedHashes = @($trustedHashes | Where-Object { $_ -ne $remoteHash }) }
        $defaults.RemoteHash = $remoteHash
        $defaults.TrustedHashes = $trustedHashes
        $defaults.RemoteSize = (Get-Item -LiteralPath $remote).Length
        $defaults | ConvertTo-Json | Set-Content (Join-Path $tempDir 'scenario.json') -Encoding UTF8
        $common = Get-Content (Join-Path $SourceRoot 'scripts/common.ps1') -Raw
        $common += "`n" + (Get-Content (Join-Path $PSScriptRoot 'test-support.ps1') -Raw)
        $common += "`n" + @'
$fixtureRoot = Split-Path -Parent $PSScriptRoot
$fixture = Get-Content (Join-Path $fixtureRoot 'scenario.json') -Raw | ConvertFrom-Json
$script:callsPath = Join-Path $fixtureRoot 'calls.jsonl'
$script:fixtureStage = 'initialization'
if ($fixture.RunNumber -eq 2 -and $fixture.PSObject.Properties['SecondFailureKind']) {
    $fixture.TransferFails = $false; $fixture.SizeDelta = 0; $fixture.TrustedHashes = @($fixture.RemoteHash)
    switch ($fixture.SecondFailureKind) {
        'transfer' { $fixture.TransferFails = $true }
        'size' { $fixture.SizeDelta = 10 }
        'signature' { $fixture.TrustedHashes = @() }
    }
}
if ($fixture.PSObject.Properties['SecondInitFails'] -and $fixture.SecondInitFails -and $env:CHATGPT_DOWNLOAD_RUN_NUMBER -eq '2') { throw (New-Object InvalidOperationException('fixture second initialization failure')) }
if ($fixture.InitFails) { throw (New-Object InvalidOperationException('fixture initialization failure', (New-Object IO.IOException('fixture dependency failure')))) }
$script:originalFriendlyError = ${function:Show-FriendlyError}
function Show-FriendlyError {
    param([Management.Automation.ErrorRecord]$ErrorRecord)
    $details = Get-TestErrorDetails $ErrorRecord
    $details | Add-Member -NotePropertyName RunId -NotePropertyValue $fixture.RunId
    $details | Add-Member -NotePropertyName Source -NotePropertyValue 'FriendlyError'
    $details | Add-Member -NotePropertyName Stage -NotePropertyValue $script:fixtureStage
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'errors.json'), ($details | ConvertTo-Json -Depth 16), (New-Object Text.UTF8Encoding($true)))
    & $script:originalFriendlyError -ErrorRecord $ErrorRecord
}
function Record-Call {
    param($Value)
    $script:fixtureStage = [string]$Value
    $entry = [pscustomobject]@{ RunId = $fixture.RunId; RunNumber = $fixture.RunNumber; Pid = $PID; Value = $Value }
    [IO.File]::AppendAllText($script:callsPath, (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}
$script:originalMsixReader = ${function:Get-MsixInfo}
function Get-MsixInfo {
    param([string]$Path)
    Record-Call 'manifest:start'
    try {
        $info = & $script:originalMsixReader -Path $Path
        Record-Call 'manifest:ok'
        return $info
    } catch { Record-Call 'manifest:failed'; throw }
}
function Start-AppLog { param($Name) return 'fixture.log' }
function Stop-AppLog { }
# Mock the HTTP boundary, including the HEAD request made through .NET.
Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @"
using System;
using System.Net;
public class FixtureRequest : WebRequest {
    public static long Size;
    public static bool HeadFails;
    public override string Method { get; set; }
    public override int Timeout { get; set; }
    public override WebResponse GetResponse() {
        if (HeadFails) throw new WebException("fixture HEAD unavailable");
        return new FixtureResponse();
    }
}
public class FixtureResponse : WebResponse {
    public override long ContentLength { get { return FixtureRequest.Size; } set {} }
}
public class FixtureCreator : IWebRequestCreate {
    public WebRequest Create(Uri uri) { return new FixtureRequest(); }
}
"@
[FixtureRequest]::Size = $fixture.RemoteSize + $fixture.SizeDelta
[FixtureRequest]::HeadFails = $fixture.HeadFails
$null = [Net.WebRequest]::RegisterPrefix('fixture:', (New-Object FixtureCreator))
$script:UrlMsixX64 = 'fixture://packages/ChatGPT-x64.msix'
$script:UrlMsixArm64 = 'fixture://packages/ChatGPT-arm64.msix'
$script:UrlLicense = 'fixture://packages/ChatGPT-License.xml'
$env:SystemRoot = Join-Path $fixtureRoot 'windows'
$script:curlPath = Join-Path $env:SystemRoot 'System32\curl.exe'
function Test-Path {
    [CmdletBinding()]
    param($Path, $LiteralPath)
    if ($LiteralPath -eq $script:curlPath) { return ($fixture.Engine -eq 'curl') }
    if ($LiteralPath) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
    return Microsoft.PowerShell.Management\Test-Path -Path $Path
}
function Get-Command {
    [CmdletBinding()]
    param($Name)
    if ($Name -eq 'Start-BitsTransfer') {
        if ($fixture.Engine -eq 'bits') { return [pscustomobject]@{ Name = $Name } }
        return
    }
    Microsoft.PowerShell.Core\Get-Command -Name $Name
}
function Write-FixtureDownload {
    param($Destination, [bool]$Resume)
    Record-Call "transfer:$($fixture.Engine):resume=$Resume"
    $bytes = [IO.File]::ReadAllBytes((Join-Path $fixtureRoot 'remote.msix'))
    $offset = 0
    if ($Resume -and (Test-Path -LiteralPath $Destination)) { $offset = (Get-Item -LiteralPath $Destination).Length }
    $mode = if ($Resume) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
    $stream = [IO.File]::Open($Destination, $mode)
    try {
        $count = $bytes.Length - $offset
        if ($fixture.TransferFails) { $count = [int]($count / 2) }
        $stream.Write($bytes, $offset, $count)
    } finally { $stream.Dispose() }
    if ($fixture.TransferFails) { throw 'fixture interrupted transfer' }
}
$script:originalFixtureTransfer = ${function:Write-FixtureDownload}
function Write-FixtureDownload {
    param($Destination, [bool]$Resume)
    Record-Call 'stage:transfer:start'
    try {
        try { & $script:originalFixtureTransfer -Destination $Destination -Resume:$Resume }
        finally {
            if ($fixture.PSObject.Properties['SecondUnrelated'] -and $fixture.SecondUnrelated -and $env:CHATGPT_DOWNLOAD_RUN_NUMBER -eq '2') {
                throw (New-Object InvalidOperationException('fixture unrelated second-run exception'))
            }
        }
        Record-Call 'stage:transfer:complete'
    } catch { Record-Call 'stage:transfer:failed'; throw }
}
# A function whose name is the absolute curl path intercepts native execution on all hosts.
Set-Item -LiteralPath ("Function:global:" + $script:curlPath) -Value {
    param([Parameter(ValueFromRemainingArguments=$true)]$CurlArguments)
    $index = [array]::IndexOf($CurlArguments, '-o')
    Write-FixtureDownload -Destination $CurlArguments[$index + 1] -Resume:($CurlArguments -contains '-C')
    $global:LASTEXITCODE = 0
}
function Start-BitsTransfer {
    [CmdletBinding()]
    param($Source, $Destination, $Description)
    Write-FixtureDownload -Destination $Destination -Resume:$false
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    if ($Uri -like '*License.xml') {
        Record-Call 'license'
        if ($fixture.LicenseFails) { [IO.File]::WriteAllText($OutFile, '<License'); throw 'fixture license unavailable' }
        $content = if ($fixture.LicenseMalformed) { '<License' } else { '<License/>' }
        [IO.File]::WriteAllText($OutFile, $content)
    } else { Write-FixtureDownload -Destination $OutFile -Resume:$false }
}
function Get-AuthenticodeSignature {
    param($FilePath)
    Record-Call 'signature'
    $hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    $status = if ($fixture.TrustedHashes -contains $hash) { 'Valid' } else { 'HashMismatch' }
    [pscustomobject]@{
        Status = $status
        SignerCertificate = [pscustomobject]@{ Subject = $fixture.Signer; Issuer = 'Fixture CA' }
    }
}
'@
        [IO.File]::WriteAllText((Join-Path $scripts 'common.ps1'), $common, (New-Object Text.UTF8Encoding($true)))
        $results = @(); $calls = @()
        for ($run = 0; $run -lt $Runs; $run++) {
            $runId = [guid]::NewGuid().ToString('N')
            $runDir = Join-Path $tempDir ('runs/run-{0:D2}-{1}' -f ($run + 1), $runId)
            $runScripts = Join-Path $runDir 'scripts'
            $null = New-Item -ItemType Directory -Path $runScripts -Force
            Copy-Item -LiteralPath (Join-Path $scripts 'common.ps1'), (Join-Path $scripts 'download-chatgpt-msix.ps1') -Destination $runScripts
            Copy-Item -LiteralPath $remote -Destination $runDir
            $runScenario = $defaults.Clone(); $runScenario.RunId = $runId; $runScenario.RunNumber = $run + 1
            [IO.File]::WriteAllText((Join-Path $runDir 'scenario.json'), ($runScenario | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($true)))
            $child = Invoke-TestChild -HostExe $hostExe -EntryPath (Join-Path $runScripts 'download-chatgpt-msix.ps1') -Arguments (@('-Arch','x64','-OutDir',$outDir,'-NoPause') + $Arguments) -Environment @{ CHATGPT_DOWNLOAD_RUN_NUMBER = [string]($run + 1) }
            $runCalls = @(); $friendlyErrors = @()
            $callsPath = Join-Path $runDir 'calls.jsonl'
            if ([IO.File]::Exists($callsPath)) { $runCalls = @([IO.File]::ReadAllLines($callsPath) | ForEach-Object { $_ | ConvertFrom-Json }) }
            $errorsPath = Join-Path $runDir 'errors.json'
            if ([IO.File]::Exists($errorsPath)) { $friendlyErrors = @([IO.File]::ReadAllText($errorsPath) | ConvertFrom-Json) }
            foreach ($errorDetail in $child.Errors) {
                $errorDetail | Add-Member -NotePropertyName RunId -NotePropertyValue $runId
                $errorDetail | Add-Member -NotePropertyName Source -NotePropertyValue 'ChildRunner'
                $stage = if ($runCalls.Count -gt 0) { $runCalls[-1].Value } else { 'initialization' }
                $errorDetail | Add-Member -NotePropertyName Stage -NotePropertyValue $stage
            }
            $runResult = [pscustomobject]@{ RunId = $runId; RunNumber = $run + 1; Code = $child.Code; ProcessCode = $child.ProcessCode; Output = $child.Output; Errors = @($child.Errors) + $friendlyErrors; Calls = $runCalls; Files = @(Get-ChildItem -LiteralPath $outDir | Select-Object -ExpandProperty Name); NativeStdout = $child.NativeStdout; NativeStderr = $child.NativeStderr }
            [IO.File]::WriteAllText((Join-Path $runDir 'result.json'), ($runResult | ConvertTo-Json -Depth 24), (New-Object Text.UTF8Encoding($true)))
            $results += $runResult
            $calls += @($runCalls | ForEach-Object { $_.Value })
        }
        $hash = ''
        if (Test-Path -LiteralPath $local) { $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash }
        $result = [pscustomobject]@{
            Runs = $results; Calls = $calls; Hash = $hash; RemoteHash = $remoteHash; OriginalHash = $originalHash
            LicenseContent = if (Test-Path -LiteralPath (Join-Path $outDir 'ChatGPT-License.xml')) { [IO.File]::ReadAllText((Join-Path $outDir 'ChatGPT-License.xml')) } else { '' }
            Files = @(Get-ChildItem -LiteralPath $outDir | Select-Object -ExpandProperty Name)
        }
        $script:lastFixtureDiagnostic = $result
        if ($EvidenceDir) {
            $null = New-Item -ItemType Directory -Path $EvidenceDir -Force
            $fixtureEvidence = Join-Path $EvidenceDir ('download-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $fixtureEvidence
            [IO.File]::WriteAllText((Join-Path $fixtureEvidence 'result.json'), ($result | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($true)))
            Copy-Item -LiteralPath (Join-Path $tempDir 'runs') -Destination $fixtureEvidence -Recurse
            foreach ($file in @('scenario.json','remote.msix')) {
                $source = Join-Path $tempDir $file
                if ([IO.File]::Exists($source)) { Copy-Item -LiteralPath $source -Destination $fixtureEvidence }
            }
            Copy-Item -LiteralPath (Join-Path $scripts 'common.ps1'), (Join-Path $scripts 'download-chatgpt-msix.ps1') -Destination $fixtureEvidence
        }
        return $result
    } finally { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}

Test-Case 'rolling URL cannot concatenate an older prefix with the current package' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'partial-old' }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
    Assert-True (-not ($r.Calls -contains 'transfer:curl:resume=True')) 'unconditional resume was used'
}

Test-Case 'same-size corrupt package is replaced automatically on an ordinary rerun' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'same-size-corrupt' }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
}
Test-Case 'same-size package with a bad signature is replaced automatically' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'signature-corrupt' }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
}
Test-Case 'verified local package can be reused without a package transfer' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'valid' }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
    Assert-True (@($r.Calls | Where-Object { $_ -like 'transfer:*' }).Count -eq 0) 'valid package was redownloaded'
    Assert-True ($r.Calls -contains 'signature') 'existing package signature was not checked'
}
Test-Case 'Force refreshes a verified local package' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'valid' } -Arguments @('-Force')
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
    Assert-True (@($r.Calls | Where-Object { $_ -like 'transfer:*' }).Count -eq 1) 'Force did not refresh the package'
}
Test-Case 'unavailable HEAD restarts an old fragment safely' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'partial-old'; HeadFails = $true }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
    Assert-True (-not ($r.Calls -contains 'transfer:curl:resume=True')) 'HEAD failure used unconditional resume'
}
foreach ($engine in @('bits', 'webrequest')) {
    Test-Case "$engine fallback replaces an old fragment with a complete package" {
        $r = Invoke-DownloadFixture -Scenario @{ Existing = 'partial-old'; Engine = $engine }
        Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
        Assert-True ($r.Calls -contains "transfer:${engine}:resume=False") 'expected fallback was not exercised'
    }
}
Test-Case 'interrupted transfers cannot publish partial MSIX files and reruns retry' {
    $r = Invoke-DownloadFixture -Scenario @{ TransferFails = $true } -Runs 2
    Assert-ExpectedDownloadFailure $r 'transfer'
}
Test-Case 'changed size between HEAD and GET fails safely and ordinary reruns retry' {
    $r = Invoke-DownloadFixture -Scenario @{ SizeDelta = 10 } -Runs 2
    Assert-ExpectedDownloadFailure $r 'size'
}
Test-Case 'failed signature validation discards download and ordinary reruns retry' {
    $r = Invoke-DownloadFixture -Scenario @{ RemoteInvalid = $true } -Runs 2
    Assert-ExpectedDownloadFailure $r 'signature'
}
foreach ($case in @(
    @{ Name = 'package name'; Scenario = @{ Name = 'Other.Package' } },
    @{ Name = 'manifest publisher'; Scenario = @{ Publisher = 'CN=Other' } },
    @{ Name = 'signer subject'; Scenario = @{ Signer = 'CN=Other' } },
    @{ Name = 'architecture'; Scenario = @{ Architecture = 'arm64' } }
)) {
    Test-Case "Force cannot accept the wrong $($case.Name)" {
        $r = Invoke-DownloadFixture -Scenario $case.Scenario -Arguments @('-Force')
        $expected = if ($case.Name -eq 'architecture') { '架构不符' } elseif ($case.Name -eq 'signer subject') { '数字签名' } else { '身份不受信任' }
        Assert-True ($r.Runs[0].Code -ne 0 -and $r.Runs[0].Output -match $expected) "wrong trust failure: $($r.Runs[0].Output)"
        Assert-True ($r.Files.Count -eq 0) "untrusted package was published: $($r.Files -join ', ')"
    }
}
foreach ($kind in @('transfer', 'size', 'signature', 'head')) {
    Test-Case "failed $kind refresh preserves the previous trusted package" {
        $scenario = @{ Existing = 'valid-old' }
        switch ($kind) {
            'transfer' { $scenario.TransferFails = $true }
            'size' { $scenario.SizeDelta = 10 }
            'signature' { $scenario.RemoteInvalid = $true }
            'head' { $scenario.HeadFails = $true; $scenario.TransferFails = $true }
        }
        $refreshArguments = @()
        if ($kind -ne 'head') { $refreshArguments = @('-Force') }
        $r = Invoke-DownloadFixture -Scenario $scenario -Arguments $refreshArguments
        $expected = @{ transfer = 'fixture interrupted transfer'; head = 'fixture interrupted transfer'; size = '文件大小不符'; signature = '数字签名' }[$kind]
        Assert-True ($r.Runs[0].Code -eq 1 -and $r.Runs[0].ProcessCode -eq 1 -and $r.Runs[0].Output -match $expected) 'refresh did not reach the expected failure'
        Assert-True (@($r.Calls | Where-Object { $_ -like 'transfer:*' }).Count -eq 1) 'refresh did not perform exactly one transfer'
        Assert-True ($r.OriginalHash -and $r.Hash -eq $r.OriginalHash -and $r.Hash -ne $r.RemoteHash) 'failed refresh lost or replaced the old package'
        Assert-True ($r.Files.Count -eq 1 -and $r.Files[0] -eq 'ChatGPT-x64.msix') 'failed refresh left temporary output'
    }
}
Test-Case 'successful refresh replaces the previous trusted package' {
    $r = Invoke-DownloadFixture -Scenario @{ Existing = 'valid-old' } -Arguments @('-Force')
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash -and $r.Hash -ne $r.OriginalHash) $r.Runs[0].Output
}
foreach ($fault in @('LicenseFails', 'LicenseMalformed')) {
    foreach ($existing in @('', '<License ID="previous"/>')) {
        Test-Case "$fault preserves the old license or leaves it absent (existing=$([bool]$existing))" {
            $scenario = @{ ExistingLicense = $existing }; $scenario[$fault] = $true
            $r = Invoke-DownloadFixture -Scenario $scenario
            Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
            Assert-True ($r.LicenseContent -eq $existing) 'license failure published partial XML or replaced the old license'
            $expectedCount = if ($existing) { 2 } else { 1 }
            Assert-True ($r.Files.Count -eq $expectedCount) 'license failure left temporary output'
        }
    }
}
Test-Case 'successful license refresh replaces the old XML' {
    $r = Invoke-DownloadFixture -Scenario @{ ExistingLicense = '<License ID="previous"/>' }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.LicenseContent -eq '<License/>') $r.Runs[0].Output
}
Test-Case 'license lookup rejects existing partial XML and unexpected roots' {
    . (Join-Path $SourceRoot 'scripts/common.ps1')
    $path = Join-Path ([IO.Path]::GetTempPath()) ($([guid]::NewGuid().ToString('N')) + '.xml')
    try {
        foreach ($content in @('<License', '<html/>', '', '<License/>')) {
            [IO.File]::WriteAllText($path, $content)
            $license = Get-LicensePath -Path $path
            Assert-True ([bool]$license -eq ($content -eq '<License/>')) "incorrect license selection for '$content'"
        }
    } finally { Remove-Item -LiteralPath $path -Force }
}
Test-Case 'optional license failure keeps the verified package usable' {
    $r = Invoke-DownloadFixture -Scenario @{ LicenseFails = $true }
    Assert-True ($r.Runs[0].Code -eq 0 -and $r.Hash -eq $r.RemoteHash) $r.Runs[0].Output
}

Test-Case 'initialization diagnostics retain nested errors and cannot masquerade as signature failure' {
    $r = Invoke-DownloadFixture -Scenario @{ InitFails = $true }
    $details = $r.Runs[0].Errors | ConvertTo-Json -Depth 16
    Assert-True ($r.Runs[0].Code -ne 0 -and $r.Runs[0].ProcessCode -ne 0) 'initialization fault reported success'
    Assert-True ($details -match 'InvalidOperationException' -and $details -match 'IOException' -and $details -match 'fixture dependency failure' -and $details -match 'common.ps1') 'initialization exception details missing'
    Assert-True ($r.Runs[0].Output -notmatch '数字签名' -and $r.Calls.Count -eq 0) 'setup failure reached or impersonated download validation'
}
foreach ($kind in @('transfer','size','signature')) {
    Test-Case "retry assertion rejects unrelated second-run exception after $kind failure" {
        $scenario = @{ SecondUnrelated = $true }
        switch ($kind) { 'transfer' { $scenario.TransferFails = $true }; 'size' { $scenario.SizeDelta = 10 }; 'signature' { $scenario.RemoteInvalid = $true } }
        $r = Invoke-DownloadFixture -Scenario $scenario -Runs 2
        Assert-True ($r.Runs[1].Code -eq 1 -and ($r.Runs[1].Errors | ConvertTo-Json -Depth 20) -match 'fixture unrelated second-run exception') 'negative fixture did not inject the unrelated second error'
        $detected = $false
        try { Assert-ExpectedDownloadFailure $r $kind } catch { $detected = $true }
        Assert-True $detected 'unrelated second-run exception impersonated the expected retry failure'
    }
    Test-Case "retry assertion distinguishes a different real second failure after $kind" {
        $secondKind = @{ transfer = 'size'; size = 'signature'; signature = 'transfer' }[$kind]
        $scenario = @{ SecondFailureKind = $secondKind }
        switch ($kind) { 'transfer' { $scenario.TransferFails = $true }; 'size' { $scenario.SizeDelta = 10 }; 'signature' { $scenario.RemoteInvalid = $true } }
        $r = Invoke-DownloadFixture -Scenario $scenario -Runs 2
        $secondExpected = @{ transfer = 'fixture interrupted transfer'; size = '文件大小不符'; signature = '数字签名' }[$secondKind]
        Assert-True ($r.Runs[1].Code -eq 1 -and ($r.Runs[1].Errors | ConvertTo-Json -Depth 20) -match $secondExpected) 'different real failure was not exercised'
        $detected = $false
        try { Assert-ExpectedDownloadFailure $r $kind } catch { $detected = $true }
        Assert-True $detected 'two different real failures were treated as the same retry protection'
    }
    Test-Case "ordinary retry recovers after the $kind fault is removed" {
        $scenario = @{ SecondFailureKind = 'none' }
        switch ($kind) { 'transfer' { $scenario.TransferFails = $true }; 'size' { $scenario.SizeDelta = 10 }; 'signature' { $scenario.RemoteInvalid = $true } }
        $r = Invoke-DownloadFixture -Scenario $scenario -Runs 2
        $firstExpected = @{ transfer = 'fixture interrupted transfer'; size = '文件大小不符'; signature = '数字签名' }[$kind]
        Assert-True ($r.Runs[0].Code -eq 1 -and ($r.Runs[0].Errors | ConvertTo-Json -Depth 20) -match $firstExpected -and $r.Runs[0].Files.Count -eq 0) 'first run did not fail at the intended boundary'
        Assert-True ($r.Runs[1].Code -eq 0 -and $r.Runs[1].Errors.Count -eq 0 -and $r.Hash -eq $r.RemoteHash) 'valid retry did not recover or inherited a stale error'
        Assert-True (@($r.Runs[1].Calls | Where-Object { $_.Value -like 'transfer:*' -and $_.RunId -eq $r.Runs[1].RunId }).Count -eq 1) 'successful retry did not own exactly one new transfer'
    }
    Test-Case "second initialization failure cannot inherit previous $kind diagnostics" {
        $scenario = @{ SecondInitFails = $true }
        switch ($kind) { 'transfer' { $scenario.TransferFails = $true }; 'size' { $scenario.SizeDelta = 10 }; 'signature' { $scenario.RemoteInvalid = $true } }
        $r = Invoke-DownloadFixture -Scenario $scenario -Runs 2
        $expected = @{ transfer = 'fixture interrupted transfer'; size = '文件大小不符'; signature = '数字签名' }[$kind]
        $first = $r.Runs[0].Errors | ConvertTo-Json -Depth 20
        $second = $r.Runs[1].Errors | ConvertTo-Json -Depth 20
        Assert-True ($first -match $expected -and $second -match 'fixture second initialization failure') 'expected two distinct failures were not exercised'
        Assert-True ($second -notmatch $expected) 'second initialization diagnostics inherited the previous failure'
        Assert-True ($r.Runs[0].RunId -ne $r.Runs[1].RunId -and @($r.Runs[1].Errors | Where-Object { $_.RunId -ne $r.Runs[1].RunId }).Count -eq 0) 'diagnostic run ownership was lost'
        Assert-True ($r.Runs[1].Calls.Count -eq 0) 'initialization failure inherited previous transfer or validation calls'
    }
}
Write-Host "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
