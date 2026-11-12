# Loaded by installer-regression.ps1; fixtures run real entry scripts in isolated child processes.
Test-Case 'R1 kills only processes inside the verified package directory' {
    $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'
        Processes = @(
            @{ Name = 'chrome_proxy'; Id = 101; Path = 'C:\Chrome\chrome_proxy.exe' },
            @{ Name = 'codex'; Id = 102; Path = 'C:\Users\A\bin\codex.exe' },
            @{ Name = 'extension-host'; Id = 103; Path = 'C:\WindowsApps\OpenAI.Codex_fixture\app\extension-host.exe' },
            @{ Name = 'ChatGPT'; Id = 104; Path = $null },
            @{ Name = 'codex'; Id = 105; Path = 'C:\WindowsApps\OpenAI.Codex_fixture-other\codex.exe' },
            @{ Name = 'codex'; Id = 106; Path = 'C:\WindowsApps\OpenAI.Codex_fixture\..\Other\codex.exe' }
        )
    }
    Assert-True ($r.Code -eq 0) $r.Output
    $ids = @(Get-Calls $r 'Kill' | ForEach-Object { $_.Value })
    Assert-True ($ids.Count -eq 1 -and $ids[0] -eq 103) "unrelated/unknown process killed: $ids"
}
foreach ($case in @(
    @{ RemoveError = $true }, @{ RemoveLeavesPackage = $true }, @{ PackageQueryFailsAfterRemoval = $true }
)) {
    Test-Case "R2 failed/unconfirmed removal preserves service and aliases ($($case.Keys))" {
        $s = $case.Clone(); $s.ExistingVersion = '2.0.0.0'; $s.ServiceExists = $true
        $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force', '-RemoveCliConfig', '-CleanFirewall') -Scenario $s -CaptureResult
        Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) 'failed removal reported success'
        Assert-True (@(Get-Calls $r 'Remove').Count -eq 1) 'package removal branch not reached'
        Assert-True (@(Get-Calls $r 'StopService').Count -eq 0 -and @(Get-Calls $r 'ServiceCommand').Count -eq 0) 'live package service was modified'
        Assert-True (@(Get-Calls $r 'DeletePath' | Where-Object { $_.Value -match 'WindowsApps|\.codex' }).Count -eq 0) 'live package aliases/data were removed'
        Assert-True (@(Get-Calls $r 'FirewallQuery').Count -eq 0) 'cleanup continued after unconfirmed removal'
    }
}
Test-Case 'R3 failed downgrade retains original registration without pre-uninstall' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '3.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'; InstallError = 'fixture: deployment failed'
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 1) 'deployment error was ignored'
    Assert-True (@(Get-Calls $r 'Install').Count -eq 1) 'failure was not exercised'
    Assert-True (@(Get-Calls $r 'Remove').Count -eq 0) 'downgrade uninstalled the original application'
    Assert-True ($r.State.Installed.Version -eq '3.0.0.0') 'old application was lost on failure'
    Assert-True ((Get-Calls $r 'DowngradeFlag').Value -eq $true) 'in-place downgrade flag missing'
}
Test-Case 'R3 unsupported in-place downgrade refuses before volume creation or mutation' {
    $r = Invoke-InstallerFixture -Scenario @{
        ExistingVersion = '3.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'
        SupportsDowngrade = $false; VolumeExists = $false
    } -Arguments @('-Force', '-InstallDrive', 'D:')
    Assert-True ($r.Code -eq 1 -and $r.Output -match 'ForceUpdateFromAnyVersion') $r.Output
    foreach ($name in @('Remove', 'Move', 'Install', 'AddVolume')) {
        Assert-True (@(Get-Calls $r $name).Count -eq 0) "unsupported downgrade mutated $name"
    }
}
Test-Case 'R3 successful downgrade uses deployment API and skips machine provisioning' {
    $r = Invoke-InstallerFixture -Scenario @{ ExistingVersion = '3.0.0.0' } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True ((Get-Calls $r 'DowngradeFlag').Value -eq $true) 'missing downgrade API option'
    Assert-True (@(Get-Calls $r 'Remove').Count -eq 0) 'successful downgrade pre-uninstalled package'
    Assert-True (@(Get-Calls $r 'Provision').Count -eq 0) 'downgrade attempted unsupported provisioning downgrade'
}
foreach ($s in @(
    @{ ManifestPublisher = 'CN=Other' },
    @{ SignerSubject = 'CN=Other' },
    @{ ManifestPublisher = 'CN=Other'; SignerSubject = 'CN=Other' },
    @{ SignatureValid = $false }
)) {
    Test-Case "R4 Force cannot bypass identity/signature boundary ($($s.Keys))" {
        $r = Invoke-InstallerFixture -Scenario $s -Arguments @('-Force')
        Assert-True ($r.Code -eq 1) 'untrusted package was accepted with Force'
        Assert-True (@(Get-Calls $r 'Install').Count -eq 0) 'untrusted package reached deployment'
        Assert-True (@(Get-Calls $r 'Provision').Count -eq 0) 'untrusted package reached provisioning'
    }
}
Test-Case 'R4 installed-package lookup excludes foreign publisher and family' {
    foreach ($s in @(@{ ExistingPublisher = 'CN=Other' }, @{ ExistingFamily = 'OpenAI.Codex_foreign' })) {
        $s.ExistingVersion = '2.0.0.0'
        $r = Invoke-InstallerFixture -Scenario $s
        Assert-True ($r.Code -eq 0) $r.Output
        Assert-True (@(Get-Calls $r 'Install').Count -eq 1) 'same-name foreign package was treated as official existing install'
    }
    $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{ ForeignPackage = $true }
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'Remove').Count -eq 0) 'uninstall removed another publisher package'
}
function Assert-CrossAccountBoundary {
    param($Result)
    Assert-True ($Result.Code -eq 1 -and $Result.Completion.ExitCode -eq 1) 'SID refusal did not propagate'
    Assert-True (@(Get-Calls $Result 'SidGateRefused').Count -eq 1) 'SID refusal boundary was not exercised'
    $mutations = @($Result.State.Calls | Where-Object {
        $_.Name -in @('Install','Remove','Move','AddVolume','Provision','Deprovision','StopService','Kill','DeleteFirewall') -or
        ($_.Name -eq 'ServiceCommand' -and $_.Value -eq 'delete')
    })
    Assert-True ($mutations.Count -eq 0) ('cross-account target mutation: ' + ($mutations | ConvertTo-Json -Depth 12))
    Assert-True ($Result.Resources.Count -eq 4 -and @($Result.Resources | Where-Object {
        -not $_.Exists -or -not $_.BeforeHash -or $_.BeforeHash -ne $_.AfterHash -or $_.BeforeLength -ne $_.AfterLength
    }).Count -eq 0) 'cross-account application, CLI, package data or alias resource was removed or overwritten'
    foreach ($deletion in @(Get-Calls $Result 'DeletePath')) {
        $owners = @($Result.State.Calls | Where-Object {
            $_.Name -in @('TaskScratch','HarnessScratch') -and $_.Pid -eq $deletion.Pid -and
            [IO.Path]::GetFullPath([string]$_.Value) -eq [IO.Path]::GetFullPath([string]$deletion.Value)
        })
        $launcherFinally = $deletion.Phase -eq 'launcher-finalize' -and @($deletion.Frames | Where-Object { $_.File -match '[\\/]launch-chatgpt-desktop\.ps1$' }).Count -gt 0
        $harnessFinally = @($deletion.Frames | Where-Object { $_.Function -eq 'Invoke-TestChild' }).Count -gt 0
        Assert-True ($owners.Count -eq 1 -and ($launcherFinally -or $harnessFinally)) ('unexpected cross-account deletion: ' + ($deletion | ConvertTo-Json -Depth 12))
    }
}
foreach ($op in @('install', 'uninstall')) {
    Test-Case "R5 cross-account elevation refuses $op before deployment or data cleanup" {
        $r = Invoke-InstallerFixture -Operation launch -LaunchOperation $op -Scenario @{
            Admin = $false; AccountSid = 'S-1-5-21-100'; ElevatedSid = 'S-1-5-21-200'; ExistingVersion = '1.0.0.0'
        } -Arguments $(if ($op -eq 'uninstall') { @('-Force', '-RemoveCliConfig', '-RemoveUserData') } else { @('-Force') })
        Assert-CrossAccountBoundary $r
    }
}
foreach ($injection in @('data','raw-data','package','service','process')) {
    Test-Case "D5 ownership assertion detects a real pre-SID $injection mutation" {
        $r = Invoke-InstallerFixture -Operation launch -LaunchOperation uninstall -Scenario @{
            Admin = $false; ElevatedSid = 'S-1-5-21-200'; ExistingVersion = '1.0.0.0'; InjectBeforeIdentity = $injection
        } -Arguments @('-Force', '-RemoveCliConfig', '-RemoveUserData')
        $mutationName = @{ data = 'DeletePath'; 'raw-data' = 'RawDelete'; package = 'Remove'; service = 'StopService'; process = 'Kill' }[$injection]
        if ($injection -eq 'raw-data') {
            Assert-True (@($r.Resources | Where-Object { -not $_.Exists }).Count -gt 0) 'raw negative fixture did not actually delete its resource'
        }
        Assert-True (@(Get-Calls $r 'SidGateRefused').Count -eq 1) 'negative fixture did not reach the actual SID refusal'
        Assert-True (@(Get-Calls $r $mutationName | Where-Object { $_.Phase -eq 'entry-before-identity' }).Count -gt 0) 'negative fixture did not perform its intended pre-SID mutation'
        $detected = $false
        try { Assert-CrossAccountBoundary $r } catch { $detected = $true }
        Assert-True $detected "pre-SID $injection mutation escaped the ownership assertion"
    }
}
foreach ($injection in @('child-overwrite','child-volume')) {
    Test-Case "D5 rejects actual child pre-SID $injection mutation" {
        $r = Invoke-InstallerFixture -Operation launch -LaunchOperation uninstall -Scenario @{
            Admin = $false; ElevatedSid = 'S-1-5-21-200'; ExistingVersion = '1.0.0.0'; InjectBeforeIdentity = $injection
        } -Arguments @('-Force')
        $refusal = @(Get-Calls $r 'SidGateRefused')
        $mutationName = if ($injection -eq 'child-overwrite') { 'ObservedChildContent' } else { 'AddVolume' }
        $mutation = @(Get-Calls $r $mutationName)
        Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1 -and $refusal.Count -eq 1) 'child injection did not reach the actual SID refusal'
        Assert-True ($mutation.Count -eq 1 -and $mutation[0].Pid -eq $refusal[0].Pid -and $mutation[0].Phase -eq 'entry-before-identity') 'mutation did not occur in the child before SID validation'
        if ($injection -eq 'child-overwrite') {
            Assert-True ($mutation[0].Value -eq 'fixture-replaced' -and @($r.Resources | Where-Object { -not $_.Exists }).Count -eq 0) 'real overwrite fixture was not exercised'
            Assert-True (@($r.Resources | Where-Object { $_.BeforeHash -ne $_.AfterHash -and $_.BeforeLength -eq $_.AfterLength }).Count -eq 1) 'same-length file replacement did not exercise the content hash guard'
        }
        $detected = $false
        try { Assert-CrossAccountBoundary $r } catch { $detected = $true }
        Assert-True $detected "child pre-SID $injection escaped the boundary assertion"
    }
}
foreach ($case in @(
    @{ ServiceDeleteCode = 5 }, @{ ServiceDeleteThrows = $true }, @{ ServiceRemains = $true }, @{ ServiceMarked = $true }
)) {
    Test-Case "R6 service failure/pending state reaches result file ($($case.Keys))" {
        $s = $case.Clone(); $s.ServiceExists = $true; $s.ExistingVersion = '2.0.0.0'
        $r = Invoke-InstallerFixture -Operation uninstall -Scenario $s -Arguments @('-Force') -CaptureResult
        Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) 'service cleanup failure/pending reported success'
        Assert-True (@(Get-Calls $r 'ServiceCommand' | Where-Object { $_.Value -eq 'delete' }).Count -eq 1) 'service deletion failure branch never reached'
        if ($s['ServiceMarked']) { Assert-True ($r.Output -match '标记|重启') 'pending deletion not distinguished' }
    }
}
Test-Case 'R6 successful service cleanup verifies absence' {
    $r = Invoke-InstallerFixture -Operation uninstall -Scenario @{ ServiceExists = $true; ExistingVersion = '2.0.0.0' } -Arguments @('-Force')
    Assert-True ($r.Code -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'ServiceCommand' | Where-Object { $_.Value -eq 'query' }).Count -ge 1) 'service absence was not verified'
}
Test-Case 'R6 launcher propagates service cleanup failure' {
    $r = Invoke-InstallerFixture -Operation launch -LaunchOperation uninstall -Scenario @{
        ServiceExists = $true; ExistingVersion = '2.0.0.0'; ServiceDeleteCode = 5
    } -Arguments @('-Force')
    Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) 'launcher hid service deletion failure'
}
# Round 2: an empty managed query is not evidence of absence, including early return.
foreach ($mode in @('denied', 'empty', 'missing-error')) {
    Test-Case "R6A inventory refuses unconfirmed service state ($mode), with and without a package" {
        foreach ($version in @('', '2.0.0.0')) {
            $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
                ExistingVersion = $version; ServiceExists = $true; ServiceQueryMode = $mode
            } -CaptureResult
            Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) "unconfirmed service query returned success: $($r.Output)"
            Assert-True (@(Get-Calls $r 'ServiceQuery').Count -gt 0) 'managed query branch not exercised'
            Assert-True (@(Get-Calls $r 'NativeServiceQueryCode' | Where-Object { $_.Value -eq 0 }).Count -gt 0) 'service existence was not independently checked'
            Assert-True (@(Get-Calls $r 'Remove').Count -eq 0) 'inventory uncertainty was detected after package removal'
        }
    }
    Test-Case "R6A cleanup refuses unconfirmed service state after package removal ($mode)" {
        $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
            ExistingVersion = '2.0.0.0'; ServiceExists = $true; ServiceQueryModeAfterRemoval = $mode
        } -CaptureResult
        Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) "cleanup query returned false success: $($r.Output)"
        Assert-True (@(Get-Calls $r 'AfterRemove').Count -eq 1) 'post-removal query seam not reached'
        Assert-True (@(Get-Calls $r 'NativeServiceQueryCode' | Where-Object { $_.Value -eq 0 }).Count -gt 0) 'missing cleanup object was not independently checked'
        Assert-True (@(Get-Calls $r 'ServiceCommand' | Where-Object { $_.Value -eq 'delete' }).Count -eq 0) 'unconfirmed service was modified'
    }
}
foreach ($case in @(@{ ServiceQueryCode = 5 }, @{ ServiceQueryCode = 1072 }, @{ ServiceQueryThrows = $true })) {
    Test-Case "R6A native inventory query failure cannot take the no-package early return ($($case.Keys))" {
        $s = $case.Clone(); $s.ServiceQueryMode = 'denied'
        $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario $s -CaptureResult
        Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) 'unavailable native query was treated as absent'
        Assert-True (@(Get-Calls $r 'ServiceCommand' | Where-Object { $_.Value -eq 'query' }).Count -eq 1) 'native query error not exercised'
    }
}
Test-Case 'R6A native cleanup query failure reaches completion file' {
    $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
        ExistingVersion = '2.0.0.0'; ServiceExists = $true
        ServiceQueryModeAfterRemoval = 'denied'; ServiceQueryCodeAfterRemoval = 5
    } -CaptureResult
    Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) 'post-removal native query failure was hidden'
    Assert-True (@(Get-Calls $r 'NativeServiceQueryCode' | Where-Object { $_.Value -eq 5 }).Count -eq 1) 'cleanup query failure branch not exercised'
}
foreach ($mode in @('normal', 'denied', 'empty', 'missing-error')) {
    Test-Case "R6A native 1060 confirms true absence without false failures ($mode)" {
        foreach ($version in @('', '2.0.0.0')) {
            $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
                ExistingVersion = $version; ServiceQueryMode = $mode; ServiceExists = $false
            } -CaptureResult
            Assert-True ($r.Code -eq 0 -and $r.Completion.ExitCode -eq 0) $r.Output
            Assert-True (@(Get-Calls $r 'NativeServiceQueryCode' | Where-Object { $_.Value -eq 1060 }).Count -gt 0) 'success lacks explicit service absence evidence'
            Assert-True (@(Get-Calls $r 'ServiceCommand' | Where-Object { $_.Value -eq 'delete' }).Count -eq 0) 'nonexistent service deletion was attempted'
        }
    }
}
Test-Case 'R6A package-managed service disappearance is confirmed even if the managed query is denied' {
    $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
        ExistingVersion = '2.0.0.0'; ServiceExists = $true; ServiceDisappearsAfterRemoval = $true
        ServiceQueryModeAfterRemoval = 'denied'
    } -CaptureResult
    Assert-True ($r.Code -eq 0 -and $r.Completion.ExitCode -eq 0) $r.Output
    Assert-True (@(Get-Calls $r 'AfterRemove').Count -eq 1) 'package-managed disappearance not exercised'
    Assert-True (@(Get-Calls $r 'NativeServiceQueryCode' | Where-Object { $_.Value -eq 1060 }).Count -eq 1) 'cleanup absence not confirmed'
}
Test-Case 'R6A launcher propagates a service inventory query failure without installed packages' {
    $r = Invoke-InstallerFixture -Operation launch -LaunchOperation uninstall -Arguments @('-Force') -Scenario @{
        ServiceExists = $true; ServiceQueryMode = 'denied'
    }
    Assert-True ($r.Code -eq 1 -and $r.Completion.ExitCode -eq 1) 'launcher hid early service query failure'
    # The launcher persists its own call log after the child exits; child boundary calls
    # are asserted by the direct-entry cases above, while this case checks propagation.
    Assert-True ((Get-Calls $r 'ChildExit').Value -eq 1 -and $r.Output -match '无法确认服务') 'child service query failure was not propagated'
}
foreach ($exists in @($false, $true)) {
    Test-Case "R6A non-admin cleanup succeeds only when service absence is confirmed (exists=$exists)" {
        $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force') -Scenario @{
            ExistingVersion = '2.0.0.0'; Admin = $false; ServiceExists = $exists
        } -CaptureResult
        $expected = if ($exists) { 1 } else { 0 }
        Assert-True ($r.Code -eq $expected -and $r.Completion.ExitCode -eq $expected) $r.Output
        Assert-True (@(Get-Calls $r 'ServiceCommand' | Where-Object { $_.Value -eq 'delete' }).Count -eq 0) 'non-admin attempted shared service deletion'
        if (-not $exists) {
            Assert-True (@(Get-Calls $r 'NativeServiceQueryCode' | Where-Object { $_.Value -eq 1060 }).Count -ge 2) 'non-admin did not confirm absence at both boundaries'
        }
    }
}
Test-Case 'R7 preserves all firewall rules without tool-managed ownership records' {
    $program = 'C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
    $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force', '-CleanFirewall') -Scenario @{
        ExistingVersion = '2.0.0.0'; ExistingLocation = 'C:\WindowsApps\OpenAI.Codex_fixture'
        FirewallRules = @(
            @{ Name = 'user-custom-block'; DisplayName = 'My outbound policy'; Action = 'Block'; Program = $program; Package = 'Any'; PolicyStoreSourceType = 'Local' },
            @{ Name = 'user-custom-allow'; DisplayName = 'My inbound policy'; Action = 'Allow'; Program = $program; Package = 'Any'; PolicyStoreSourceType = 'Local' },
            @{ Name = 'OpenAI.Codex'; DisplayName = 'ChatGPT desktop installer managed'; Action = 'Allow'; Program = $program; Package = 'OpenAI.Codex_2p2nqsd0c76g0' },
            @{ Name = ''; DisplayName = ''; Action = 'Block'; Program = $program; Package = 'Any' },
            @{ Action = 'Allow'; Program = $program; Package = 'Any' },
            @{ Name = 'user-block'; DisplayName = 'Block OpenAI telemetry'; Program = 'Any'; Package = 'Any' },
            @{ Name = 'chrome'; DisplayName = 'Codex browser'; Program = 'C:\Chrome\chrome.exe'; Package = 'Any' },
            @{ Name = 'prefix'; DisplayName = 'ChatGPT'; Program = 'C:\WindowsApps\OpenAI.Codex_fixture-other\app.exe'; Package = 'Any' }
        )
    } -CaptureResult
    Assert-True ($r.Code -eq 0 -and $r.Completion.ExitCode -eq 0) $r.Output
    $deleted = @(Get-Calls $r 'DeleteFirewall' | ForEach-Object { $_.Value })
    Assert-True ($deleted.Count -eq 0) "user rules deleted without ownership records: $deleted"
    Assert-True ($r.Output -match '未创建.*防火墙规则|没有.*规则.*管理记录') 'retention without ownership evidence was not explained'
}
foreach ($version in @('', '2.0.0.0')) {
    Test-Case "R7 CleanFirewall remains a reported no-op even if rule queries are unavailable (package=$version)" {
        $r = Invoke-InstallerFixture -Operation uninstall -Arguments @('-Force', '-CleanFirewall') -Scenario @{
            ExistingVersion = $version; FirewallQueryFails = $true
        } -CaptureResult
        Assert-True ($r.Code -eq 0 -and $r.Completion.ExitCode -eq 0) $r.Output
        foreach ($call in @('FirewallQuery', 'FirewallFilter', 'DeleteFirewall')) {
            Assert-True (@(Get-Calls $r $call).Count -eq 0) "no managed rules exist, but firewall operation ran: $call"
        }
        Assert-True ($r.Output -match '保留.*防火墙规则|防火墙规则.*保留') 'CleanFirewall did not explain that existing rules are preserved'
    }
}
Test-Case 'R9 bat normalizes drive root before native PowerShell boundary' {
    $text = Get-Content (Join-Path $repo '安装ChatGPT桌面版.bat') -Raw
    Assert-True ($text -notmatch '-ResultPath "%RESULT%" %\*') 'raw quoted trailing backslash still crosses native PowerShell boundary'
    Assert-True ($text -notmatch '(?im)^shift\s*$') 'argument parsing must preserve %0 for the launcher script path'
}
if ($env:OS -eq 'Windows_NT') {
    Test-Case 'R9 complete installation bat preserves subsequent switches for all legal drive forms' {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path (Join-Path $tempDir 'scripts') -Force
        try {
            Copy-Item (Join-Path $repo '安装ChatGPT桌面版.bat') (Join-Path $tempDir 'entry.bat')
            $stub = @'
param($Operation, $ResultPath, $InstallDrive, [switch]$NoPause, [switch]$Force, [switch]$SkipProvision, $PackagePath)
if ($Operation -ne 'install' -or $InstallDrive -ne 'D:' -or -not $NoPause -or -not $Force -or -not $SkipProvision -or $PackagePath -ne "C:\fixture's & ! [test]\package.msix") { exit 9 }
[IO.File]::WriteAllText($ResultPath, '{"ExitCode":0}')
exit 0
'@
            [IO.File]::WriteAllText((Join-Path $tempDir 'scripts/launch-chatgpt-desktop.ps1'), $stub, (New-Object Text.UTF8Encoding($true)))
            foreach ($drive in @('D:', 'D:\', '"D:"', '"D:\"')) {
                $batch = Join-Path $tempDir 'entry.bat'
                $command = "call `"$batch`" -InstallDrive $drive -NoPause -Force -SkipProvision -PackagePath `"C:\fixture's & ! [test]\package.msix`" <nul"
                # Store the exact CMD invocation in a .cmd file so the outer test host's
                # native argument parser cannot alter the quoted D:\ case before CMD sees it.
                $casePath = Join-Path $tempDir 'drive-case.cmd'
                [IO.File]::WriteAllText($casePath, ($command + "`r`nexit /b %errorlevel%`r`n"), [Text.Encoding]::ASCII)
                $native = Invoke-TestNative -FilePath $env:ComSpec -Arguments ('/d /v:off /c ""' + $casePath + '""')
                Assert-True ($native.Code -eq 0) "drive $drive lost trailing arguments: $($native.Output)"
            }
        } finally { Remove-Item $tempDir -Recurse -Force }
    }
} else { Write-Host 'SKIP R9 complete-batch drive quoting (requires Windows cmd.exe and powershell.exe)' }
