<#
.SYNOPSIS
    从 OpenAI 官方源下载 ChatGPT 桌面版 MSIX 安装包及离线授权文件。

.DESCRIPTION
    优先使用系统自带的 curl.exe，其次 BITS。
    固定下载地址可能指向新版本；未确认资源身份时从头下载，避免拼接不同版本。
    下载到临时文件，校验大小、包身份、架构和数字签名后才保存为安装包。

.PARAMETER Arch
    目标架构：auto（默认，跟随当前系统）、x64、arm64。

.PARAMETER OutDir
    输出目录，默认为仓库的 pkg\ 目录。

.PARAMETER Force
    已存在同名文件时重新下载（而不是校验后复用）。

.PARAMETER NoPause
    结束时不等待按键。

.EXAMPLE
    .\download-chatgpt-msix.ps1
    .\download-chatgpt-msix.ps1 -Arch arm64 -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'x64', 'arm64')]
    [string] $Arch = 'auto',
    [string] $OutDir,
    [switch] $Force,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$logFile  = Start-AppLog -Name 'download'
$exitCode = 0
$downloadDirectory = $null

function Get-RemoteSize {
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method  = 'HEAD'
        $req.Timeout = 30000
        $resp = $req.GetResponse()
        try { return [int64]$resp.ContentLength } finally { $resp.Close() }
    } catch { return [int64]-1 }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        Write-Info '下载引擎: curl.exe'
        # 不传 -C：URL 和文件大小都不能证明本地片段属于当前资源。
        $args = @('-L', '--fail', '--retry', '3', '--retry-delay', '2',
                  '--connect-timeout', '30', '--progress-bar', '-o', $Destination, $Url)
        & $curl @args
        if ($LASTEXITCODE -ne 0) { throw "curl 下载失败，退出码 $LASTEXITCODE。" }
        return
    }

    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Write-Info '下载引擎: BITS'
        Start-BitsTransfer -Source $Url -Destination $Destination -Description 'ChatGPT MSIX' -ErrorAction Stop
        return
    }

    Write-Info '下载引擎: Invoke-WebRequest（无进度显示，请耐心等待）'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
}

