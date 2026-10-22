[CmdletBinding()]
param(
    [switch]$TunnelOnly,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Pause-Launcher {
    if (-not $NoPause -and -not $TunnelOnly) {
        Write-Host ''
        [void](Read-Host '按回车关闭启动窗口（代理和 ChatGPT 会继续运行）')
    }
}

function Sync-TunnelData {
    param($Config)
    $sourceX = Join-Path ([string]$Config.SotDataDir) 'x_tunnel'
    $sourceClient = Join-Path $sourceX 'client.json'
    if (-not (Test-Path -LiteralPath $sourceClient)) {
        throw '未找到 SOT 登录配置。请先启动 SOT、完成登录并确认 SOT 可以正常上网。'
    }

    $targetX = Join-Path ([string]$Config.TunnelDataDir) 'x_tunnel'
    $launcherDir = Join-Path ([string]$Config.TunnelDataDir) 'launcher'
    New-Item -ItemType Directory -Path $targetX -Force | Out-Null
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null

    foreach ($name in @(
        'relay_host.json', 'relay_speed.json', 'seley_host.json',
        'seley_speed.json', 'cloudflare_domains.json', 'cloudflare_speed.json'
    )) {
        $source = Join-Path $sourceX $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $targetX $name) -Force
        }
    }

    # Read the recipient's own SOT credentials. No account data is included
    # in the distribution package or copied from the package author.
    $client = Get-Content -LiteralPath $sourceClient -Raw | ConvertFrom-Json
    $client | Add-Member -NotePropertyName socks_port -NotePropertyValue ([int]$Config.SocksPort) -Force
    $clientJson = $client | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText(
        (Join-Path $targetX 'client.json'),
        $clientJson,
        (New-Object Text.UTF8Encoding($false))
    )

    $launcherConfig = @{
        control_port = [int]$Config.ControlPort
        enable_x_tunnel = 1
        enable_smart_router = 0
        enable_gae_proxy = 0
        enable_launcher = 0
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        (Join-Path $launcherDir 'config.json'),
        $launcherConfig,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Ensure-Tunnel {
    param($Config)
    $listeners = @(Get-LoopbackListener -Port ([int]$Config.SocksPort))
    if ($listeners.Count -gt 0) {
        foreach ($listener in $listeners) {
            if (Test-ExpectedTunnelProcess -ProcessId $listener.OwningProcess -Config $Config) {
                Write-Success ("复用现有独立隧道 pid={0}, 127.0.0.1:{1}" -f $listener.OwningProcess, $Config.SocksPort)
                return $listener.OwningProcess
            }
        }
        throw ("端口 {0} 已被其他程序占用。请运行 Diagnose.cmd 查看占用者。" -f $Config.SocksPort)
    }

    $controlListeners = @(Get-LoopbackListener -Port ([int]$Config.ControlPort))
    if ($controlListeners.Count -gt 0) {
        throw ("控制端口 {0} 已被占用，无法启动独立隧道。" -f $Config.ControlPort)
    }

    if (-not (Get-Process -Name 'SOT' -ErrorAction SilentlyContinue)) {
        throw 'SOT 本体未运行。请先启动 SOT，确认它已经登录并能正常打开网页。'
    }

    Sync-TunnelData -Config $Config
    $python = Join-Path ([string]$Config.SotScriptDir) 'python3\python.exe'
    $startPy = Join-Path ([string]$Config.SotScriptDir) 'code\default\launcher\start.py'
    if (-not (Test-Path -LiteralPath $python) -or -not (Test-Path -LiteralPath $startPy)) {
        throw 'SOT 的 Python 或 x_tunnel 启动文件不存在。请重新运行 Install.cmd。'
    }

    $argumentList = @(
        (Quote-ProcessArgument $startPy),
        '-no_systray', '-no_popup', '-no_mess_system',
        '--data_path', (Quote-ProcessArgument ([string]$Config.TunnelDataDir))
    ) -join ' '
    $process = Start-Process -FilePath $python -ArgumentList $argumentList `
        -WorkingDirectory ([string]$Config.SotScriptDir) -WindowStyle Hidden -PassThru
    Write-Step ("已启动独立隧道 pid={0}，等待端口 {1}..." -f $process.Id, $Config.SocksPort)

    $listener = Wait-ForExpectedListener -Port ([int]$Config.SocksPort) `
        -Kind Tunnel -Config $Config -TimeoutSeconds 45
    if (-not $listener) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        throw ("独立隧道未能在 45 秒内监听 127.0.0.1:{0}。" -f $Config.SocksPort)
    }
    Write-Success ("独立隧道已就绪: socks5://127.0.0.1:{0}" -f $Config.SocksPort)
    return $listener.OwningProcess
}

