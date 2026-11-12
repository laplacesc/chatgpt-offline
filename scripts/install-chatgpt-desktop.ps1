<#
.SYNOPSIS
    离线安装 ChatGPT 桌面版（MSIX）。

.DESCRIPTION
    从本地 pkg\ 目录读取官方 MSIX 安装包，先为当前用户安装，
    再（如具备管理员权限）预置到整机，使新建用户账户也能直接使用。

.PARAMETER PackagePath
    指定 MSIX 路径。省略时自动在 pkg\ 目录中按当前 CPU 架构查找。

.PARAMETER InstallDrive
    指定本地 NTFS 安装盘（如 D:）。由 Windows 管理包目录，自动跳过整机预置。
    已安装在其他盘时先尝试迁移，迁移失败则停止。

.PARAMETER Force
    发现已安装时不再询问，直接覆盖/降级安装。

.PARAMETER SkipProvision
    只为当前用户安装，跳过整机预置。

.PARAMETER NoPause
    结束时不等待按键，便于在自动化流程中调用。

.PARAMETER ResultPath
    启动器使用的完成结果文件，记录退出码和日志位置。

.EXAMPLE
    .\install-chatgpt-desktop.ps1
    .\install-chatgpt-desktop.ps1 -PackagePath D:\ChatGPT-x64.msix -Force
    .\install-chatgpt-desktop.ps1 -InstallDrive D:
