# Run with: powershell -NoProfile -File tests\installer-regression.ps1
# Deployment scripts and the launcher run in child processes; Windows APIs are mocked.
param([string]$SourceRoot, [string]$EvidenceDir)
. (Join-Path $PSScriptRoot 'test-support.ps1')
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = if ($SourceRoot) { $SourceRoot } else { Split-Path -Parent $PSScriptRoot }
$hostExe = (Get-Process -Id $PID).Path
$failed = 0
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $script:lastInstallerDiagnostic = $null
        & $Body
        $script:passed++
        Write-Host "PASS $Name"
    } catch {
        $script:failed++
        Write-Host "FAIL $Name : $((Get-TestErrorDetails $_) | ConvertTo-Json -Depth 12 -Compress)"
        if ($script:lastInstallerDiagnostic) { Write-Host ($script:lastInstallerDiagnostic | ConvertTo-Json -Depth 24) }
    }
}

function Invoke-InstallerFixture {
    param(
        [hashtable]$Scenario = @{},
        [string[]]$Arguments = @(),
        [ValidateSet('install', 'uninstall', 'launch')][string]$Operation = 'install',
        [ValidateSet('install', 'uninstall')][string]$LaunchOperation = 'install',
        [switch]$CaptureResult
    )
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path (Join-Path $tempDir 'scripts') -Force
    try {
        Get-ChildItem (Join-Path $repo 'scripts') -Filter '*.ps1' |
            Copy-Item -Destination (Join-Path $tempDir 'scripts')
        $common = Get-Content (Join-Path $repo 'scripts/common.ps1') -Raw
        $common += "`n" + @'
$fixture = Get-Content (Join-Path $PSScriptRoot '../scenario.json') -Raw | ConvertFrom-Json
$script:state = [pscustomobject]@{
    Calls = @()
    Installed = $null
    Volume = $null
    Provisioned = $fixture.Provisioned
    ProvisionQueries = 0
}
$script:fixturePhase = 'setup'
function Record-Call {
    param($Name, $Value)
    $entry = [pscustomobject]@{ Name = $Name; Value = $Value; Pid = $PID; Phase = $script:fixturePhase; Frames = @() }
    if ($Name -eq 'DeletePath') {
        $entry.Frames = @(Get-PSCallStack | ForEach-Object { [pscustomobject]@{ Function = $_.FunctionName; File = $_.ScriptName; Line = $_.ScriptLineNumber } })
    }
    $script:state.Calls += $entry
    [IO.File]::AppendAllText((Join-Path $PSScriptRoot '../calls.jsonl'), (($entry | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '../result.json'), ($script:state | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding($true)))
}
if ($fixture.VolumeExists) {
    $script:state.Volume = [pscustomobject]@{
        PackageStorePath = 'D:\WindowsApps'
        IsOffline = $fixture.Offline
    }
}
function Assert-AppxHost {
    # Inject once in the launcher; the child must still reach its real SID boundary.
    if ($env:CHATGPT_FIXTURE_CHILD -eq '1') {
        switch ($fixture.InjectBeforeIdentity) {
            'child-overwrite' {
                $path = Join-Path $env:USERPROFILE '.codex/fixture-cli-config'
                [IO.File]::WriteAllText($path, 'fixture-replaced')
                Record-Call 'ObservedChildContent' ([IO.File]::ReadAllText($path))
            }
            'child-volume' { $null = Add-AppxVolume -Path 'D:\FixtureOnlyWindowsApps' }
        }
        return
    }
    switch ($fixture.InjectBeforeIdentity) {
        'data' { Remove-Item -LiteralPath (Join-Path $env:USERPROFILE '.codex') -Recurse -Force }
        'raw-data' {
            $path = Join-Path $env:USERPROFILE '.codex/fixture-cli-config'
            [IO.File]::Delete($path)
            Record-Call 'RawDelete' $path
        }
        'package' { Remove-AppxPackage -Package 'fixture' }
        'service' { Stop-Service -Name 'fixture' -Force }
        'process' { Stop-Process -Id 987654 -Force }
    }
}
function Start-AppLog { param($Name) return 'fixture.log' }
function Stop-AppLog { }
function Test-IsAdmin { return $fixture.Admin }
function Get-SystemArch { return 'x64' }
function Get-OsBuild { return 22621 }
function Get-PSDrive {
    [CmdletBinding()]
    param($Name)
    $free = if ($Name -eq 'D') { $fixture.TargetFreeGB } else { $fixture.SystemFreeGB }
    [pscustomobject]@{ Free = $free * 1GB }
}
function Get-CimInstance {
    [CmdletBinding()]
    param($ClassName, $Filter)
    Record-Call 'DiskQuery' $Filter
    if (-not $fixture.DiskExists) { return }
    [pscustomobject]@{
        DeviceID = 'D:'
        DriveType = $fixture.DriveType
        FileSystem = $fixture.FileSystem
    }
}
function Test-Path {
    [CmdletBinding()]
    param($Path, $LiteralPath)
    if ($Path -and $Path -like 'HKLM:*') { return $false }
    if ($LiteralPath) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
    return Microsoft.PowerShell.Management\Test-Path -Path $Path
}
function Get-AppxVolume {
    [CmdletBinding()]
    param($Path)
    Record-Call 'GetVolume' $Path
    return $script:state.Volume
}
function Add-AppxVolume {
    [CmdletBinding()]
    param($Path)
    Record-Call 'AddVolume' $Path
    $script:state.Volume = [pscustomobject]@{ PackageStorePath = $Path; IsOffline = $false }
    return $script:state.Volume
}
function Move-AppxPackage {
    [CmdletBinding()]
    param($Package, $Volume)
    Record-Call 'Move' $Volume.PackageStorePath
    if ($fixture.MoveFails) { throw 'fixture: package cannot be moved' }
    if (-not $fixture.MoveIgnoresVolume) {
        $script:state.Installed.InstallLocation = 'D:\WindowsApps\OpenAI.Codex_fixture'
    }
    Record-Call 'Moved' $Package
}
function Add-AppxProvisionedPackage {
    [CmdletBinding()]
    param([switch]$Online, $PackagePath, $LicensePath, [switch]$SkipLicense)
    Record-Call 'Provision' $PackagePath
}
function Remove-AppxProvisionedPackage {
    [CmdletBinding()]
    param([switch]$Online, $PackageName, [switch]$AllUsers)
    Record-Call 'Deprovision' $PackageName
    if ($fixture.ProvisionRemoveError) {
        if ($fixture.ProvisionGoneAfterError) { $script:state.Provisioned = $false }
        throw '0x80070002 fixture: source file missing'
    }
    $script:state.Provisioned = $false
}
function Start-Sleep { param($Seconds) Record-Call 'Wait' $Seconds }
function Start-Process {
    [CmdletBinding()]
    param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru, $WorkingDirectory)
    Record-Call 'Launch' ([pscustomobject]@{ Wait = [bool]$Wait; PassThru = [bool]$PassThru; Verb = $Verb })
    $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
    Record-Call 'ChildCommand' $command
    switch ($fixture.ChildMode) {
        'cancel' { throw (New-Object ComponentModel.Win32Exception(1223)) }
        'killed' { return [pscustomobject]@{ ExitCode = 137 } }
        'no-result' { return [pscustomobject]@{ ExitCode = 0 } }
    }
    $childAst = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$null, [ref]$null)
    $childCall = $childAst.Find({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' }, $true)
    $childArguments = @()
    foreach ($element in $childCall.CommandElements | Select-Object -Skip 1) {
        if ($element -is [Management.Automation.Language.CommandParameterAst]) {
            $childArguments += ('-' + $element.ParameterName + $(if ($element.Argument) { ':' + $element.Argument.Extent.Text } else { '' }))
        } else { $childArguments += $element.Value }
    }
    $resultParameter = [array]::IndexOf($childArguments, '-ResultPath')
    Record-Call 'TaskScratch' (Split-Path -Parent $childArguments[$resultParameter + 1])
    $child = Invoke-TestChild -HostExe $fixture.HostExe -EntryPath $childCall.CommandElements[0].Value -Arguments $childArguments -Environment @{ CHATGPT_FIXTURE_CHILD = '1' }
    Write-Host $child.Output
    Record-Call 'ChildDiagnostic' $child
    $childCode = $child.Code
    $script:fixturePhase = 'launcher-finalize'
    if ($fixture.ChildMode -eq 'exit-mismatch') { $childCode = 137 }
    Record-Call 'ChildExit' $childCode
    return [pscustomobject]@{ ExitCode = $childCode }
}
$env:SystemDrive = 'C:'
$env:USERNAME = 'fixture'
$env:LOCALAPPDATA = Join-Path $PSScriptRoot '../appdata'
$env:USERPROFILE = Join-Path $PSScriptRoot '../profile'
Record-Call 'Start' $null
'@
        $common += "`n" + (Get-Content (Join-Path $PSScriptRoot 'test-support.ps1') -Raw)
        $common += "`n" + (Get-Content (Join-Path $PSScriptRoot 'risk-fixture.ps1') -Raw)
        # Windows PowerShell 5.1 requires a BOM for non-ASCII script content.
        [IO.File]::WriteAllText(
            (Join-Path $tempDir 'scripts/common.ps1'), $common, (New-Object Text.UTF8Encoding($true)))
        $defaults = @{
            Admin = $true; SystemFreeGB = 10; TargetFreeGB = 10
            DiskExists = $true; DriveType = 3; FileSystem = 'NTFS'
            VolumeExists = $true; Offline = $false; MoveFails = $false
            MoveIgnoresVolume = $false; InstallIgnoresVolume = $false
            ExistingVersion = ''; ExistingLocation = ''
            HasServices = $false; InstallError = ''
            Provisioned = $false; ProvisionRemoveError = $false; ProvisionGoneAfterError = $false
            ProvisionClearsAfterQueries = 0; ChildMode = 'run'; HostExe = $hostExe
            ManifestPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
            SignerSubject = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'; SignatureValid = $true
            ExistingPublisher = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
            ExistingFamily = 'OpenAI.Codex_2p2nqsd0c76g0'; ForeignPackage = $false
            RemoveError = $false; RemoveLeavesPackage = $false; PackageQueryFailsAfterRemoval = $false
            Processes = @(); ServiceExists = $false; ServiceDeleteCode = 0
            ServiceDeleteThrows = $false; ServiceRemains = $false; ServiceMarked = $false
            ServiceQueryFails = $false; ServiceQueryMode = 'normal'; ServiceQueryModeAfterRemoval = ''
            ServiceQueryCode = -1; ServiceQueryCodeAfterRemoval = -1; ServiceQueryThrows = $false
            ServiceDisappearsAfterRemoval = $false
            FirewallRules = @(); FirewallQueryFails = $false
            AccountSid = 'S-1-5-21-100'; ElevatedSid = ''; SupportsDowngrade = $true; InjectBeforeIdentity = ''
        }
        foreach ($key in $Scenario.Keys) { $defaults[$key] = $Scenario[$key] }
        $defaults | ConvertTo-Json | Set-Content (Join-Path $tempDir 'scenario.json')
        $package = Join-Path $tempDir "fixture's package.msix"
        $stream = [IO.File]::Create($package)
        $stream.SetLength(101MB)
        $stream.Dispose()
        $completionPath = Join-Path $tempDir 'completion.json'
        $entry = "scripts/$Operation-chatgpt-desktop.ps1"
        $entryArgs = @('-NoPause')
        if ($Operation -eq 'install' -or ($Operation -eq 'launch' -and $LaunchOperation -eq 'install')) {
            $entryArgs += @('-PackagePath', $package)
        }
        if ($Operation -eq 'launch') {
            $entryArgs += @('-Operation', $LaunchOperation)
            $CaptureResult = $true
        }
        if ($CaptureResult) { $entryArgs += @('-ResultPath', $completionPath) }
        $entryArgs += $Arguments
        $child = Invoke-TestChild -HostExe $hostExe -EntryPath (Join-Path $tempDir $entry) -Arguments $entryArgs
        $output = $child.Output; $code = $child.Code
        $state = $null
        $resultPath = Join-Path $tempDir 'result.json'
        if (Test-Path $resultPath) { $state = Get-Content $resultPath -Raw | ConvertFrom-Json }
        $completion = $null
        if (Test-Path $completionPath) { $completion = Get-Content $completionPath -Raw | ConvertFrom-Json }
        if ($state -and [IO.File]::Exists((Join-Path $tempDir 'calls.jsonl'))) {
            $state.Calls = @([IO.File]::ReadAllLines((Join-Path $tempDir 'calls.jsonl')) | ForEach-Object { $_ | ConvertFrom-Json })
        }
        $resources = @()
        if ($state -and $state.PSObject.Properties['Resources']) {
            $baselines = @($state.Calls | Where-Object { $_.Name -eq 'ResourceBaseline' })
            if ($baselines.Count -ne 1) { throw 'Fixture must record exactly one resource baseline before launching the application entry.' }
            $resources = @($baselines[0].Value | ForEach-Object {
                $exists = [IO.File]::Exists($_.Path)
                $afterHash = if ($exists) { (Get-FileHash -LiteralPath $_.Path -Algorithm SHA256).Hash } else { '' }
                $afterLength = if ($exists) { ([IO.FileInfo]$_.Path).Length } else { -1 }
                [pscustomobject]@{ Path = $_.Path; Exists = $exists; BeforeHash = $_.Sha256; AfterHash = $afterHash; BeforeLength = $_.Length; AfterLength = $afterLength }
            })
        }
        $result = [pscustomobject]@{ Code = $code; Output = $output; State = $state; Completion = $completion; Resources = $resources; Diagnostic = $child; Scenario = $defaults; Operation = $Operation; LaunchOperation = $LaunchOperation; Arguments = $Arguments }
        $script:lastInstallerDiagnostic = $result
        if ($EvidenceDir) {
            $null = New-Item -ItemType Directory -Path $EvidenceDir -Force
            [IO.File]::WriteAllText((Join-Path $EvidenceDir ('installer-' + [guid]::NewGuid().ToString('N') + '.json')), ($result | ConvertTo-Json -Depth 24), (New-Object Text.UTF8Encoding($true)))
        }
        return $result
    } finally {
        Remove-Item $tempDir -Recurse -Force
    }
}

function Get-Calls {
    param($Result, [string]$Name)
    if ($Result.State) { $Result.State.Calls | Where-Object { $_.Name -eq $Name } }
}

Test-Case 'install and uninstall never prefer pwsh' {
    foreach ($name in @('安装ChatGPT桌面版.bat', '卸载ChatGPT桌面版.bat')) {
        $text = Get-Content (Join-Path $repo $name) -Raw
        Assert-True ($text -notmatch '(?im)^\s*where\s+pwsh\b') "$name selects incompatible PowerShell 7 when installed"
        Assert-True ($text -match '(?im)^set "PS=.*WindowsPowerShell\\v1\.0\\powershell\.exe"') "$name must pin Windows PowerShell"
    }
}

if ($env:OS -eq 'Windows_NT') {
    Test-Case 'Windows launchers select Desktop even with pwsh on PATH' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tempDir
        $originalPath = $env:PATH
        try {
            Set-Content (Join-Path $tempDir 'pwsh.cmd') "@echo Core`r`n@exit /b 42" -Encoding ASCII
            $env:PATH = "$tempDir;$originalPath"
            foreach ($name in @('安装ChatGPT桌面版.bat', '卸载ChatGPT桌面版.bat')) {
                # Execute the actual host-selection statements without running UAC or deployment.
                $selection = Get-Content (Join-Path $repo $name) |
                    Where-Object { $_ -match '^set "PS=|^where pwsh\b|^if exist .* set "PS=' }
                $batch = Join-Path $tempDir 'select-host.bat'
                $body = @('@echo off') + $selection + @(
                    '"%PS%" -NoProfile -Command "$PSVersionTable.PSEdition; exit 0"'
                    'exit /b %errorlevel%'
                )
                Set-Content $batch $body -Encoding ASCII
                $native = Invoke-TestNative -FilePath $env:ComSpec -Arguments ('/d /c ""' + $batch + '""')
                $output = $native.Output
                Assert-True ($native.Code -eq 0 -and $output.Trim() -eq 'Desktop') "$name selected $output"
            }
        } finally {
            $env:PATH = $originalPath
            Remove-Item $tempDir -Recurse -Force
        }
    }
    Test-Case 'complete bat entries detect interrupted launchers and propagate failure' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path (Join-Path $tempDir 'scripts') -Force
        $originalMode = $env:CHATGPT_LAUNCHER_FIXTURE
        try {
            # Keep the real batch entry; replace only the delegated launcher with a harmless fixture.
            $stub = @'
param($Operation, $ResultPath, [switch]$NoPause, $PackagePath)
if (-not $NoPause -or $PackagePath -ne "C:\fixture's & ! [test]\package.msix") { exit 2 }
if ($env:CHATGPT_LAUNCHER_FIXTURE -eq 'killed') { exit 137 }
if ($env:CHATGPT_LAUNCHER_FIXTURE -eq 'no-result') { exit 0 }
$code = if ($env:CHATGPT_LAUNCHER_FIXTURE -eq 'failure') { 1 } else { 0 }
[IO.File]::WriteAllText($ResultPath, '{"ExitCode":' + $code + '}')
exit $code
'@
            [IO.File]::WriteAllText((Join-Path $tempDir 'scripts/launch-chatgpt-desktop.ps1'),
                $stub, (New-Object Text.UTF8Encoding($true)))
            foreach ($name in @('安装ChatGPT桌面版.bat', '卸载ChatGPT桌面版.bat')) {
                $batch = Join-Path $tempDir 'entry.bat'
                Copy-Item (Join-Path $repo $name) $batch -Force
                foreach ($mode in @('success', 'failure', 'killed', 'no-result')) {
                    $env:CHATGPT_LAUNCHER_FIXTURE = $mode
                    $command = "call `"$batch`" -NoPause -PackagePath `"C:\fixture's & ! [test]\package.msix`" <nul"
                    $native = Invoke-TestNative -FilePath $env:ComSpec -Arguments ('/d /v:off /c ' + $command)
                    $output = $native.Output; $code = $native.Code
                    if ($mode -eq 'success') {
                        Assert-True ($code -eq 0) "$name $mode : $output"
                    } else {
                        Assert-True ($code -ne 0 -and $output -match '\[X\]') "$name $mode was silent: $output"
                    }
                    if ($mode -in @('killed', 'no-result')) {
                        Assert-True ($output -match 'Could not confirm task completion') "$name lost missing-result warning: $output"
                    }
                }
            }
        } finally {
            $env:CHATGPT_LAUNCHER_FIXTURE = $originalMode
            Remove-Item $tempDir -Recurse -Force
        }
    }
} else {
    Write-Host 'SKIP cmd.exe host-selection and complete-batch execution (requires Windows)'
}