function Ensure-Forwarder {
    param($Config)
    $listeners = @(Get-LoopbackListener -Port ([int]$Config.ForwarderPort))
    if ($listeners.Count -gt 0) {
        foreach ($listener in $listeners) {
            if (Test-ExpectedForwarderProcess -ProcessId $listener.OwningProcess -Config $Config) {
                Write-Success ("复用 durable 转发器 pid={0}, 127.0.0.1:{1}" -f $listener.OwningProcess, $Config.ForwarderPort)
                return $listener.OwningProcess
            }
        }
        throw ("127.0.0.1:{0} 已被其他程序占用。为避免误转发，启动已中止。" -f $Config.ForwarderPort)
    }

    $python = Join-Path ([string]$Config.SotScriptDir) 'python3\python.exe'
    $forwarder = Join-Path ([string]$Config.InstallRoot) 'ws-cloud-forwarder.py'
    $logDir = Join-Path ([string]$Config.InstallRoot) 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logFile = Join-Path $logDir 'forwarder.log'
    $arguments = @(
        (Quote-ProcessArgument $forwarder),
        '--listen-host', '127.0.0.1',
        '--listen-port', [string]$Config.ForwarderPort,
        '--socks-host', '127.0.0.1',
        '--socks-port', [string]$Config.SocksPort,
        '--target-host', [string]$Config.TargetHost,
        '--target-port', '443',
        '--log-file', (Quote-ProcessArgument $logFile)
    ) -join ' '
    $process = Start-Process -FilePath $python -ArgumentList $arguments `
        -WorkingDirectory ([string]$Config.InstallRoot) -WindowStyle Hidden -PassThru
    Write-Step ("已启动 durable 转发器 pid={0}，等待端口 {1}..." -f $process.Id, $Config.ForwarderPort)

    $listener = Wait-ForExpectedListener -Port ([int]$Config.ForwarderPort) `
        -Kind Forwarder -Config $Config -TimeoutSeconds 15
    if (-not $listener) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        throw ("durable 转发器未能监听 127.0.0.1:{0}。查看 {1}" -f $Config.ForwarderPort, $logFile)
    }
    Write-Success ("durable 转发器已就绪: 127.0.0.1:{0} -> SOCKS5 {1}" -f $Config.ForwarderPort, $Config.SocksPort)
    return $listener.OwningProcess
}

