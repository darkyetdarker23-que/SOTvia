[CmdletBinding()]
param(
    [string]$SotScriptDir,
    [string]$SotDataDir,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$installRoot = Join-Path $env:LOCALAPPDATA 'ChatGPT-via-SOT'
$targetHost = 'codex-cloud-backend.chatgpt.com'
$socksPort = 1081
$controlPort = 8285
$forwarderPort = 443
$testedAppVersion = '26.1013.4894.0'

function Pause-Installer {
    if (-not $NoPause) {
        Write-Host ''
        [void](Read-Host '按回车关闭窗口')
    }
}

function Copy-PackageFile {
    param([string]$Name)
    $source = Join-Path $PSScriptRoot $Name
    $destination = Join-Path $installRoot $Name
    if (-not (Test-Path -LiteralPath $source)) {
        throw "安装包缺少文件: $Name"
    }
    if ([IO.Path]::GetFullPath($source) -ieq [IO.Path]::GetFullPath($destination)) { return }
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

function Test-PortAvailability {
    param($OldConfig)
    foreach ($port in @($socksPort, $controlPort, $forwarderPort)) {
        foreach ($listener in @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalAddress -in @('127.0.0.1', '0.0.0.0', '::', '::1') })) {
            $expected = $false
            if ($OldConfig) {
                if ($port -eq $forwarderPort) {
                    $expected = Test-ExpectedForwarderProcess -ProcessId $listener.OwningProcess -Config $OldConfig
                } else {
                    $expected = Test-ExpectedTunnelProcess -ProcessId $listener.OwningProcess -Config $OldConfig
                }
            }
            if (-not $expected) {
                $record = Get-ProcessRecord -ProcessId $listener.OwningProcess
                $name = if ($record) { $record.Name } else { '未知进程' }
                throw ("端口 {0} 已由 {1} (pid={2}) 占用，无法安全安装。" -f $port, $name, $listener.OwningProcess)
            }
        }
    }
}

function New-LauncherShortcut {
    param(
        [string]$Path,
        [string]$ScriptName,
        [string]$Description,
        [string]$ExtraArguments = '',
        [string]$IconPath
    )
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $installRoot $ScriptName
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + (Quote-ProcessArgument $scriptPath)
    if ($ExtraArguments) { $arguments += ' ' + $ExtraArguments }
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.WindowStyle = 1
    $shortcut.Description = $Description
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
        $shortcut.IconLocation = $IconPath + ',0'
    }
    $shortcut.Save()
}