Test-Case 'direct script host check gives actionable PowerShell guidance' {
    . (Join-Path $repo 'scripts/common.ps1')
    $message = ''
    try { Assert-AppxHost } catch { $message = $_.Exception.Message }
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Assert-True (-not $message) "Windows PowerShell was rejected: $message"
    } else {
        Assert-True ($message -match 'powershell\.exe' -and $message -match '5\.1') 'Core host lacked retry instructions'
    }
}

Test-Case 'default install still provisions' {
    $r = Invoke-InstallerFixture
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'Install').Count -eq 1) 'default install was skipped'
    Assert-True (@(Get-Calls $r 'Provision').Count -eq 1) 'default provisioning was skipped'
}

Test-Case 'custom drive works with low system-drive space and skips provisioning' {
    $r = Invoke-InstallerFixture -Scenario @{ SystemFreeGB = 0.5 } -Arguments @('-InstallDrive', 'D:')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True ((Get-Calls $r 'Install').Value -eq 'D:') 'package was not installed on D:'
    Assert-True (@(Get-Calls $r 'Provision').Count -eq 0) 'provisioning ignored the custom drive'
}

Test-Case 'creates WindowsApps volume when needed' {
    $r = Invoke-InstallerFixture -Scenario @{ VolumeExists = $false } -Arguments @('-InstallDrive', 'D:\')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True ((Get-Calls $r 'AddVolume').Value -eq 'D:\WindowsApps') 'invalid Appx volume path'
}

Test-Case 'same-version installation moves to requested drive' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'
    } -Arguments @('-InstallDrive', 'D:')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'Move').Count -eq 1) 'same-version shortcut ignored drive change'
    Assert-True (@(Get-Calls $r 'Remove').Count -eq 0) 'move removed the existing package'
    Assert-True (@(Get-Calls $r 'Install').Count -eq 0) 'same-version move reinstalled package'
}