try {
    $config = Read-PackageConfig -Root $PSScriptRoot

    $addresses = @([Net.Dns]::GetHostAddresses([string]$config.TargetHost))
    if ($addresses.Count -eq 0 -or
        -not ($addresses | Where-Object { $_.IPAddressToString -eq '127.0.0.1' }) -or
        ($addresses | Where-Object { -not (Test-IsLoopbackAddress $_.IPAddressToString) })) {
        throw ("hosts 未正确生效：{0} 必须只解析到本机。请重新运行 Install.cmd。" -f $config.TargetHost)
    }

    [void](Ensure-Tunnel -Config $config)
    [void](Ensure-Forwarder -Config $config)

    if ($TunnelOnly) {
        Write-Success '隧道和 durable 转发器均已在线。'
        exit 0
    }

    $chatgpt = Get-ChatGPTPackageInfo
    if (-not $chatgpt) {
        throw '未找到 OpenAI.Codex/ChatGPT 桌面端。请安装后重新运行。'
    }
    Write-Success ("ChatGPT {0}: {1}" -f $chatgpt.Version, $chatgpt.ExePath)

    $proxy = "http://127.0.0.1:{0}" -f $config.SocksPort
    $env:HTTP_PROXY = $proxy
    $env:HTTPS_PROXY = $proxy
    $env:ALL_PROXY = $proxy
    $env:NO_PROXY = 'localhost,127.0.0.1,::1'

    $running = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Step '正在关闭已有 ChatGPT，以确保所有子进程继承代理设置...'
        $running | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    $chatgptProcess = Start-Process -FilePath $chatgpt.ExePath `
        -ArgumentList ("--proxy-server=socks5://127.0.0.1:{0}" -f $config.SocksPort) -PassThru
    Write-Step ("ChatGPT 已启动 pid={0}，等待网络与 durable 通道..." -f $chatgptProcess.Id)

    $durableConnected = $false
    $durableTcp = $false
    $deadline = (Get-Date).AddSeconds(35)
    do {
        Start-Sleep -Seconds 1
        $tree = @(Get-DescendantProcessIds -RootProcessId $chatgptProcess.Id)
        $durableTcp = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
            Where-Object {
                $_.OwningProcess -in $tree -and $_.RemoteAddress -eq '127.0.0.1' -and
                $_.RemotePort -eq [int]$config.ForwarderPort
            }).Count -gt 0

        $logRoot = Join-Path $env:LOCALAPPDATA 'Codex\Logs'
        if (Test-Path -LiteralPath $logRoot) {
            $logFiles = @(Get-ChildItem -LiteralPath $logRoot -Recurse -File `
                -Filter ("*-{0}-*.log" -f $chatgptProcess.Id) -ErrorAction SilentlyContinue)
            foreach ($logFile in $logFiles) {
                if (Select-String -LiteralPath $logFile.FullName `
                        -Pattern 'hostId=durable.*next=connected' -Quiet -ErrorAction SilentlyContinue) {
                    $durableConnected = $true
                    break
                }
            }
        }
    } while (-not $durableConnected -and (Get-Date) -lt $deadline)

    $processTree = @(Get-DescendantProcessIds -RootProcessId $chatgptProcess.Id)
    $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -in $processTree -and $_.State -notin @('Bound', 'Listen') })
    $viaTunnel = @($connections | Where-Object {
        $_.RemoteAddress -eq '127.0.0.1' -and $_.RemotePort -eq [int]$config.SocksPort
    })
    $direct = @($connections | Where-Object { -not (Test-IsLoopbackAddress $_.RemoteAddress) })

    Write-Host ''
    Write-Host ("[结果] 代理 TCP={0}，durable 本地 TCP={1}，外网直连 TCP={2}" -f `
        $viaTunnel.Count, [int]$durableTcp, $direct.Count)
    if ($durableConnected) {
        Write-Success 'durable WebSocket 日志已确认 connected。'
    } elseif ($durableTcp) {
        Write-Warning 'durable TCP 已进入转发器，但日志尚未确认 connected；可稍后运行 Diagnose.cmd。'
    } else {
        Write-Warning '尚未观察到 durable 连接，请运行 Diagnose.cmd。'
    }
    if ($direct.Count -eq 0) {
        Write-Success '未发现 ChatGPT 进程树的外网直连 TCP。'
    } else {
        Write-Warning ("发现 {0} 条非 loopback TCP；请运行 Diagnose.cmd 并停止使用。" -f $direct.Count)
    }

    Write-Host ''
    Write-Host '使用结束后请运行桌面的“停止 ChatGPT via SOT”。'
    Pause-Launcher
    exit 0
} catch {
    Write-Host ''
    Write-Host ("[失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '请先运行 Diagnose.cmd；若端口冲突，不要强行结束不明进程。'
    Pause-Launcher
    exit 1
}