try {
    if (-not $env:LOCALAPPDATA -or -not $env:APPDATA) {
        throw '无法读取当前 Windows 用户的 AppData 路径。'
    }

    Write-Step '探测 SOT 安装与当前用户配置...'
    $resolvedSotScriptDir = Find-SotScriptDir -Override $SotScriptDir
    if (-not $resolvedSotScriptDir) {
        throw '未找到 SOT。请先安装并启动 SOT；非默认安装可用 -SotScriptDir 指定 resources\sot-script。'
    }
    $resolvedSotDataDir = Find-SotDataDir -Override $SotDataDir
    if (-not $resolvedSotDataDir) {
        throw '未找到 SOT 登录配置。请先在 SOT 中登录并确认它能正常打开网页。'
    }
    $clientPath = Join-Path $resolvedSotDataDir 'x_tunnel\client.json'
    try {
        $clientConfig = Get-Content -LiteralPath $clientPath -Raw | ConvertFrom-Json
    } catch {
        throw 'SOT 的 x_tunnel\client.json 不是有效 JSON。'
    }
    if (-not $clientConfig) { throw 'SOT 登录配置为空。' }
    Write-Success ("SOT 程序: {0}" -f $resolvedSotScriptDir)
    Write-Success ("SOT 用户数据: {0}" -f $resolvedSotDataDir)

    Write-Step '探测 ChatGPT 桌面端并检查 durable 主机兼容性...'
    $chatgpt = Get-ChatGPTPackageInfo
    if (-not $chatgpt) {
        throw '未找到 Microsoft Store 版 OpenAI.Codex/ChatGPT 桌面端。'
    }
    if (-not (Test-Path -LiteralPath $chatgpt.AsarPath)) {
        throw 'ChatGPT 的 app.asar 不存在，无法进行版本兼容性检查。'
    }
    if (-not (Test-FileContainsAscii -Path $chatgpt.AsarPath -Needle $targetHost)) {
        throw ("当前 ChatGPT {0} 未包含预期主机 {1}；为避免错误转发，安装已停止。" -f $chatgpt.Version, $targetHost)
    }
    Write-Success ("ChatGPT {0} 通过兼容性检查（基准测试版本 {1}）。" -f $chatgpt.Version, $testedAppVersion)

    $oldConfig = $null
    $oldConfigPath = Join-Path $installRoot 'config.json'
    if (Test-Path -LiteralPath $oldConfigPath) {
        try { $oldConfig = Get-Content -LiteralPath $oldConfigPath -Raw | ConvertFrom-Json } catch { $oldConfig = $null }
    }
    Test-PortAvailability -OldConfig $oldConfig

    Write-Step ("安装到 {0}..." -f $installRoot)
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $installRoot 'logs') -Force | Out-Null
    foreach ($name in @(
        'Common.ps1',
        'Manage-Hosts.ps1',
        'Start-ChatGPT-via-SOT.ps1',
        'Stop-ChatGPT-via-SOT.ps1',
        'Start-Browser-via-SOT.ps1',
        'Diagnose.ps1',
        'Diagnose.cmd',
        'Uninstall.ps1',
        'Uninstall.cmd',
        'ws-cloud-forwarder.py',
        'README.md',
        'VERSION.txt'
    )) {
        Copy-PackageFile -Name $name
    }

    Write-Step '请求一次管理员授权，用于备份并更新 hosts...'
    $hostsHelper = Join-Path $installRoot 'Manage-Hosts.ps1'
    # Keep hosts backups outside the program directory so uninstalling the
    # launcher cannot also erase the recovery copy.
    $backupDirectory = Join-Path $env:LOCALAPPDATA 'ChatGPT-via-SOT-hosts-backups'
    $helperArguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $hostsHelper),
        '-Action', 'Add',
        '-BackupDirectory', (Quote-ProcessArgument $backupDirectory)
    ) -join ' '
    try {
        $helper = Start-Process -FilePath 'powershell.exe' -Verb RunAs `
            -ArgumentList $helperArguments -Wait -PassThru
    } catch {
        throw '管理员授权被取消或无法启动；hosts 尚未完成配置。'
    }
    if ($helper.ExitCode -notin @(0, 10)) {
        throw ("hosts 配置失败，辅助程序退出码: {0}" -f $helper.ExitCode)
    }
    $hostsEntryManaged = ($helper.ExitCode -eq 0)

    $config = [ordered]@{
        PackageVersion = $script:PackageVersion
        InstallRoot = $installRoot
        SotScriptDir = $resolvedSotScriptDir
        SotDataDir = $resolvedSotDataDir
        TunnelDataDir = (Join-Path $env:APPDATA 'sot-chatgpt-tunnel')
        SocksPort = $socksPort
        ControlPort = $controlPort
        ForwarderPort = $forwarderPort
        TargetHost = $targetHost
        TestedAppVersion = $testedAppVersion
        DetectedAppVersion = $chatgpt.Version
        HostsEntryManaged = $hostsEntryManaged
        HostsBackupDir = $backupDirectory
        InstalledAt = (Get-Date).ToString('o')
    }
    $configJson = $config | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        (Join-Path $installRoot 'config.json'),
        $configJson,
        (New-Object Text.UTF8Encoding($false))
    )

    # Persist enough state for Uninstall.cmd before doing any remaining
    # validation. If a later step fails, the hosts entry can still be removed
    # safely from the installed directory.
    $addresses = @([Net.Dns]::GetHostAddresses($targetHost))
    if ($addresses.Count -eq 0 -or
        -not ($addresses | Where-Object { $_.IPAddressToString -eq '127.0.0.1' }) -or
        ($addresses | Where-Object { -not (Test-IsLoopbackAddress $_.IPAddressToString) })) {
        throw ("hosts 验证失败：{0} 当前未只解析到本机。请运行 {1} 回滚。" -f `
            $targetHost, (Join-Path $installRoot 'Uninstall.cmd'))
    }
    Write-Success ("hosts 已验证: {0} -> 127.0.0.1" -f $targetHost)

    Write-Step '创建桌面和开始菜单快捷方式...'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ChatGPT via SOT'
    New-Item -ItemType Directory -Path $startMenu -Force | Out-Null

    New-LauncherShortcut -Path (Join-Path $desktop 'ChatGPT via SOT.lnk') `
        -ScriptName 'Start-ChatGPT-via-SOT.ps1' -Description '通过 SOT 独立隧道启动 ChatGPT' `
        -IconPath $chatgpt.ExePath
    New-LauncherShortcut -Path (Join-Path $desktop '停止 ChatGPT via SOT.lnk') `
        -ScriptName 'Stop-ChatGPT-via-SOT.ps1' -Description '停止本工具的隧道与转发器' `
        -ExtraArguments '-StopChatGPT' -IconPath $chatgpt.ExePath

    New-LauncherShortcut -Path (Join-Path $startMenu 'ChatGPT via SOT.lnk') `
        -ScriptName 'Start-ChatGPT-via-SOT.ps1' -Description '通过 SOT 独立隧道启动 ChatGPT' `
        -IconPath $chatgpt.ExePath
    New-LauncherShortcut -Path (Join-Path $startMenu '浏览器 via SOT.lnk') `
        -ScriptName 'Start-Browser-via-SOT.ps1' -Description '通过同一 SOT 隧道打开独立浏览器配置' `
        -IconPath $chatgpt.ExePath
    New-LauncherShortcut -Path (Join-Path $startMenu '停止 ChatGPT via SOT.lnk') `
        -ScriptName 'Stop-ChatGPT-via-SOT.ps1' -Description '停止本工具的隧道与转发器' `
        -ExtraArguments '-StopChatGPT' -IconPath $chatgpt.ExePath
    New-LauncherShortcut -Path (Join-Path $startMenu '诊断 ChatGPT via SOT.lnk') `
        -ScriptName 'Diagnose.ps1' -Description '检查安装、端口、hosts 与连接状态' `
        -IconPath $chatgpt.ExePath
    New-LauncherShortcut -Path (Join-Path $startMenu '卸载 ChatGPT via SOT.lnk') `
        -ScriptName 'Uninstall.ps1' -Description '删除快捷方式、hosts 区块与本工具文件' `
        -IconPath $chatgpt.ExePath

    Write-Host ''
    Write-Success '安装完成。'
    Write-Host '使用顺序：先启动并登录 SOT，然后双击桌面的“ChatGPT via SOT”。'
    Write-Host '启动窗口提示成功后可以关闭；隧道和 ChatGPT 不会因此退出。'
    Write-Host '使用结束后运行“停止 ChatGPT via SOT”；需要彻底移除时从开始菜单运行卸载。'
    Pause-Installer
    exit 0
} catch {
    Write-Host ''
    Write-Host ("[安装失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '安装器不会复制分发者的 SOT 账号；请确认本机 SOT 已登录且端口 443/1081/8285 未被占用。'
    $rollback = Join-Path $installRoot 'Uninstall.cmd'
    if (Test-Path -LiteralPath (Join-Path $installRoot 'config.json')) {
        Write-Host ("安装状态已保存；如不继续排查，请运行 {0} 完整回滚。" -f $rollback)
    }
    Pause-Installer
    exit 1
}