Test-Case 'upgrade moves existing package before installing on target drive' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '1.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'
    } -Arguments @('-InstallDrive', 'D:')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'Move').Count -eq 1) 'upgrade did not move existing package'
    Assert-True ((Get-Calls $r 'Install').Value -eq 'D:') 'upgrade installed on wrong drive'
}

foreach ($case in @(
    @{ Name = 'missing drive'; Scenario = @{ DiskExists = $false }; Message = '不存在' },
    @{ Name = 'non-NTFS drive'; Scenario = @{ FileSystem = 'exFAT' }; Message = 'NTFS' },
    @{ Name = 'network drive'; Scenario = @{ DriveType = 4 }; Message = '固定磁盘' },
    @{ Name = 'full target drive'; Scenario = @{ TargetFreeGB = 0.5 }; Message = '磁盘空间不足' },
    @{ Name = 'offline volume'; Scenario = @{ Offline = $true }; Message = '离线状态' },
    @{ Name = 'non-admin volume creation'; Scenario = @{ Admin = $false; VolumeExists = $false }; Message = '管理员权限' }
)) {
    Test-Case "rejects $($case.Name) before changing installed package" {
        $scenario = $case.Scenario.Clone()
        $scenario.ExistingVersion = '3.0.0.0'
        $scenario.ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'
        $r = Invoke-InstallerFixture -Scenario $scenario -Arguments @('-InstallDrive', 'D:', '-Force')
        Assert-True ($r.Code -ne 0) 'invalid target accepted'
        Assert-True (@(Get-Calls $r 'DiskQuery').Count -eq 1) 'disk validation was not exercised'
        Assert-True ($r.Output -match $case.Message) "wrong failure: $($r.Output)"
        Assert-True (@(Get-Calls $r 'Remove').Count -eq 0) 'invalid target removed installed package'
        Assert-True (@(Get-Calls $r 'Install').Count -eq 0) 'invalid target triggered install'
    }
}

