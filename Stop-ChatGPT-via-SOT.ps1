[CmdletBinding()]
param(
    [switch]$StopChatGPT,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

function Stop-VerifiedProcess {
    param(
        [int]$ProcessId,
        [ValidateSet('Tunnel', 'Forwarder')][string]$Kind,
        $Config
    )
    $valid = if ($Kind -eq 'Tunnel') {
        Test-ExpectedTunnelProcess -ProcessId $ProcessId -Config $Config
    } else {
        Test-ExpectedForwarderProcess -ProcessId $ProcessId -Config $Config
    }
    if (-not $valid) {
        Write-Warning ("跳过 pid={0}：它不是本工具启动的 {1} 进程。" -f $ProcessId, $Kind)
        return $false
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    Write-Success ("已停止 {0} pid={1}" -f $Kind, $ProcessId)
    return $true
}

try {
    $config = Read-PackageConfig -Root $PSScriptRoot
    $stopped = New-Object 'System.Collections.Generic.HashSet[int]'

    # Stop the forwarder first so it cannot accept a new connection while the
    # SOCKS tunnel is being removed.
    foreach ($listener in @(Get-LoopbackListener -Port ([int]$config.ForwarderPort))) {
        if ($stopped.Add([int]$listener.OwningProcess)) {
            [void](Stop-VerifiedProcess -ProcessId $listener.OwningProcess -Kind Forwarder -Config $config)
        }
    }

    foreach ($port in @([int]$config.SocksPort, [int]$config.ControlPort)) {
        foreach ($listener in @(Get-LoopbackListener -Port $port)) {
            if ($stopped.Add([int]$listener.OwningProcess)) {
                [void](Stop-VerifiedProcess -ProcessId $listener.OwningProcess -Kind Tunnel -Config $config)
            }
        }
    }

    if ($StopChatGPT) {
        $chatgpt = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue)
        if ($chatgpt.Count -gt 0) {
            $chatgpt | Stop-Process -Force
            Write-Success '已关闭 ChatGPT。'
        }
    } elseif (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue) {
        Write-Warning 'ChatGPT 仍在运行，但代理已停止；请关闭 ChatGPT，之后务必通过专用快捷方式重新启动。'
    }

    Write-Host ''
    Write-Host 'hosts 映射会保留，这是正常设计；下次使用请先启动 SOT，再运行“ChatGPT via SOT”。'
    if (-not $NoPause) { [void](Read-Host '按回车关闭窗口') }
    exit 0
} catch {
    Write-Host ("[失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    if (-not $NoPause) { [void](Read-Host '按回车关闭窗口') }
    exit 1
}

