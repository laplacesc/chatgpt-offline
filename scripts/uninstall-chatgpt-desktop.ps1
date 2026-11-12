<#
.SYNOPSIS
    彻底卸载 ChatGPT 桌面版（MSIX），并清理常见残留。

.DESCRIPTION
    依次执行：结束进程 → 取消整机预置 → 移除所有用户的应用包 →
    删除残留的沙箱服务 → 清理执行别名。默认不主动清理 OpenAI 目录和 CLI 配置；
    Windows 仍可能随卸载删除打包应用数据目录，登录状态不保证保留。

.PARAMETER Force
    不再逐项确认，直接执行。

.PARAMETER RemoveUserData
    同时删除应用数据目录（登录状态、缓存、设置会全部丢失）。

.PARAMETER RemoveCliConfig
    同时删除 Codex CLI 配置目录 %USERPROFILE%\.codex。

.PARAMETER CleanFirewall
    保留兼容参数。本工具未创建防火墙规则、没有规则管理记录，因此保留全部现有规则并提示。

.PARAMETER NoPause
    结束时不等待按键。

.PARAMETER ResultPath
    启动器使用的完成结果文件，记录退出码和日志位置。

.EXAMPLE
    .\uninstall-chatgpt-desktop.ps1
    .\uninstall-chatgpt-desktop.ps1 -Force -RemoveUserData -CleanFirewall
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $RemoveUserData,
    [switch] $RemoveCliConfig,
    [switch] $CleanFirewall,
    [switch] $NoPause,
    [string] $ResultPath,
    [string] $OriginatingUserSid
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# Return an object only when Get-Service can read the service. An empty/error result
# is never treated as absence until the independent SCM query reports ERROR_SERVICE_DOES_NOT_EXIST.
function Get-UninstallService {
    param([Parameter(Mandatory)][string]$Name)
    $managedError = 'Get-Service 未返回服务对象'
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service) { return $service }
    } catch {
        $managedError = $_.Exception.Message
    }
    $queryOut = & sc.exe query $Name 2>&1
    $queryCode = $LASTEXITCODE
    if ($queryCode -eq 1060) { return $null }
    throw "无法确认服务 $Name 不存在，已停止服务清理。Get-Service: $managedError；sc.exe query=$queryCode ($queryOut)"
}

$logFile  = Start-AppLog -Name 'uninstall'
$exitCode = 0
$removed  = @()
$failed   = @()