Test-Case 'move failure stops before upgrade or removal' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '1.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'; MoveFails = $true
    } -Arguments @('-InstallDrive', 'D:')
    Assert-True ($r.Code -ne 0) 'failed move reported success'
    Assert-True (@(Get-Calls $r 'Move').Count -eq 1) 'fixture never exercised move failure'
    Assert-True (@(Get-Calls $r 'Install').Count -eq 0) 'upgrade continued after failed move'
}

Test-Case 'rejects arbitrary directory before querying disks' {
    $r = Invoke-InstallerFixture -Arguments @('-InstallDrive', 'D:\Custom Apps')
    Assert-True ($r.Code -ne 0 -and $r.Output -match '安装盘格式无效') $r.Output
    Assert-True (@(Get-Calls $r 'DiskQuery').Count -eq 0) 'invalid path reached disk query'
}

Test-Case 'same-version package already on target drive does not move or reinstall' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'D:\WindowsApps\OpenAI.Codex_fixture'
    } -Arguments @('-InstallDrive', 'd:')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'Move').Count -eq 0) 'unnecessary package move'
    Assert-True (@(Get-Calls $r 'Install').Count -eq 0) 'unnecessary reinstall'
}

Test-Case 'detects install command ignoring target volume' {
    $r = Invoke-InstallerFixture -Scenario @{ InstallIgnoresVolume = $true } -Arguments @('-InstallDrive', 'D:')
    Assert-True ($r.Code -ne 0 -and $r.Output -match '安装位置不在指定盘') $r.Output
}

