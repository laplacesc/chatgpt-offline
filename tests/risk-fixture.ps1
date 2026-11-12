# Appended only to a temporary common.ps1 by installer-regression.ps1.
# All mutating Windows boundaries below are simulated, including nonempty processes/services/rules.
function New-FixturePackage {
    param($Version = '2.0.0.0', $Location = 'C:\WindowsApps\OpenAI.Codex_fixture',
        $Publisher = $fixture.ExistingPublisher, $Family = $fixture.ExistingFamily)
    [pscustomobject]@{
        Name = 'OpenAI.Codex'; Version = $Version; Publisher = $Publisher; PackageFamilyName = $Family
        PackageFullName = "OpenAI.Codex_${Version}_x64__2p2nqsd0c76g0"; InstallLocation = $Location
    }
}
if ($fixture.ExistingVersion) {
    $script:state.Installed = New-FixturePackage $fixture.ExistingVersion $fixture.ExistingLocation
}
$script:serviceExists = $fixture.ServiceExists
$script:removeAttempted = $false
function Get-CurrentAccountSid {
    if ($env:CHATGPT_FIXTURE_CHILD -eq '1' -and $fixture.ElevatedSid) { return $fixture.ElevatedSid }
    return $fixture.AccountSid
}
function Get-MsixInfo {
    param($Path)
    [pscustomobject]@{
        Name = 'OpenAI.Codex'; Version = '2.0.0.0'; Architecture = 'x64'
        Publisher = $fixture.ManifestPublisher; RequiresAdmin = $fixture.HasServices
    }
}
function Test-MsixSignature {
    param($Path)
    [pscustomobject]@{ Valid = $fixture.SignatureValid; Status = 'fixture'; Subject = $fixture.SignerSubject; Issuer = 'fixture' }
}
function Get-AppxPackage {
    [CmdletBinding()]
    param($Name, $Publisher, [switch]$AllUsers)
    Record-Call 'QueryPackages' ([bool]$AllUsers)
    if ($fixture.PackageQueryFailsAfterRemoval -and $script:removeAttempted) { throw 'fixture: package query unavailable' }
    if ($script:state.Installed) { $script:state.Installed }
    # Deliberately ignore the -Publisher filter to exercise defensive family/publisher checks too.
    if ($fixture.ForeignPackage) { New-FixturePackage -Publisher 'CN=Other' -Family 'OpenAI.Codex_foreign' }
}
function Get-AppxProvisionedPackage {
    [CmdletBinding()]
    param([switch]$Online)
    $script:state.ProvisionQueries++
    Record-Call 'QueryProvision' $script:state.ProvisionQueries
    if ($script:state.ProvisionQueries -gt $fixture.ProvisionClearsAfterQueries -and $fixture.ProvisionClearsAfterQueries -gt 0) {
        $script:state.Provisioned = $false
    }
    if ($script:state.Provisioned) {
        [pscustomobject]@{ DisplayName = 'OpenAI.Codex'; PackageName = 'OpenAI.Codex_2.0.0.0_x64__2p2nqsd0c76g0' }
    }
}
function Remove-AppxPackage {
    [CmdletBinding()]
    param($Package, [switch]$AllUsers)
    $script:removeAttempted = $true
    Record-Call 'Remove' $Package
    if ($fixture.RemoveError) { throw 'fixture: package removal failed' }
    if (-not $fixture.RemoveLeavesPackage) { $script:state.Installed = $null }
    if ($fixture.ServiceDisappearsAfterRemoval) { $script:serviceExists = $false }
    Record-Call 'AfterRemove' $Package
}
function Add-AppxPackage {
    [CmdletBinding()]
    param($Path, [switch]$ForceApplicationShutdown, $Volume, [switch]$ForceUpdateFromAnyVersion)
    $drive = if ($Volume -and -not $fixture.InstallIgnoresVolume) { 'D:' } else { 'C:' }
    Record-Call 'Install' $drive
    Record-Call 'DowngradeFlag' ([bool]$ForceUpdateFromAnyVersion)
    if ($fixture.InstallError) { throw $fixture.InstallError }
    $script:state.Installed = New-FixturePackage -Location "$drive\WindowsApps\OpenAI.Codex_fixture" -Publisher 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B' -Family 'OpenAI.Codex_2p2nqsd0c76g0'
    Record-Call 'Installed' $Path
}
function Get-Command {
    [CmdletBinding()]
    param($Name)
    if ($Name -eq 'Add-AppxPackage' -and -not $fixture.SupportsDowngrade) {
        return [pscustomobject]@{ Parameters = @{} }
    }
    Microsoft.PowerShell.Core\Get-Command -Name $Name
}
function Get-Process {
    [CmdletBinding()]
    param($Name)
    $fixture.Processes | Where-Object { $_.Name -ieq $Name }
}
function Stop-Process {
    [CmdletBinding()]
    param($Id, [switch]$Force)
    Record-Call 'Kill' $Id
}
function Get-Service {
    [CmdletBinding()]
    param($Name)
    Record-Call 'ServiceQuery' $Name
    $mode = $fixture.ServiceQueryMode
    if ($script:removeAttempted -and $fixture.ServiceQueryModeAfterRemoval) { $mode = $fixture.ServiceQueryModeAfterRemoval }
    if ($fixture.ServiceQueryFails -or $mode -eq 'denied') {
        Write-Error -Message 'fixture: Get-Service access is denied' -Category PermissionDenied
        return
    }
    if ($mode -eq 'missing-error') {
        Write-Error -Message 'fixture: Get-Service cannot find the requested service' -Category ObjectNotFound -ErrorId NoServiceFoundForGivenName
        return
    }
    if ($mode -eq 'empty') { return }
    if ($script:serviceExists) { [pscustomobject]@{ Name = $Name; Status = 'Running' } }
}
function Stop-Service {
    [CmdletBinding()]
    param($Name, [switch]$Force)
    Record-Call 'StopService' $Name
}
function sc.exe {
    param($Action, $Name)
    Record-Call 'ServiceCommand' $Action
    if ($Action -eq 'query') {
        if ($fixture.ServiceQueryThrows) { throw 'fixture: native service query exception' }
        $code = $fixture.ServiceQueryCode
        if ($script:removeAttempted -and $fixture.ServiceQueryCodeAfterRemoval -ne -1) { $code = $fixture.ServiceQueryCodeAfterRemoval }
        $global:LASTEXITCODE = if ($code -ne -1) { $code } elseif ($script:serviceExists) { 0 } else { 1060 }
        Record-Call 'NativeServiceQueryCode' $global:LASTEXITCODE
        return 'fixture native service query output'
    }
    if ($fixture.ServiceDeleteThrows) { throw 'fixture: service control exception' }
    $global:LASTEXITCODE = if ($fixture.ServiceMarked) { 1072 } else { $fixture.ServiceDeleteCode }
    if ($LASTEXITCODE -eq 0 -and -not $fixture.ServiceRemains) { $script:serviceExists = $false }
    return 'fixture service output'
}
function Get-NetFirewallRule {
    [CmdletBinding()]
    param()
    Record-Call 'FirewallQuery' $null
    if ($fixture.FirewallQueryFails) { throw 'fixture: firewall query failed' }
    $fixture.FirewallRules
}
function Get-NetFirewallApplicationFilter {
    [CmdletBinding()]
    param($AssociatedNetFirewallRule)
    Record-Call 'FirewallFilter' $AssociatedNetFirewallRule.Name
    [pscustomobject]@{ Program = $AssociatedNetFirewallRule.Program; Package = $AssociatedNetFirewallRule.Package }
}
function Remove-NetFirewallRule {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)]$InputObject)
    process { Record-Call 'DeleteFirewall' $InputObject.Name }
}
# Make aliases and user data observable while keeping filesystem mutation inside the fixture tree.
$aliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps'
if ($env:CHATGPT_FIXTURE_CHILD -ne '1') {
    $null = New-Item -ItemType Directory -Path $aliasDir -Force
    Set-Content (Join-Path $aliasDir 'codex-chrome-native-host.exe') 'fixture'
    $null = New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.codex') -Force
}
function Remove-Item {
    [CmdletBinding()]
    param($LiteralPath, $Path, [switch]$Force, [switch]$Recurse)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    Record-Call 'DeletePath' $target
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $target -Force:$Force -Recurse:$Recurse
}
# Protect concrete fixture-owned resources; AppData/Temp is not itself application data.
$resourcePaths = @(
    (Join-Path $env:LOCALAPPDATA 'OpenAI/fixture-user-data'),
    (Join-Path $env:LOCALAPPDATA 'Packages/OpenAI.Codex_2p2nqsd0c76g0/fixture-package-data'),
    (Join-Path $env:USERPROFILE '.codex/fixture-cli-config'),
    (Join-Path $aliasDir 'codex-chrome-native-host.exe')
)
# A launched child must not recreate resources removed by its launcher before the SID gate.
if ($env:CHATGPT_FIXTURE_CHILD -ne '1') {
    foreach ($path in $resourcePaths) {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        [IO.File]::WriteAllText($path, 'fixture-resource')
    }
    Record-Call 'ResourceBaseline' @($resourcePaths | ForEach-Object {
        [pscustomobject]@{ Path = $_; Sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash; Length = ([IO.FileInfo]$_).Length }
    })
}
$script:state | Add-Member -NotePropertyName Resources -NotePropertyValue $resourcePaths
$script:originalAccountAssertion = ${function:Assert-OriginatingAccount}
function Assert-OriginatingAccount {
    param([string]$OriginatingUserSid)
    $script:fixturePhase = 'identity-check'
    Record-Call 'SidGateEnter' $OriginatingUserSid
    try {
        & $script:originalAccountAssertion -OriginatingUserSid $OriginatingUserSid
        $script:fixturePhase = 'identity-passed'
        Record-Call 'SidGatePassed' $OriginatingUserSid
    } catch {
        $script:fixturePhase = 'identity-refused'
        Record-Call 'SidGateRefused' $OriginatingUserSid
        throw
    }
}
$script:fixturePhase = 'entry-before-identity'
Record-Call 'FixtureReady' $resourcePaths
