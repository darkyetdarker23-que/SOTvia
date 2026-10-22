[CmdletBinding()]
param([switch]$NoPause)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$script:FailureCount = 0
$script:WarningCount = 0

function Write-Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')][string]$Status,
        [string]$Message
    )
    $color = switch ($Status) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    if ($Status -eq 'FAIL') { $script:FailureCount++ }
    if ($Status -eq 'WARN') { $script:WarningCount++ }
    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Get-ListenerSummary {
    param([int]$Port)
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0) { return @() }
    return @($listeners | ForEach-Object {
        $record = Get-ProcessRecord -ProcessId $_.OwningProcess
        [pscustomobject]@{
            Address = $_.LocalAddress
            Port = $_.LocalPort
            ProcessId = $_.OwningProcess
            Name = if ($record) { $record.Name } else { '未知' }
            CommandLine = if ($record) { [string]$record.CommandLine } else { '' }
        }
    })
}

try {
    Write-Host 'ChatGPT via SOT 诊断报告' -ForegroundColor Cyan
    Write-Host ("时间: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
    Write-Host ''

    $config = Read-PackageConfig -Root $PSScriptRoot
    Write-Check OK ("配置版本 {0}，安装目录 {1}" -f $config.PackageVersion, $config.InstallRoot)

    $python = Join-Path ([string]$config.SotScriptDir) 'python3\python.exe'
    $startPy = Join-Path ([string]$config.SotScriptDir) 'code\default\launcher\start.py'
    if ((Test-Path -LiteralPath $python) -and (Test-Path -LiteralPath $startPy)) {
        Write-Check OK ("SOT 运行组件存在: {0}" -f $config.SotScriptDir)
    } else {
        Write-Check FAIL 'SOT 运行组件缺失；SOT 可能被移动、升级或卸载，请重跑 Install.cmd。'
    }

    $sourceClient = Join-Path ([string]$config.SotDataDir) 'x_tunnel\client.json'
    if (Test-Path -LiteralPath $sourceClient) {
        try {
            [void](Get-Content -LiteralPath $sourceClient -Raw | ConvertFrom-Json)
            Write-Check OK '本机 SOT 登录配置存在且 JSON 有效（诊断不会显示账号内容）。'
        } catch {
            Write-Check FAIL '本机 SOT 登录配置不是有效 JSON。'
        }
    } else {
        Write-Check FAIL '未找到本机 SOT 登录配置，请先在 SOT 中登录。'
    }
    if (Get-Process -Name SOT -ErrorAction SilentlyContinue) {
        Write-Check OK 'SOT 本体正在运行。'
    } else {
        Write-Check WARN 'SOT 本体未运行；启动 ChatGPT via SOT 前应先启动并登录 SOT。'
    }

    $chatgpt = Get-ChatGPTPackageInfo
    if (-not $chatgpt) {
        Write-Check FAIL '未找到 Microsoft Store 版 OpenAI.Codex/ChatGPT。'
    } else {
        Write-Check OK ("ChatGPT 版本 {0}: {1}" -f $chatgpt.Version, $chatgpt.ExePath)
        if (Test-FileContainsAscii -Path $chatgpt.AsarPath -Needle ([string]$config.TargetHost)) {
            Write-Check OK '当前 app.asar 仍包含预期 durable 主机。'
        } else {
            Write-Check FAIL 'ChatGPT 更新后不再包含预期 durable 主机；请停止使用并更新本工具。'
        }
    }

    try {
        $addresses = @([Net.Dns]::GetHostAddresses([string]$config.TargetHost))
        $addressText = (($addresses | ForEach-Object { $_.IPAddressToString }) -join ', ')
        if ($addresses.Count -gt 0 -and
            ($addresses | Where-Object { $_.IPAddressToString -eq '127.0.0.1' }) -and
            -not ($addresses | Where-Object { -not (Test-IsLoopbackAddress $_.IPAddressToString) })) {
            Write-Check OK ("hosts/DNS: {0} -> {1}" -f $config.TargetHost, $addressText)
        } else {
            Write-Check FAIL ("hosts/DNS 不正确: {0} -> {1}" -f $config.TargetHost, $addressText)
        }
    } catch {
        Write-Check FAIL ("无法解析 durable 主机: {0}" -f $_.Exception.Message)
    }

    $tunnelOnline = $false
    foreach ($port in @([int]$config.SocksPort, [int]$config.ControlPort)) {
        $listeners = @(Get-ListenerSummary -Port $port)
        if ($listeners.Count -eq 0) {
            Write-Check INFO ("端口 {0} 当前未监听；尚未启动或已经正常停止。" -f $port)
            continue
        }
        foreach ($listener in $listeners) {
            if (Test-ExpectedTunnelProcess -ProcessId $listener.ProcessId -Config $config) {
                Write-Check OK ("隧道端口 {0} 由预期进程监听: pid={1}" -f $port, $listener.ProcessId)
                if ($port -eq [int]$config.SocksPort) { $tunnelOnline = $true }
            } else {
                Write-Check FAIL ("端口 {0} 被非本工具进程占用: {1} pid={2}" -f $port, $listener.Name, $listener.ProcessId)
            }
        }
    }

    $forwarderOnline = $false
    $forwarderListeners = @(Get-ListenerSummary -Port ([int]$config.ForwarderPort))
    if ($forwarderListeners.Count -eq 0) {
        Write-Check INFO ("转发端口 {0} 当前未监听；停止代理后这是正常状态。" -f $config.ForwarderPort)
    } else {
        foreach ($listener in $forwarderListeners) {
            if (Test-ExpectedForwarderProcess -ProcessId $listener.ProcessId -Config $config) {
                Write-Check OK ("durable 转发器正在监听 127.0.0.1:{0}, pid={1}" -f $config.ForwarderPort, $listener.ProcessId)
                $forwarderOnline = $true
            } else {
                Write-Check FAIL ("端口 {0} 被非本工具进程占用: {1} pid={2}" -f $config.ForwarderPort, $listener.Name, $listener.ProcessId)
            }
        }
    }

    if ($tunnelOnline) {
        try {
            $proxy = "http://127.0.0.1:{0}" -f $config.SocksPort
            $ipResult = Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -Proxy $proxy -TimeoutSec 15
            if ($ipResult.ip) {
                Write-Check OK ("经 SOT 隧道探测到的公网 IP: {0}" -f $ipResult.ip)
            } else {
                Write-Check WARN '公网 IP 检查返回了未知格式。'
            }
        } catch {
            Write-Check WARN ("隧道公网 IP 检查失败: {0}" -f $_.Exception.Message)
        }
    }

    $chatgptProcesses = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    if ($chatgptProcesses.Count -eq 0) {
        Write-Check INFO 'ChatGPT 当前未运行。'
    } else {
        $chatgptIdSet = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($process in $chatgptProcesses) {
            foreach ($processId in @(Get-DescendantProcessIds -RootProcessId $process.Id)) {
                [void]$chatgptIdSet.Add([int]$processId)
            }
        }
        $chatgptIds = @($chatgptIdSet)
        $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -in $chatgptIds -and $_.State -notin @('Bound', 'Listen') })
        $proxyConnections = @($connections | Where-Object {
            $_.RemoteAddress -eq '127.0.0.1' -and $_.RemotePort -eq [int]$config.SocksPort
        })
        $durableConnections = @($connections | Where-Object {
            $_.RemoteAddress -eq '127.0.0.1' -and $_.RemotePort -eq [int]$config.ForwarderPort
        })
        $directConnections = @($connections | Where-Object { -not (Test-IsLoopbackAddress $_.RemoteAddress) })
        Write-Check INFO ("ChatGPT TCP: 代理={0}, durable 本地={1}, 外网直连={2}" -f `
            $proxyConnections.Count, $durableConnections.Count, $directConnections.Count)
        if ($directConnections.Count -gt 0) {
            $endpoints = @($directConnections | ForEach-Object {
                "{0}:{1}" -f $_.RemoteAddress, $_.RemotePort
            } | Select-Object -Unique)
            Write-Check FAIL ("发现 ChatGPT 外网直连: {0}" -f ($endpoints -join ', '))
        } else {
            Write-Check OK '未发现 ChatGPT 进程的外网直连 TCP。'
        }
        if ($forwarderOnline -and $durableConnections.Count -eq 0) {
            Write-Check WARN '转发器在线，但当前未观察到 ChatGPT 到 127.0.0.1:443 的 durable TCP。'
        }
    }

    $logRoot = Join-Path $env:LOCALAPPDATA 'Codex\Logs'
    if (Test-Path -LiteralPath $logRoot) {
        $recentLogs = @(Get-ChildItem -LiteralPath $logRoot -Recurse -File -Filter '*.log' `
            -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 12)
        $lastConnected = $null
        $lastTimeout = $null
        foreach ($log in $recentLogs) {
            if (-not $lastConnected) {
                $lastConnected = Select-String -LiteralPath $log.FullName `
                    -Pattern 'hostId=durable.*next=connected' -ErrorAction SilentlyContinue | Select-Object -Last 1
            }
            if (-not $lastTimeout) {
                $lastTimeout = Select-String -LiteralPath $log.FullName `
                    -Pattern 'hostId=durable.*(open_timeout|pong_timeout)' -ErrorAction SilentlyContinue | Select-Object -Last 1
            }
        }
        if ($lastConnected) {
            Write-Check OK ("最近日志中存在 durable connected: {0}" -f $lastConnected.Path)
        } elseif ($chatgptProcesses.Count -gt 0) {
            Write-Check WARN '最近日志中未找到 durable connected。'
        }
        if ($lastTimeout) {
            Write-Check INFO ("最近日志样本中也存在 durable timeout 记录（可能是修复前历史）: {0}" -f $lastTimeout.Path)
        }
    }

    $forwarderLog = Join-Path ([string]$config.InstallRoot) 'logs\forwarder.log'
    if (Test-Path -LiteralPath $forwarderLog) {
        Write-Host ''
        Write-Host '转发器日志末尾：' -ForegroundColor Cyan
        Get-Content -LiteralPath $forwarderLog -Tail 8 -ErrorAction SilentlyContinue
    }

    Write-Host ''
    if ($script:FailureCount -eq 0) {
        Write-Host ("诊断完成：0 项失败，{0} 项警告。" -f $script:WarningCount) -ForegroundColor Green
    } else {
        Write-Host ("诊断完成：{0} 项失败，{1} 项警告。" -f $script:FailureCount, $script:WarningCount) -ForegroundColor Red
    }
    if (-not $NoPause) { [void](Read-Host '按回车关闭窗口') }
    if ($script:FailureCount -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Host ("[诊断失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    if (-not $NoPause) { [void](Read-Host '按回车关闭窗口') }
    exit 1
}