Test-Case 'detects migration command leaving package on original drive' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'; MoveIgnoresVolume = $true
    } -Arguments @('-InstallDrive', 'D:')
    Assert-True ($r.Code -ne 0 -and $r.Output -match '应用位置未变更') $r.Output
}

Test-Case 'packaged-service permission error has actionable guidance' {
    $r = Invoke-InstallerFixture -Scenario @{ Admin = $false; InstallError = 'HRESULT: 0x80073D28' }
    Assert-True ($r.Code -eq 1 -and $r.Output -match '管理员' -and $r.Output -match '\.bat') $r.Output
}

Test-Case 'service manifest stops non-admin before deployment' {
    $r = Invoke-InstallerFixture -Scenario @{ Admin = $false; HasServices = $true }
    Assert-True ($r.Code -eq 1 -and $r.Output -match '0x80073D28') $r.Output
    Assert-True (@(Get-Calls $r 'Install').Count -eq 0) 'service package reached non-admin deployment'
}

Test-Case 'legacy package without services can still install per user' {
    $r = Invoke-InstallerFixture -Scenario @{ Admin = $false }
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'Install').Count -eq 1) 'legacy user install rejected'
}

Test-Case 'real manifest parser detects packaged services across namespaces' {
    . (Join-Path $repo 'scripts/common.ps1')
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).msix"
    try {
        foreach ($extension in @('', '<desktop6:Extension Category="windows.service"><desktop6:Service Name="Fixture"/></desktop6:Extension>')) {
            $zip = [IO.Compression.ZipFile]::Open($tempFile, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $zip.CreateEntry('AppxManifest.xml')
                $writer = New-Object IO.StreamWriter($entry.Open())
                try {
                    $writer.Write(('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6"><Identity Name="OpenAI.Codex" Version="2.0.0.0" ProcessorArchitecture="x64" Publisher="fixture"/><Properties><DisplayName>Fixture</DisplayName></Properties><Applications><Application><Extensions>{0}</Extensions></Application></Applications></Package>' -f $extension))
                } finally { $writer.Dispose() }
            } finally { $zip.Dispose() }
            $info = Get-MsixInfo -Path $tempFile
            Assert-True ($info.RequiresAdmin -eq [bool]$extension) 'manifest service detection was wrong'
            Remove-Item $tempFile
        }
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
    }
}