#>
[CmdletBinding()]
param(
    [string] $PackagePath,
    [string] $InstallDrive,
    [switch] $Force,
    [switch] $SkipProvision,
    [switch] $NoPause,
    [string] $ResultPath,
    [string] $OriginatingUserSid
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$logFile  = Start-AppLog -Name 'install'
$exitCode = 0

try {
    Write-Banner 'ChatGPT 桌面版 · 离线安装'
    Assert-AppxHost
    Assert-OriginatingAccount -OriginatingUserSid $OriginatingUserSid
    $isDowngrade = $false

    # ---------------------------------------------------------
    # 1. 环境自检
    # ---------------------------------------------------------
    Write-Step '检查运行环境'

    $isAdmin = Test-IsAdmin
    $arch    = Get-SystemArch
    $build   = Get-OsBuild
    $target  = $null
    $spaceDrive = $env:SystemDrive
    if ($InstallDrive) {
        $target = Get-InstallTarget -Drive $InstallDrive
        if (-not $target.Volume -and -not $isAdmin) {
            throw "首次在 $($target.Drive) 创建应用卷需要管理员权限，请以管理员身份重新运行。"
        }
        $spaceDrive = $target.Drive
        Write-Info "指定安装盘: $($target.Drive)（自动跳过整机预置）"
    }
    $freeGB = Get-FreeSpaceGB -DriveLetter $spaceDrive

    Write-Info "操作系统  : Windows Build $build"
    Write-Info "CPU 架构  : $arch"
    Write-Info "管理员权限: $(if ($isAdmin) { '是' } else { '否' })"
    Write-Info "可用空间  : $(if ($freeGB -ge 0) { "$freeGB GB ($spaceDrive)" } else { '未知' })"

    if ($build -lt $MinOsBuild) {
        throw "系统版本过低：需要 Windows 10 Build $MinOsBuild（2004 版）或更高，当前为 Build $build。"
    }
    if ($arch -eq 'x86') {
        throw 'ChatGPT 桌面版不支持 32 位系统，请在 64 位（x64 或 arm64）Windows 上安装。'
    }
    if ($freeGB -ge 0 -and $freeGB -lt $RequiredFreeGB) {
        throw "磁盘空间不足：安装过程约需 $RequiredFreeGB GB，当前 $spaceDrive 仅剩 $freeGB GB。"
    }
    Write-Ok '环境检查通过'
    Write-Host ''

    # ---------------------------------------------------------
    # 2. 定位并校验安装包
    # ---------------------------------------------------------
    Write-Step '定位安装包'

    $msix = Resolve-MsixPath -Explicit $PackagePath
    if (-not $msix) {
        Write-Err2 "在 pkg\ 目录下没有找到 MSIX 安装包。"
        Write-Host ''
        Write-Info '请任选一种方式获取安装包：'
        Write-Info "  1) 双击运行「下载ChatGPT安装包.bat」自动下载"
        Write-Info "  2) 手动下载后放入 pkg\ 目录："
        Write-Info "     $UrlMsixX64"
        Write-Info "     $UrlMsixArm64"
        throw '缺少安装包，安装中止。'
    }

    $file = Get-Item -LiteralPath $msix
    Write-Info "文件: $($file.Name)"
    Write-Info "大小: $(Format-Size $file.Length)"
    Write-Info "路径: $($file.FullName)"

    if ($file.Length -lt 100MB) {
        throw "安装包只有 $(Format-Size $file.Length)，明显小于正常体积（通常为数百 MB 至约 1 GB，随版本变化），文件很可能没下载完整。请删除后重新下载。"
    }

    $info = Get-MsixInfo -Path $msix
    Write-Info "包标识: $($info.Name) $($info.Version) [$($info.Architecture)]"

    if ($info.Name -ne $AppPackageName) {
        throw "安装包标识为 $($info.Name)，不是 ChatGPT 桌面版（应为 $AppPackageName）。"
    }
    if ($info.Architecture -and $info.Architecture -ne $arch) {
        throw "架构不匹配：安装包是 $($info.Architecture)，当前系统是 $arch。请下载 $arch 版本。"
    }
    Write-Ok '安装包有效'
    Write-Host ''

    # ---------------------------------------------------------
    # 3. 数字签名校验
    # ---------------------------------------------------------
    Write-Step '校验数字签名'
    $sig = Test-MsixSignature -Path $msix
    Assert-TrustedMsixIdentity -Info $info -Signature $sig
    Write-Info "签名主体: $($sig.Subject)"
    Write-Info "颁发机构: $($sig.Issuer)"
    Write-Ok '官方包身份与数字签名校验通过'
    Write-Host ''

    # ---------------------------------------------------------
    # 4. 处理已安装的版本
    # ---------------------------------------------------------
    # 先校验签名，再由清单判断权限要求；不影响不含服务的旧版按用户安装。
    if ($info.RequiresAdmin -and -not $isAdmin) {
        throw '0x80073D28：安装包声明了系统服务，必须以管理员身份安装。'
    }
    Write-Step '检查已安装版本'
    $existing = Get-InstalledChatGpt

    if ($existing) {
        $curVer = [version]$existing.Version
        $newVer = [version]$info.Version
        Write-Info "当前已安装: $curVer"
        Write-Info "即将安装  : $newVer"

        if ($curVer -eq $newVer -and -not $Force) {
            if ($target) {
                $null = Initialize-InstallVolume -Target $target -IsAdmin $isAdmin
                Move-ChatGptToVolume -Package $existing -Target $target
                $existing = Get-InstalledChatGpt
            }
            Write-Ok '已是相同版本，无需重复安装。'
            Write-Info '如需强制重装，请使用 -Force 参数。'
            Write-Host ''
            Write-Host '安装位置: ' -NoNewline; Write-Host $existing.InstallLocation -ForegroundColor Gray
            return
        }
        if ($curVer -gt $newVer) {
            Write-Warn2 '系统中的版本比安装包更新，继续将执行降级。'
            if (-not $Force) {
                $ans = Read-Host '是否继续？输入 Y 确认，其他键取消'
                if ($ans -notmatch '^[Yy]') { Write-Warn2 '已取消。'; return }
            }
            # Supported in-place deployment preserves registration/data if deployment fails.
            # Never fall back to Remove-AppxPackage on older hosts or deployment errors.
            if (-not (Get-Command Add-AppxPackage -ErrorAction Stop).Parameters.ContainsKey('ForceUpdateFromAnyVersion')) {
                throw '当前 Appx 模块不支持 ForceUpdateFromAnyVersion，就地降级不可用；已保留现有应用，未执行卸载。'
            }
            $isDowngrade = $true
            Write-Info '使用 ForceUpdateFromAnyVersion 就地降级，部署失败时不主动卸载原应用。'
        } else {
            Write-Info '将就地升级到新版本。'
        }
    } else {
        Write-Info '系统中尚未安装，执行全新安装。'
    }
    Write-Host ''

    # ---------------------------------------------------------
    # 5. 确保允许旁加载
    # ---------------------------------------------------------
    if ($isAdmin) {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
        try {
            $blocked = $false
            if (Test-Path $key) {
                $v = Get-ItemProperty -Path $key -Name 'AllowAllTrustedApps' -ErrorAction SilentlyContinue
                if ($v -and $v.AllowAllTrustedApps -eq 0) { $blocked = $true }
            }
            if ($blocked) {
                Write-Step '开启“旁加载应用”策略'
                Set-ItemProperty -Path $key -Name 'AllowAllTrustedApps' -Value 1 -Type DWord
                Write-Ok '已允许安装受信任的本地应用包'
                Write-Host ''
            }
        } catch {
            Write-Warn2 "旁加载策略检查失败（可忽略）：$($_.Exception.Message)"
        }
    }

    # ---------------------------------------------------------
    # 6. 为当前用户安装
    # ---------------------------------------------------------
    Write-Step "为当前用户安装（$env:USERNAME）"
    Write-Info '安装包体积较大，请耐心等待 1-5 分钟，期间请勿关闭窗口…'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $installParams = @{
        Path = $msix
        ForceApplicationShutdown = $true
        ErrorAction = 'Stop'
    }
    if ($isDowngrade) { $installParams.ForceUpdateFromAnyVersion = $true }
    if ($target) {
        $installParams.Volume = Initialize-InstallVolume -Target $target -IsAdmin $isAdmin
        if ($existing) { Move-ChatGptToVolume -Package $existing -Target $target }
    }
    Add-AppxPackage @installParams
    $sw.Stop()
    Write-Ok "当前用户安装完成，用时 $([math]::Round($sw.Elapsed.TotalSeconds)) 秒"
    Write-Host ''

    # ---------------------------------------------------------
    # 7. 整机预置（供所有用户使用）
    # ---------------------------------------------------------
    if ($isDowngrade) {
        Write-Warn2 '本次仅降级当前用户，跳过整机预置；其他用户及已有整机预置版本不会被降级。'
    } elseif ($target) {
        Write-Info '已指定安装盘，跳过整机预置，避免再次在系统盘部署。其他用户需各自安装。'
    } elseif ($SkipProvision) {
        Write-Info '已指定 -SkipProvision，跳过整机预置。'
    } elseif (-not $isAdmin) {
        Write-Warn2 '当前没有管理员权限，已跳过整机预置。'
        Write-Info '本机其他用户账户登录后需各自安装一次。'
    } else {
        Write-Step '预置到整机（新用户账户登录即可使用）'
        try {
            $lic = Get-LicensePath
            if ($lic) {
                Write-Info "使用离线授权文件: $(Split-Path -Leaf $lic)"
                Add-AppxProvisionedPackage -Online -PackagePath $msix -LicensePath $lic -ErrorAction Stop | Out-Null
            } else {
                Write-Info '未找到 ChatGPT-License.xml，改用 -SkipLicense 方式预置。'
                Add-AppxProvisionedPackage -Online -PackagePath $msix -SkipLicense -ErrorAction Stop | Out-Null
            }
            Write-Ok '整机预置完成'
        } catch {
            Write-Warn2 "整机预置失败（不影响当前用户使用）：$($_.Exception.Message)"
        }
    }
    Write-Host ''

    # ---------------------------------------------------------
    # 8. 结果校验
    # ---------------------------------------------------------
    Write-Step '校验安装结果'
    $now = Get-InstalledChatGpt
    if (-not $now) { throw '安装命令已执行，但系统中查询不到该应用，安装可能未生效。' }
    if ([version]$now.Version -ne [version]$info.Version) { throw '安装后的版本与目标版本不一致，请检查 Windows 应用部署日志。' }
    if ($target -and -not (Test-PackageOnDrive -Package $now -Drive $target.Drive)) {
        throw "应用已注册，但安装位置不在指定盘 $($target.Drive)：$($now.InstallLocation)"
    }

    Write-Ok "$AppDisplayName $($now.Version) 安装成功"
    Write-Info "安装位置: $($now.InstallLocation)"

    $svc = Get-Service -Name $AppServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Info "沙箱服务: $($svc.Name) [$($svc.Status)]"
        if ($svc.Status -ne 'Running') {
            Write-Info "          此处显示 Stopped 属正常，该服务由应用按需拉起。"
        }
    }

    Write-Host ''
    Write-Host '───────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host ' 现在可以这样启动 ChatGPT：' -ForegroundColor White
    Write-Host '   · 打开「开始」菜单，搜索 ChatGPT' -ForegroundColor Gray
    Write-Host '   · 或按 Win 键后直接输入 chatgpt 回车' -ForegroundColor Gray
    Write-Host '' 
    Write-Host ' 首次启动需要联网登录 OpenAI 账号。' -ForegroundColor DarkGray
    Write-Host '───────────────────────────────────────────────' -ForegroundColor DarkGray

} catch {
    Write-Host ''
    Show-FriendlyError -ErrorRecord $_
    Write-Host ''
    Write-Info "完整日志: $logFile"
    $exitCode = 1
} finally {
    Write-Host ''
    Stop-AppLog
    if (-not $NoPause) {
        Write-Host '按任意键关闭窗口…' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
    }
    try {
        Write-AppResult -Path $ResultPath -Operation 'install' -ExitCode $exitCode -LogPath $logFile
    } catch {
        Write-Err2 "无法写入安装结果：$($_.Exception.Message)"
        $exitCode = 1
    }
    exit $exitCode
}
