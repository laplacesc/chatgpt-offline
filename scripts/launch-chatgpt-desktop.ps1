<#
.SYNOPSIS
    安装/卸载入口：请求提权、等待子进程，并核对完成结果。
.DESCRIPTION
    由 .bat 调用。部署仍由原安装/卸载脚本负责；每次使用独立的结果目录，
    即使子进程被外部终止或退出码为零但没有结果，也会报告无法确认完成。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('install', 'uninstall')][string]$Operation,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$PackagePath,
    [string]$InstallDrive,
    [switch]$Force,
    [switch]$SkipProvision,
    [switch]$RemoveUserData,
    [switch]$RemoveCliConfig,
    [switch]$CleanFirewall,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$exitCode = 1
$logFile = ''
$resultDir = $null

try {
    Assert-AppxHost
    $allowed = if ($Operation -eq 'install') {
        @('PackagePath', 'InstallDrive', 'Force', 'SkipProvision')
    } else {
        @('Force', 'RemoveUserData', 'RemoveCliConfig', 'CleanFirewall')
    }
    $scriptPath = Join-Path $PSScriptRoot "$Operation-chatgpt-desktop.ps1"
    $resultDir = Join-Path ([IO.Path]::GetTempPath()) ("chatgpt-task-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $resultDir -ErrorAction Stop
    $childResult = Join-Path $resultDir 'result.json'

    # -EncodedCommand 避免 Start-Process 合并 ArgumentList 时丢失带空格或引号的路径。
    # 所有用户字符串都作为 PowerShell 单引号字面量转义，不拼接可执行的用户代码。
    $originatingUserSid = Get-CurrentAccountSid
    $command = "& '" + $scriptPath.Replace("'", "''") + "' -NoPause -ResultPath '" + $childResult.Replace("'", "''") + "'"
    $command += " -OriginatingUserSid '" + $originatingUserSid.Replace("'", "''") + "'"
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -in @('Operation', 'ResultPath', 'NoPause')) { continue }
        if ($key -notin $allowed) { throw "参数 -$key 不适用于 $Operation 操作。" }
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            $command += " -${key}:`$$([bool]$value)"
        } else {
            $command += " -$key '" + ([string]$value).Replace("'", "''") + "'"
        }
    }
    $command += '; exit $LASTEXITCODE'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $startParams = @{
        FilePath = (Join-Path $PSHOME 'powershell.exe')
        ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $encoded)
        WorkingDirectory = $RootDir
        Wait = $true
        PassThru = $true
        ErrorAction = 'Stop'
    }
    if (-not (Test-IsAdmin)) {
        Write-Info '正在请求管理员权限；任务结束前请保持此窗口打开。'
        $startParams.Verb = 'RunAs'
    }
    $process = Start-Process @startParams
    if (-not (Test-Path -LiteralPath $childResult)) {
        throw '未能确认安装/卸载任务完成：子进程没有写出结果，可能未能运行或被环境中断。请重试；仍失败请右键 .bat 选择“以管理员身份运行”，并检查 log 目录。'
    }
    $result = Get-Content -LiteralPath $childResult -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($result.Operation -ne $Operation -or
        ($result.ExitCode -isnot [int] -and $result.ExitCode -isnot [long]) -or
        $result.ExitCode -lt 0 -or $result.ExitCode -gt 255) {
        throw '未能确认任务完成：子进程结果文件无效，请检查 log 目录。'
    }
    $logFile = [string]$result.LogPath
    if ($null -ne $process.ExitCode -and $process.ExitCode -ne $result.ExitCode) {
        throw '未能确认任务完成：进程与结果文件的退出码不一致，任务可能被环境中断，请检查日志后重试。'
    }
    $exitCode = $result.ExitCode
    if ($exitCode -ne 0) {
        Write-Err2 '安装/卸载任务失败，请查看日志中的具体原因。'
    } else {
        Write-Ok '任务已结束，结果已确认。'
    }
} catch {
    if ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) {
        Write-Err2 '已取消管理员授权（UAC），任务未执行。请重试并确认权限提示。'
    } else {
        Write-Err2 "启动或提权任务失败：$($_.Exception.Message)"
    }
    $exitCode = 1
} finally {
    if ($logFile) { Write-Info "完整日志: $logFile" }
    if ($resultDir -and (Test-Path -LiteralPath $resultDir)) {
        Remove-Item -LiteralPath $resultDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    try {
        Write-AppResult -Path $ResultPath -Operation $Operation -ExitCode $exitCode -LogPath $logFile
    } catch {
        Write-Err2 "无法写入启动器结果：$($_.Exception.Message)"
        $exitCode = 1
    }
    exit $exitCode
}