Test-Case 'deprovisions before removing all-user package and verifies all users' {
    $r = Invoke-InstallerFixture -Operation uninstall -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\fixture'; Provisioned = $true
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0) $r.Output
    $calls = @($r.State.Calls.Name)
    Assert-True ([array]::IndexOf($calls, 'Deprovision') -lt [array]::IndexOf($calls, 'Remove')) 'package removed before deprovisioning'
    Assert-True (@(Get-Calls $r 'QueryProvision').Count -ge 2) 'no final provisioning query'
    Assert-True (@(Get-Calls $r 'QueryPackages' | Where-Object { $_.Value -eq $false }).Count -eq 0) 'final check ignored other users'
}

Test-Case 'provision race is judged from final state instead of stale error' {
    $r = Invoke-InstallerFixture -Operation uninstall -Scenario @{
        ExistingVersion = '2.0.0.0'; Provisioned = $true
        ProvisionRemoveError = $true; ProvisionGoneAfterError = $true
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True ($r.Output -notmatch '未完成:.*整机预置') $r.Output
    Assert-True (@(Get-Calls $r 'QueryProvision').Count -ge 2) 'race was not rechecked'
}

Test-Case 'persistent provisioning residue returns failure even with no installed package' {
    $r = Invoke-InstallerFixture -Operation uninstall -Scenario @{
        Provisioned = $true; ProvisionRemoveError = $true
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 1 -and $r.Output -match '未完成:.*整机预置') $r.Output
    Assert-True (@(Get-Calls $r 'QueryProvision').Count -ge 3) 'residual provisioning not checked twice'
}

Test-Case 'delayed provisioning cleanup succeeds after one recheck' {
    $r = Invoke-InstallerFixture -Operation uninstall -Scenario @{
        Provisioned = $true; ProvisionRemoveError = $true; ProvisionClearsAfterQueries = 2
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'QueryProvision').Count -eq 3) 'pending provisioning state was not rechecked'
}