try {
    Write-Banner 'ChatGPT 桌面版 · 卸载与清理'
    Assert-AppxHost
    Assert-OriginatingAccount -OriginatingUserSid $OriginatingUserSid

    $isAdmin = Test-IsAdmin
    if (-not $isAdmin) {
        Write-Warn2 '当前没有管理员权限：只能卸载当前用户的安装，整机预置与系统服务无法清理。'
        Write-Host ''
    }

    # ---------------------------------------------------------
    # 1. 盘点
    # ---------------------------------------------------------
    Write-Step '检查安装状态'

    $pkgs = @(Get-InstalledChatGpt -AllUsers:$isAdmin)
    # Capture verified package roots before Windows removes the packages.
    $installRoots = @($pkgs | ForEach-Object { [string]$_.InstallLocation } | Where-Object { $_ })
    $prov = @()
    $provisionQueryFailed = $false
    if ($isAdmin) {
        try {
            $prov = @(Get-ProvisionedChatGpt)
        } catch {
            $provisionQueryFailed = $true
            Write-Warn2 "未能读取整机预置状态，卸载后将复查：$($_.Exception.Message)"
        }
    }
    $svc = Get-UninstallService -Name $AppServiceName

    if ($pkgs.Count -eq 0 -and $prov.Count -eq 0 -and -not $svc -and -not $provisionQueryFailed) {
        Write-Ok '系统中没有检测到 ChatGPT 桌面版，无需卸载。'
        Write-Info '如仅想清理残留数据，可加 -RemoveUserData 或 -RemoveCliConfig 参数重新运行。'
        if (-not ($RemoveUserData -or $RemoveCliConfig -or $CleanFirewall)) { return }
    } else {
        foreach ($p in $pkgs) { Write-Info "应用包    : $($p.PackageFullName)" }
        if ($prov.Count -gt 0) { Write-Info "整机预置  : $($prov.Count) 项" }
        if ($svc)              { Write-Info "系统服务  : $($svc.Name) [$($svc.Status)]" }
    }
    if ($svc -and $svc.PSObject.Methods['Dispose']) { $svc.Dispose() }
    $svc = $null
    Write-Host ''

    # ---------------------------------------------------------
    # 2. 确认
    # ---------------------------------------------------------
    if (-not $Force) {
        Write-Host '即将执行的操作：' -ForegroundColor White
        Write-Host '  · 卸载 ChatGPT 桌面版应用包' -ForegroundColor Gray
        Write-Host '  · 清理整机预置与残留的沙箱服务' -ForegroundColor Gray
        Write-Host ("  · OpenAI 数据目录: " + $(if ($RemoveUserData) { '一并删除' } else { '脚本不主动删除' })) -ForegroundColor Gray
        Write-Host '  · Windows 可能随卸载删除打包应用数据目录，登录状态不保证保留。' -ForegroundColor Yellow
        Write-Host ("  · Codex CLI 配置 (~/.codex): "  + $(if ($RemoveCliConfig) { '一并删除' } else { '保留' })) -ForegroundColor Gray
        Write-Host '  · 防火墙规则: 保留（本工具未创建或记录受管规则）' -ForegroundColor Gray
        Write-Host ''
        $ans = Read-Host '确认继续？输入 Y 开始卸载，其他键取消'
        if ($ans -notmatch '^[Yy]') { Write-Warn2 '已取消，未做任何改动。'; return }
        Write-Host ''
    }

    # ---------------------------------------------------------
    # 3. 结束进程
    # ---------------------------------------------------------
    Write-Step '结束正在运行的进程'
    $names = @('ChatGPT', 'codex', 'chrome_proxy', 'codex-command-runner',
               'codex-windows-sandbox-service', 'extension-host')
    $killed = 0
    foreach ($n in $names) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if (Test-AppOwnedPath -Path $_.Path -InstallRoots $installRoots) {
                    Stop-Process -Id $_.Id -Force -ErrorAction Stop
                    $killed++
                }
            } catch { Write-Info '跳过无法确认路径或无法结束的进程。' }
        }
    }
    if ($killed -gt 0) {
        Write-Ok "已结束 $killed 个进程"
        Start-Sleep -Seconds 2
    } else {
        Write-Info '没有正在运行的相关进程'
    }
    Write-Host ''

    # ---------------------------------------------------------
    # 4. 先取消整机预置，避免卸载包后预置引用的源文件已被删除
    # ---------------------------------------------------------
    if ($prov.Count -gt 0) {
        Write-Step '取消整机预置'
        foreach ($p in $prov) {
            try {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -ErrorAction Stop | Out-Null
                } catch [System.Management.Automation.ParameterBindingException] {
                    Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null
                }
                Write-Ok "已移除预置 $($p.PackageName)"
                $removed += '整机预置'
            } catch {
                # Windows 可能并发/异步清理预置。保留原始诊断，以最终查询状态判定。
                Write-Warn2 "预置移除命令未能确认完成，将在卸载后复查：$($_.Exception.Message)"
            }
        }
        Write-Host ''
    }

    # ---------------------------------------------------------
    # 5. 卸载应用包
    # ---------------------------------------------------------
    if ($pkgs.Count -gt 0) {
        Write-Step '卸载应用包'
        foreach ($p in $pkgs) {
            try {
                if ($isAdmin) {
                    Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                } else {
                    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                }
                Write-Ok "已卸载 $($p.PackageFullName)"
                $removed += '应用包'
            } catch {
                Write-Err2 "卸载失败: $($p.PackageFullName)"
                Write-Info $_.Exception.Message
                $failed += '应用包'
            }
        }
        Write-Host ''
    }

    # Package removal must be confirmed BEFORE treating services, aliases or data as residue.
    # For a non-admin run, current-user absence cannot prove machine-wide service ownership.
    $remaining = @(Get-InstalledChatGpt -AllUsers:$isAdmin)
    if ($remaining.Count -gt 0) {
        throw '应用包仍存在，已保留服务、执行别名及数据；卸载未完成，请检查日志后重试。'
    }

    # ---------------------------------------------------------
    # 6. 清理残留服务（卸载后偶尔会留下"幽灵服务"）
    # ---------------------------------------------------------
    Write-Step '检查残留系统服务'
    try {
        $svc = Get-UninstallService -Name $AppServiceName
        if ($svc) {
            if (-not $isAdmin) { throw '系统服务仍存在，当前没有管理员权限，无法清理。' }
            if ($svc.Status -ne 'Stopped') {
                Stop-Service -Name $AppServiceName -Force -ErrorAction Stop
            }
            if ($svc.PSObject.Methods['Dispose']) { $svc.Dispose() }
            $svc = $null
            $out = & sc.exe delete $AppServiceName 2>&1
            $deleteCode = $LASTEXITCODE
            $queryOut = & sc.exe query $AppServiceName 2>&1
            $queryCode = $LASTEXITCODE
            if ($queryCode -eq 1060) {
                Write-Ok "已确认残留服务不存在：$AppServiceName"
                $removed += '沙箱服务'
            } elseif (($deleteCode -eq 0 -or $deleteCode -eq 1072) -and
                      ($queryCode -eq 0 -or $queryCode -eq 1072)) {
                Write-Warn2 '服务已标记删除但尚未消失；请关闭占用服务句柄的程序或重启后重试。'
                $failed += '沙箱服务（等待删除）'
            } else {
                Write-Err2 "服务清理失败：delete=$deleteCode ($out)，query=$queryCode ($queryOut)"
                $failed += '沙箱服务'
            }
        } else {
            Write-Info '已通过 sc.exe query 确认没有残留服务（1060）'
        }
    } catch {
        Write-Warn2 "处理服务时出错: $($_.Exception.Message)"
        $failed += '沙箱服务'
    } finally {
        if ($svc -and $svc.PSObject.Methods['Dispose']) { $svc.Dispose() }
    }
    Write-Host ''

    # ---------------------------------------------------------
    # 7. 清理执行别名
    # ---------------------------------------------------------
    Write-Step '清理命令行执行别名'
    $aliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    $aliases  = @('codex-chrome-native-host.exe', 'codex-core-command-runner.exe')
    $aliasHit = 0
    foreach ($a in $aliases) {
        $ap = Join-Path $aliasDir $a
        if (Test-Path -LiteralPath $ap) {
            try { Remove-Item -LiteralPath $ap -Force -ErrorAction Stop; $aliasHit++ } catch { }
        }
    }
    if ($aliasHit -gt 0) { Write-Ok "已清理 $aliasHit 个执行别名" } else { Write-Info '没有残留别名' }
    Write-Host ''

    # ---------------------------------------------------------
    # 8. 可选：应用数据
    # ---------------------------------------------------------
    if ($RemoveUserData) {
        Write-Step '删除应用数据'
        $dataDirs = @(
            (Join-Path $env:LOCALAPPDATA "Packages\$AppFamilyName"),
            (Join-Path $env:LOCALAPPDATA 'OpenAI')
        )
        foreach ($d in $dataDirs) {
            if (Test-Path -LiteralPath $d) {
                try {
                    Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                    Write-Ok "已删除 $d"
                    $removed += '应用数据'
                } catch {
                    Write-Warn2 "删除失败 $d"
                    Write-Info $_.Exception.Message
                    $failed += '应用数据'
                }
            }
        }
        Write-Host ''
    }

    # ---------------------------------------------------------
    # 9. 可选：CLI 配置
    # ---------------------------------------------------------
    if ($RemoveCliConfig) {
        Write-Step '删除 Codex CLI 配置'
        $cli = Join-Path $env:USERPROFILE '.codex'
        if (Test-Path -LiteralPath $cli) {
            try {
                Remove-Item -LiteralPath $cli -Recurse -Force -ErrorAction Stop
                Write-Ok "已删除 $cli"
                $removed += 'CLI 配置'
            } catch {
                Write-Warn2 "删除失败：$($_.Exception.Message)"
                $failed += 'CLI 配置'
            }
        } else {
            Write-Info '没有 CLI 配置目录'
        }
        Write-Host ''
    }

    # ---------------------------------------------------------
    # 10. 可选：防火墙规则
    # ---------------------------------------------------------
    if ($CleanFirewall) {
        Write-Step '保留防火墙规则'
        # This tool has never created rules and has no managed-rule inventory. Program,
        # package, name and action identify a target/policy, not ownership by this tool.
        Write-Info '本工具未创建防火墙规则，也没有规则管理记录；已保留全部现有防火墙规则。'
        Write-Info '-CleanFirewall 参数继续兼容；如需调整规则，请在 Windows 防火墙中自行检查。'
        Write-Host ''
    }

    # ---------------------------------------------------------
    # 11. 汇总
    # ---------------------------------------------------------
    Write-Step '复查卸载结果'
    $left = @(Get-InstalledChatGpt -AllUsers:$isAdmin)
    if ($left.Count -eq 0) {
        $failed = @($failed | Where-Object { $_ -ne '应用包' })
        Write-Ok '应用包已移除'
    } else {
        Write-Warn2 "仍有 $($left.Count) 个包未移除，可能被其他已登录用户占用，重启后再运行一次本脚本。"
        $exitCode = 1
    }
    if ($isAdmin) {
        # 不把查询失败当作空结果；短暂残留再查一次，仍残留则返回非零退出码。
        $leftProv = @(Get-ProvisionedChatGpt)
        if ($leftProv.Count -gt 0) {
            Write-Info '整机预置仍在清理中，稍后复查一次。'
            Start-Sleep -Seconds 1
            $leftProv = @(Get-ProvisionedChatGpt)
        }
        if ($leftProv.Count -gt 0) {
            Write-Warn2 "仍有 $($leftProv.Count) 个整机预置条目未移除，请稍后重试并检查日志。"
            $failed += '整机预置'
            $exitCode = 1
        } else {
            Write-Ok '整机预置已清除'
            if ($prov.Count -gt 0) { $removed += '整机预置' }
        }
    }
    if ($failed.Count -gt 0) { $exitCode = 1 }
    if ($exitCode -eq 0) { Write-Ok 'ChatGPT 桌面版卸载完成' }

    Write-Host ''
    Write-Host '───────────────────────────────────────────────' -ForegroundColor DarkGray
    if ($removed.Count -gt 0) {
        Write-Host (' 已清理: ' + (($removed | Select-Object -Unique) -join '、')) -ForegroundColor Gray
    }
    if ($failed.Count -gt 0) {
        Write-Host (' 未完成: ' + (($failed  | Select-Object -Unique) -join '、')) -ForegroundColor Yellow
    }
    if (-not $RemoveUserData) {
        Write-Host ' 提示: 脚本未主动删除 %LOCALAPPDATA%\OpenAI，Windows 可能随卸载删除打包应用数据目录。' -ForegroundColor DarkGray
        Write-Host '       登录状态不保证保留；如需清理 OpenAI 目录，请加 -RemoveUserData。' -ForegroundColor DarkGray
    }
    if (-not $RemoveCliConfig) { Write-Host ' Codex CLI 配置 (~/.codex) 未主动删除。' -ForegroundColor DarkGray }
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
        Write-AppResult -Path $ResultPath -Operation 'uninstall' -ExitCode $exitCode -LogPath $logFile
    } catch {
        Write-Err2 "无法写入卸载结果：$($_.Exception.Message)"
        $exitCode = 1
    }
    exit $exitCode
}