function Get-VerifiedDownload {
    param([string]$Path, [string]$ExpectedArch)
    $info = Get-MsixInfo -Path $Path
    $sig = Test-MsixSignature -Path $Path
    Assert-TrustedMsixIdentity -Info $info -Signature $sig
    if ($info.Architecture -ne $ExpectedArch) {
        throw "安装包架构不符：期望 $ExpectedArch，实际 $($info.Architecture)。"
    }
    return [pscustomobject]@{
        Info = $info
        Signature = $sig
        Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

try {
    Write-Banner 'ChatGPT 桌面版 · 下载安装包'

    # 1. 目标架构
    if ($Arch -eq 'auto') {
        $Arch = Get-SystemArch
        if ($Arch -eq 'x86') { throw 'ChatGPT 桌面版不支持 32 位系统。' }
        Write-Info "自动识别架构: $Arch"
    } else {
        Write-Info "指定架构: $Arch"
    }

    $url = if ($Arch -eq 'arm64') { $UrlMsixArm64 } else { $UrlMsixX64 }

    # 2. 输出目录
    if (-not $OutDir) { $OutDir = $PkgDir }
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
    $dest   = Join-Path $OutDir "ChatGPT-$Arch.msix"

    Write-Info "下载地址: $url"
    Write-Info "保存位置: $dest"
    Write-Host ''

    # 3. 查询远端大小。HEAD 仅用于长度检查，不作为资源身份或版本凭据。
    Write-Step '查询官方安装包信息'
    $remoteSize = Get-RemoteSize -Url $url
    if ($remoteSize -gt 0) {
        Write-Info "官方文件大小: $(Format-Size $remoteSize)"
    } else {
        Write-Warn2 '无法获取文件大小（不影响下载），请检查网络是否可以访问 oaistatic.com。'
    }

    # 4. 已有文件必须通过完整校验后才能复用，损坏的同大小文件会自动重下。
    $verified = $null
    if (Test-Path -LiteralPath $dest) {
        $local = (Get-Item -LiteralPath $dest).Length
        Write-Info "本地已有文件: $(Format-Size $local)"
        if (-not $Force -and $remoteSize -gt 0 -and $local -eq $remoteSize) {
            try {
                $verified = Get-VerifiedDownload -Path $dest -ExpectedArch $Arch
                Write-Ok '本地安装包已通过身份、架构和签名校验，复用已有文件。'
                Write-Info '相同大小不代表远端版本相同；需要更新到当前官方版本时请使用 -Force。'
            } catch {
                Write-Warn2 "本地安装包校验失败，将从头下载：$($_.Exception.Message)"
            }
        }
        if (-not $verified) {
            Write-Warn2 '已有文件无法复用，将从头下载；新包校验通过前保留已有文件。'
        }
    }
    Write-Host ''

    # 5. 每次下载使用独立临时文件；失败或中断的内容不会成为可安装的 MSIX。
    # Keep the .msix extension for Windows SIP, outside Resolve-MsixPath's search directory.
    $downloadDirectory = Join-Path $OutDir ("ChatGPT-$Arch.$([guid]::NewGuid().ToString('N')).download")
    $null = New-Item -ItemType Directory -Path $downloadDirectory -ErrorAction Stop
    if (-not $verified) {
        Write-Step "下载安装包（约 $(if ($remoteSize -gt 0) { Format-Size $remoteSize } else { '800 MB' })）"
        Write-Info '文件较大，请保持网络通畅；中断后重新运行会从头下载。'
        Write-Host ''
        $downloadPath = Join-Path $downloadDirectory "ChatGPT-$Arch.msix"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-Download -Url $url -Destination $downloadPath
        $sw.Stop()

        Write-Host ''
        $got = (Get-Item -LiteralPath $downloadPath).Length
        $sec = [math]::Max($sw.Elapsed.TotalSeconds, 1)
        Write-Info "下载完成: $(Format-Size $got)，用时 $([math]::Round($sw.Elapsed.TotalMinutes,1)) 分钟（平均 $(Format-Size ($got/$sec))/s）"
        if ($remoteSize -gt 0 -and $got -ne $remoteSize) {
            throw "文件大小不符：期望 $(Format-Size $remoteSize)，实际 $(Format-Size $got)。远端文件可能已更新，请重新运行以从头下载。"
        }
        Write-Step '校验安装包'
        $verified = Get-VerifiedDownload -Path $downloadPath -ExpectedArch $Arch
        Move-Item -LiteralPath $downloadPath -Destination $dest -Force -ErrorAction Stop
    }

    $info = $verified.Info
    $sig = $verified.Signature
    Write-Info "包标识: $($info.Name) $($info.Version) [$($info.Architecture)]"
    Write-Info "显示名: $($info.DisplayName)"
    Write-Info "签名主体: $($sig.Subject)"
    Write-Ok '包身份、架构和数字签名有效'
    Write-Info "SHA256: $($verified.Hash)"
    Write-Host ''

    # 6. 授权文件
    Write-Step '下载离线授权文件'
    $licDest = Join-Path $OutDir 'ChatGPT-License.xml'
    $licTemp = Join-Path $downloadDirectory 'ChatGPT-License.xml'
    try {
        Invoke-WebRequest -Uri $UrlLicense -OutFile $licTemp -UseBasicParsing -ErrorAction Stop
        if (-not (Get-LicensePath -Path $licTemp)) { throw '授权文件不是有效的 License XML。' }
        Move-Item -LiteralPath $licTemp -Destination $licDest -Force -ErrorAction Stop
        Write-Ok "已保存 ChatGPT-License.xml（$(Format-Size (Get-Item -LiteralPath $licDest).Length)）"
    } catch {
        Write-Warn2 "授权文件下载失败：$($_.Exception.Message)"
        if (Get-LicensePath -Path $licDest) {
            Write-Info '保留已有的有效离线授权文件。'
        } else {
            Write-Info '没有有效授权文件，安装脚本会改用 -SkipLicense 方式。'
        }
    }

    Write-Host ''
    Write-Host '───────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host ' 安装包已就绪。' -ForegroundColor White
    Write-Host ' 接下来双击运行「安装ChatGPT桌面版.bat」即可完成安装。' -ForegroundColor Gray
    Write-Host '───────────────────────────────────────────────' -ForegroundColor DarkGray

} catch {
    Write-Host ''
    Show-FriendlyError -ErrorRecord $_
    Write-Host ''
    Write-Info "完整日志: $logFile"
    $exitCode = 1
} finally {
    if ($downloadDirectory -and (Test-Path -LiteralPath $downloadDirectory)) {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Stop-AppLog
    if (-not $NoPause) {
        Write-Host '按任意键关闭窗口…' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { Read-Host | Out-Null }
    }
    exit $exitCode
}