foreach ($operation in @('install', 'uninstall')) {
    Test-Case "$operation writes completion marker on early successful return" {
        $scenario = if ($operation -eq 'install') {
            @{ ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\fixture' }
        } else { @{} }
        $r = Invoke-InstallerFixture -Operation $operation -Scenario $scenario -CaptureResult
        Assert-True ($r.Code -eq 0 -and $null -ne $r.Completion) $r.Output
        Assert-True ($r.Completion.ExitCode -eq 0 -and $r.Completion.Operation -eq $operation) 'incorrect completion marker'
    }
}

Test-Case 'failed install writes exit code and log location' {
    $r = Invoke-InstallerFixture -Scenario @{ InstallError = 'HRESULT: 0x80073D28' } -CaptureResult
    Assert-True ($r.Code -eq 1 -and $null -ne $r.Completion) $r.Output
    Assert-True ($r.Completion.ExitCode -eq 1 -and $r.Completion.LogPath -eq 'fixture.log') 'failure marker lost diagnostics'
}

Test-Case 'launcher waits for elevated task and preserves quoted package paths' {
    $r = Invoke-InstallerFixture -Operation launch -Scenario @{ Admin = $false }
    Assert-True ($r.Code -eq 0 -and $null -ne $r.Completion) $r.Output
    $call = Get-Calls $r 'Launch'
    Assert-True ($call.Value.Wait -and $call.Value.PassThru -and $call.Value.Verb -eq 'RunAs') 'elevated process was not awaited'
    Assert-True ($r.Completion.ExitCode -eq 0) 'launcher did not confirm child result'
    Assert-True ($r.Output -match '安装成功') 'quoted package path did not reach child installer'
}

Test-Case 'launcher forwards uninstall switches to real child script' {
    $r = Invoke-InstallerFixture -Operation launch -LaunchOperation uninstall -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\fixture'; Provisioned = $true
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0 -and $null -ne $r.Completion) $r.Output
    Assert-True ($r.Completion.Operation -eq 'uninstall' -and $r.Output -match '卸载完成') $r.Output
}

