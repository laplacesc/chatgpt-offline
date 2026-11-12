# ============================================================
#  common.ps1 - ChatGPT 桌面版离线安装工具 公共函数库
#  被 install / uninstall / download 脚本共同引用
# ============================================================

Set-StrictMode -Version Latest

# ---------- 包标识常量（取自官方 MSIX 的 AppxManifest.xml） ----------
$script:AppPackageName   = 'OpenAI.Codex'
$script:AppFamilyName    = 'OpenAI.Codex_2p2nqsd0c76g0'
$script:AppDisplayName   = 'ChatGPT'
$script:AppPublisher     = 'CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B'
$script:AppServiceName   = 'CodexSandboxService.OpenAI.Codex'
$script:MinOsBuild       = 19041          # Windows 10 2004
$script:RequiredFreeGB   = 3

# ---------- 官方下载地址 ----------
$script:UrlBase       = 'https://persistent.oaistatic.com/codex-app-prod'
$script:UrlMsixX64    = "$script:UrlBase/ChatGPT-x64.msix"
$script:UrlMsixArm64  = "$script:UrlBase/ChatGPT-arm64.msix"
$script:UrlLicense    = "$script:UrlBase/ChatGPT-License.xml"

# ---------- 目录 ----------
$script:RootDir = Split-Path -Parent $PSScriptRoot
$script:PkgDir  = Join-Path $script:RootDir 'pkg'
$script:LogDir  = Join-Path $script:RootDir 'log'

