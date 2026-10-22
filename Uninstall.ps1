[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Pause-Uninstaller {
    if (-not $NoPause) {
        Write-Host ''
        [void](Read-Host '按回车继续关闭窗口')
    }
}

try {
    $expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'ChatGPT-via-SOT')).TrimEnd('\')
    $actualInstallRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if ($actualInstallRoot -ine $expectedInstallRoot) {
        throw "为避免误删文件，卸载器只能从固定安装目录运行: $expectedInstallRoot"
    }
    $config = Read-PackageConfig -Root $PSScriptRoot
    $expectedTunnelData = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'sot-chatgpt-tunnel')).TrimEnd('\')
    $configuredTunnelData = [IO.Path]::GetFullPath([string]$config.TunnelDataDir).TrimEnd('\')
    if ($configuredTunnelData -ine $expectedTunnelData) {
        throw "独立隧道目录不符合安全检查，卸载未开始: $configuredTunnelData"
    }

    Write-Step '关闭 ChatGPT、独立隧道和 durable 转发器...'
    $stopScript = Join-Path $PSScriptRoot 'Stop-ChatGPT-via-SOT.ps1'
    $stopArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $stopScript),
        '-StopChatGPT', '-NoPause'
    ) -join ' '
    $stopResult = Start-Process -FilePath 'powershell.exe' -ArgumentList $stopArguments -Wait -PassThru
    if ($stopResult.ExitCode -ne 0) {
        Write-Warning '停止脚本返回失败；卸载仍会继续，但不会结束无法确认归属的进程。'
    }

    if ([bool]$config.HostsEntryManaged) {
        Write-Step '请求管理员授权，删除本工具管理的 hosts 区块...'
        $hostsHelper = Join-Path $PSScriptRoot 'Manage-Hosts.ps1'
        $backupDirectory = if ($config.PSObject.Properties.Name -contains 'HostsBackupDir') {
            [string]$config.HostsBackupDir
        } else {
            Join-Path $env:LOCALAPPDATA 'ChatGPT-via-SOT-hosts-backups'
        }
        $helperArguments = @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', (Quote-ProcessArgument $hostsHelper),
            '-Action', 'Remove',
            '-BackupDirectory', (Quote-ProcessArgument $backupDirectory)
        ) -join ' '
        try {
            $helper = Start-Process -FilePath 'powershell.exe' -Verb RunAs `
                -ArgumentList $helperArguments -Wait -PassThru
        } catch {
            throw '管理员授权被取消。为防止 hosts 指向已经删除的转发器，卸载已停止。'
        }
        if ($helper.ExitCode -ne 0) {
            throw ("删除 hosts 区块失败，卸载已停止；辅助程序退出码: {0}" -f $helper.ExitCode)
        }
        Write-Success '本工具管理的 hosts 区块已删除。'
    } else {
        Write-Warning '安装时复用了用户原有的 hosts 映射，因此卸载器不会删除该行。请由原维护者决定是否保留。'
    }

    Write-Step '删除快捷方式和独立隧道数据...'
    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($shortcut in @(
        (Join-Path $desktop 'ChatGPT via SOT.lnk'),
        (Join-Path $desktop '停止 ChatGPT via SOT.lnk')
    )) {
        if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    }
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ChatGPT via SOT'
    if (Test-Path -LiteralPath $startMenu) { Remove-Item -LiteralPath $startMenu -Recurse -Force }

    if (Test-Path -LiteralPath $configuredTunnelData) {
        Remove-Item -LiteralPath $configuredTunnelData -Recurse -Force
        Write-Success '已删除独立隧道目录及其中由本机 SOT 复制的账号配置。'
    }

    Write-Step '安排删除程序目录...'
    $cleanupPath = Join-Path $env:TEMP ("ChatGPT-via-SOT-cleanup-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
    $cleanupSource = @'
param(
    [int]$ProcessToWaitFor,
    [string]$InstallRoot,
    [string]$CleanupScript
)
Wait-Process -Id $ProcessToWaitFor -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    if (-not (Test-Path -LiteralPath $InstallRoot)) { break }
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $InstallRoot)) { break }
    Start-Sleep -Milliseconds 500
}
Remove-Item -LiteralPath $CleanupScript -Force -ErrorAction SilentlyContinue
'@
    [IO.File]::WriteAllText($cleanupPath, $cleanupSource, (New-Object Text.UTF8Encoding($true)))
    $cleanupArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $cleanupPath),
        '-ProcessToWaitFor', [string]$PID,
        '-InstallRoot', (Quote-ProcessArgument $actualInstallRoot),
        '-CleanupScript', (Quote-ProcessArgument $cleanupPath)
    ) -join ' '
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cleanupArguments -WindowStyle Hidden | Out-Null

    Write-Host ''
    Write-Success '卸载步骤已完成，程序目录会在此窗口关闭后删除。'
    Write-Host 'SOT 本体、SOT 原始账号数据和 ChatGPT 均未卸载。hosts 备份保留在 LocalAppData。'
    Pause-Uninstaller
    exit 0
} catch {
    Write-Host ("[卸载失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '为避免留下失效的 hosts 映射，程序目录尚未安排删除。'
    Pause-Uninstaller
    exit 1
}