foreach ($mode in @('killed', 'no-result', 'exit-mismatch')) {
    Test-Case "launcher reports $mode instead of silent success" {
        $r = Invoke-InstallerFixture -Operation launch -Scenario @{ Admin = $false; ChildMode = $mode }
        Assert-True ($r.Code -eq 1 -and $r.Output -match '未能确认|退出码不一致') $r.Output
        Assert-True ($null -ne $r.Completion -and $r.Completion.ExitCode -eq 1) 'launcher failure was not recorded'
    }
}

Test-Case 'launcher propagates application failure and cancellation' {
    $r = Invoke-InstallerFixture -Operation launch -Scenario @{ InstallError = 'HRESULT: 0x80073D28' }
    Assert-True ($r.Code -eq 1 -and $r.Output -match 'fixture.log') $r.Output
    $r = Invoke-InstallerFixture -Operation launch -Scenario @{ Admin = $false; ChildMode = 'cancel' }
    Assert-True ($r.Code -eq 1 -and $r.Output -match '取消|1223') $r.Output
}

Test-Case 'default uninstall explains Windows data removal instead of promising login preservation' {
    $r = Invoke-InstallerFixture -Operation uninstall -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\fixture'
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True ($r.Output -match 'Windows' -and $r.Output -match '登录状态不保证保留') $r.Output
    Assert-True ($r.Output -notmatch '重装后可直接继续使用') 'uninstall still promises preserved login'
}

. (Join-Path $PSScriptRoot 'risk-regression.ps1')

Write-Host "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