# ============================================================
#  输出
# ============================================================
function Write-Banner {
    param([string]$Title)
    $line = '=' * 62
    Write-Host ''
    Write-Host $line -ForegroundColor Cyan
    Write-Host ("  " + $Title) -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step { param([string]$Message) Write-Host "[>] $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn2{ param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err2 { param([string]$Message) Write-Host "[X] $Message" -ForegroundColor Red }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# ============================================================
#  日志
# ============================================================
function Start-AppLog {
    param([string]$Name)
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $script:LogDir "$Name-$stamp.log"
    try {
        Start-Transcript -Path $path -Force | Out-Null
    } catch { }
    return $path
}

function Stop-AppLog {
    try { Stop-Transcript | Out-Null } catch { }
}

function Write-AppResult {
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$LogPath
    )
    if (-not $Path) { return }
    $result = [ordered]@{
        Operation = $Operation
        ExitCode = $ExitCode
        LogPath = $LogPath
        CompletedAt = (Get-Date).ToString('o')
    }
    # 同目录写入后再替换，读取方不会误把半写入的文件当成完成结果。
    $temporary = "$Path.$PID.tmp"
    try {
        $json = $result | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

# ============================================================
#  环境检测
# ============================================================
function Assert-AppxHost {
    # Windows 10 的 Appx 模块在 PowerShell 7 中可能被错误地当作兼容模块加载。
    # 直接调用 .ps1 时也在任何部署操作前给出明确的重试方式。
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw '安装和卸载需要 Windows PowerShell 5.1。请运行对应的 .bat，或使用 powershell.exe -NoProfile -ExecutionPolicy Bypass -File <脚本路径>。不要使用 pwsh。'
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemArch {
    <#
      返回 x64 / arm64 / x86。
      优先使用 .NET 的 OSArchitecture（在 WOW64 下也准确），
      失败时回退到环境变量。
    #>
    try {
        $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        switch ($osArch) {
            'X64'   { return 'x64' }
            'Arm64' { return 'arm64' }
            'X86'   { return 'x86' }
        }
    } catch { }

    # 回退：32 位进程跑在 64 位系统上时，真实架构在 PROCESSOR_ARCHITEW6432 里
    $a = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $env:PROCESSOR_ARCHITECTURE }
    if ([string]::IsNullOrWhiteSpace($a)) { return 'unknown' }

    switch ($a.ToUpper()) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        'X86'   { return 'x86' }
        default { return $a.ToLower() }
    }
}

function Get-OsBuild {
    try { return [int](Get-CimInstance Win32_OperatingSystem).BuildNumber }
    catch { return [int][Environment]::OSVersion.Version.Build }
}

function Get-FreeSpaceGB {
    param([string]$DriveLetter = $env:SystemDrive)
    try {
        $d = Get-PSDrive -Name $DriveLetter.TrimEnd(':') -ErrorAction Stop
        return [math]::Round($d.Free / 1GB, 1)
    } catch { return -1 }
}

# ============================================================
#  自定义安装卷
# ============================================================
function Get-InstallTarget {
    param([Parameter(Mandatory)][string]$Drive)

    if ($Drive -notmatch '^[A-Za-z]:\\?$') {
        throw '安装盘格式无效：请指定盘符（如 D: 或 D:\），不能指定任意文件夹。'
    }
    $driveName = $Drive.TrimEnd('\').ToUpperInvariant()
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$driveName'" -ErrorAction Stop
    if (-not $disk) { throw "安装盘 $driveName 不存在或尚未就绪。" }
    if ($disk.DriveType -ne 3) { throw "安装盘 $driveName 必须是本地固定磁盘。" }
    if ($disk.FileSystem -ne 'NTFS') { throw "安装盘 $driveName 必须使用 NTFS 文件系统。" }

    # 枚举后筛选，避免尚未注册的磁盘在按路径查询时被 Windows 当作无效卷报错。
    $volume = Get-AppxVolume -ErrorAction Stop |
        Where-Object { $_ -and ([string]$_.PackageStorePath).StartsWith("$driveName\", [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($volume -and $volume.IsOffline) { throw "安装盘 $driveName 的应用卷处于离线状态，请先在 Windows 中使其联机。" }
    return [pscustomobject]@{
        Drive = $driveName
        Volume = $volume
    }
}

function Initialize-InstallVolume {
    param([Parameter(Mandatory)]$Target, [bool]$IsAdmin)

    if ($Target.Volume) { return $Target.Volume }
    if (-not $IsAdmin) { throw "首次在 $($Target.Drive) 创建应用卷需要管理员权限，请以管理员身份重新运行。" }
    $volume = Add-AppxVolume -Path "$($Target.Drive)\WindowsApps" -ErrorAction Stop
    if (-not $volume) { throw "未能在 $($Target.Drive) 创建应用卷。" }
    $Target.Volume = $volume
    return $volume
}

function Test-PackageOnDrive {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$Drive)
    return ([string]$Package.InstallLocation).StartsWith("$Drive\", [StringComparison]::OrdinalIgnoreCase)
}

function Move-ChatGptToVolume {
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)]$Target)
    if (Test-PackageOnDrive -Package $Package -Drive $Target.Drive) { return }
    Write-Step "将已安装的应用迁移到 $($Target.Drive)"
    Write-Info '请先完全退出 ChatGPT；若系统禁止移动此包，脚本会停止并保留原安装。'
    Move-AppxPackage -Package $Package.PackageFullName -Volume $Target.Volume -ErrorAction Stop
    $moved = Get-InstalledChatGpt
    if (-not $moved -or -not (Test-PackageOnDrive -Package $moved -Drive $Target.Drive)) {
        throw '迁移命令已执行，但应用位置未变更到指定磁盘。请检查 Windows 应用部署日志。'
    }
    Write-Ok "应用已迁移到 $($Target.Drive)"
}

# ============================================================
#  MSIX 包信息
# ============================================================
function Get-MsixInfo {
    <#
      读取 MSIX 内部 AppxManifest.xml，返回 Name / Version / Architecture / DisplayName。
      纯 .NET 实现，不依赖任何外部工具。
    #>
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = $null
    try {
        $zip   = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
        if (-not $entry) { throw '压缩包内没有 AppxManifest.xml，这不是一个有效的 MSIX 文件。' }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        $xmlTxt = $reader.ReadToEnd()
        $reader.Dispose()

        [xml]$xml = $xmlTxt
        $identity = $xml.Package.Identity
        return [pscustomobject]@{
            Name         = $identity.Name
            Version      = $identity.Version
            Architecture = $identity.ProcessorArchitecture
            Publisher    = $identity.Publisher
            DisplayName  = $xml.Package.Properties.DisplayName
            RequiresAdmin = ($xml.SelectNodes("//*[local-name()='Extension' and @Category='windows.service']").Count -gt 0)
        }
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Test-MsixSignature {
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    return [pscustomobject]@{
        Status  = $sig.Status
        Valid   = ($sig.Status -eq 'Valid')
        Subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '(无签名)' }
        Issuer  = if ($sig.SignerCertificate) { $sig.SignerCertificate.Issuer }  else { '' }
    }
}

function Assert-TrustedMsixIdentity {
    param([Parameter(Mandatory)]$Info, [Parameter(Mandatory)]$Signature)
    # Valid alone authenticates any trusted publisher. Identity is never bypassed by -Force.
    if ($Info.Name -cne $script:AppPackageName -or $Info.Publisher -ine $script:AppPublisher) {
        throw "安装包身份不受信任：必须是 $script:AppPackageName，发布者 $script:AppPublisher。"
    }
    if (-not $Signature.Valid -or $Signature.Subject -ine $script:AppPublisher -or
        $Signature.Subject -ine $Info.Publisher) {
        throw '数字签名或发布者校验未通过：签名必须有效，且主体必须与官方清单发布者一致；-Force 不会跳过此检查。'
    }
}

function Get-InstalledChatGpt {
    param([switch]$AllUsers)
    Get-AppxPackage -Name $script:AppPackageName -Publisher $script:AppPublisher -AllUsers:$AllUsers -ErrorAction Stop |
        Where-Object { $_.Name -ceq $script:AppPackageName -and
            $_.Publisher -ieq $script:AppPublisher -and $_.PackageFamilyName -ceq $script:AppFamilyName }
}

function Get-ProvisionedChatGpt {
    # DISM exposes PackageName rather than Publisher. Its final component is the publisher ID.
    Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {
        $_.DisplayName -ceq $script:AppPackageName -and
        $_.PackageName -cmatch '^OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_(x64|arm64|neutral)_[^_]*_2p2nqsd0c76g0$'
    }
}

function Get-CurrentAccountSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Assert-OriginatingAccount {
    param([string]$OriginatingUserSid)
    if ($OriginatingUserSid -and $OriginatingUserSid -ne (Get-CurrentAccountSid)) {
        throw '提权后的账户身份与发起账户不同，已在部署或数据清理前停止。请使用同一账户确认 UAC；不支持输入其他管理员账户凭据。'
    }
}

function Test-AppOwnedPath {
    param([string]$Path, [string[]]$InstallRoots)
    # Use Windows path semantics also in portable mocked tests. Unknown/relative/traversal paths fail closed.
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:\\' -or
        $Path -match '(^|[\\/])\.{1,2}([\\/]|$)' -or $Path.Contains('/')) { return $false }
    foreach ($root in $InstallRoots) {
        if ($root -and $root -match '^[A-Za-z]:\\' -and
            $root -notmatch '(^|[\\/])\.{1,2}([\\/]|$)' -and -not $root.Contains('/') -and
            $Path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Resolve-MsixPath {
    <#
      在 pkg\ 目录里查找安装包：
      优先 ChatGPT-<当前架构>.msix，其次任意 *.msix（取最新的）。
    #>
    param([string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "指定的安装包不存在：$Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    if (-not (Test-Path $script:PkgDir)) { return $null }

    $arch      = Get-SystemArch
    $preferred = Join-Path $script:PkgDir "ChatGPT-$arch.msix"
    if (Test-Path -LiteralPath $preferred) { return $preferred }

    $any = Get-ChildItem -Path $script:PkgDir -Filter '*.msix' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($any) { return $any.FullName }
    return $null
}

function Get-LicensePath {
    param([string]$Path = (Join-Path $script:PkgDir 'ChatGPT-License.xml'))
    if (Test-Path -LiteralPath $Path) {
        try {
            $license = [xml](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
            if ($license.DocumentElement.LocalName -ne 'License') { throw '缺少 License 根元素。' }
            return $Path
        } catch {
            Write-Warn2 "忽略无效的离线授权文件：$($_.Exception.Message)"
        }
    }
    return $null
}

# ============================================================
#  错误码翻译
# ============================================================
function Resolve-AppxError {
    param([string]$Message)

    $map = @{
        '0x80073CF3' = '包依赖校验失败：系统版本过低或缺少运行库，请先安装 Windows 更新。'
        '0x80073CF9' = '安装服务内部错误：通常重启电脑后重试即可解决。'
        '0x80073CFD' = '系统未允许旁加载应用：请在「设置 → 系统 → 开发者选项」中打开“旁加载应用”。'
        '0x80073D06' = '系统中已存在更高版本的 ChatGPT，请先卸载后再安装。'
        '0x80073D02' = '应用正在运行中：请完全退出 ChatGPT（含托盘图标）后重试。'
        '0x80073D28' = '该安装包内含系统服务组件，必须以管理员身份安装。请双击安装 .bat（会自动请求管理员权限），或右键选择“以管理员身份运行”后重试。'
        '0x80070103' = '系统认为已安装相同版本，无需重复安装。'
        '0x800B0109' = '证书链不受信任：安装包可能已损坏或被篡改，建议重新下载。'
        '0x800B0100' = '安装包没有有效签名：文件可能在传输中损坏，建议重新下载。'
        '0x80080204' = '安装包内容损坏：请重新下载安装包。'
        '0x80070005' = '权限不足：请以管理员身份运行本脚本。'
    }

    foreach ($code in $map.Keys) {
        if ($Message -match [regex]::Escape($code)) {
            return "$code - $($map[$code])"
        }
    }
    return $null
}

function Show-FriendlyError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    Write-Err2 $msg
    $hint = Resolve-AppxError -Message $msg
    if ($hint) {
        Write-Host ''
        Write-Warn2 "可能原因：$hint"
    }
}
