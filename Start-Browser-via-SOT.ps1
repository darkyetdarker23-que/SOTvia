[CmdletBinding()]
param([string]$Url)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

try {
    $config = Read-PackageConfig -Root $PSScriptRoot
    $launcher = Join-Path $PSScriptRoot 'Start-ChatGPT-via-SOT.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -TunnelOnly -NoPause
    if ($LASTEXITCODE -ne 0) { throw '无法启动 SOT 独立隧道。' }

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $browserCandidates = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        $(if ($programFilesX86) { Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe' }),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        $(if ($programFilesX86) { Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe' })
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    $browser = $browserCandidates | Select-Object -First 1
    if (-not $browser) { throw '未找到 Google Chrome 或 Microsoft Edge。' }

    if (-not $Url) {
        $clipboard = Get-Clipboard -ErrorAction SilentlyContinue
        if ($clipboard -is [string] -and $clipboard -match '^https?://') {
            $Url = $clipboard.Trim()
        }
    }
    if (-not $Url) { $Url = 'https://auth.openai.com/' }

    $profileDir = Join-Path ([string]$config.InstallRoot) 'browser-profile'
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    $arguments = @(
        ("--proxy-server=socks5://127.0.0.1:{0}" -f $config.SocksPort),
        ("--user-data-dir={0}" -f $profileDir),
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-sync',
        '--disable-features=ChromeWhatsNewUI,MediaRouter',
        $Url
    )
    Start-Process -FilePath $browser -ArgumentList $arguments
    Write-Success ("已通过 SOT 打开浏览器: {0}" -f $Url)
    Start-Sleep -Seconds 2
    exit 0
} catch {
    Write-Host ("[失败] {0}" -f $_.Exception.Message) -ForegroundColor Red
    [void](Read-Host '按回车关闭窗口')
    exit 1
}

