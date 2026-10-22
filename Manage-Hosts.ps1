[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Add', 'Remove')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$BackupDirectory
)

$ErrorActionPreference = 'Stop'
$targetHost = 'codex-cloud-backend.chatgpt.com'
$beginMarker = '# BEGIN ChatGPT via SOT'
$endMarker = '# END ChatGPT via SOT'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TextFileInfo {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = $null
    $offset = 0

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true)
        $offset = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object Text.UnicodeEncoding($false, $true)
        $offset = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object Text.UnicodeEncoding($true, $true)
        $offset = 2
    } else {
        try {
            $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
            [void]$strictUtf8.GetString($bytes)
            $encoding = New-Object Text.UTF8Encoding($false)
        } catch {
            $encoding = [Text.Encoding]::Default
        }
    }

    $text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } else { "`r`n" }
    return [pscustomobject]@{
        Text = $text
        Encoding = $encoding
        NewLine = $newLine
    }
}

function Get-TargetMappings {
    param([string]$Text)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($line in [Text.RegularExpressions.Regex]::Split($Text, '\r\n|\n|\r')) {
        $active = ($line -split '#', 2)[0].Trim()
        if (-not $active) { continue }
        $parts = @($active -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 2) { continue }
        if (@($parts[1..($parts.Count - 1)] | Where-Object { $_ -ieq $targetHost }).Count -gt 0) {
            $results.Add([pscustomobject]@{ Address = $parts[0]; Line = $line })
        }
    }
    return @($results)
}

function Test-ManagedBlock {
    param([string]$Text)
    $inside = $false
    $beginCount = 0
    $endCount = 0
    $validMappingCount = 0
    foreach ($line in [Text.RegularExpressions.Regex]::Split($Text, '\r\n|\n|\r')) {
        if ($line.Trim() -eq $beginMarker) {
            $beginCount++
            if ($inside -or $beginCount -gt 1) { return $false }
            $inside = $true
            continue
        }
        if ($line.Trim() -eq $endMarker) {
            $endCount++
            if (-not $inside -or $endCount -gt 1) { return $false }
            $inside = $false
            continue
        }
        if (-not $inside) { continue }
        $active = ($line -split '#', 2)[0].Trim()
        if (-not $active) { continue }
        $parts = @($active -split '\s+' | Where-Object { $_ })
        if ($parts.Count -lt 2) { continue }
        if (@($parts[1..($parts.Count - 1)] | Where-Object { $_ -ieq $targetHost }).Count -gt 0) {
            if ($parts[0] -ne '127.0.0.1') { return $false }
            $validMappingCount++
        }
    }
    return (-not $inside -and $beginCount -eq 1 -and $endCount -eq 1 -and $validMappingCount -eq 1)
}

if (-not (Test-IsAdministrator)) {
    Write-Error 'Manage-Hosts.ps1 必须以管理员身份运行。'
    exit 5
}

try {
    if (-not (Test-Path -LiteralPath $hostsPath)) {
        throw "未找到 hosts 文件: $hostsPath"
    }
    $fileInfo = Get-TextFileInfo -Path $hostsPath

    if ($Action -eq 'Add') {
        if ($fileInfo.Text.Contains($beginMarker) -or $fileInfo.Text.Contains($endMarker)) {
            if (Test-ManagedBlock -Text $fileInfo.Text) {
                Write-Host 'ChatGPT via SOT 的 hosts 区块已经存在。'
                ipconfig.exe /flushdns | Out-Null
                exit 0
            }
            Write-Error 'hosts 中存在不完整的 ChatGPT via SOT 标记，请先人工检查。'
            exit 20
        }

        $mappings = @(Get-TargetMappings -Text $fileInfo.Text)
        if ($mappings.Count -gt 0) {
            if (@($mappings | Where-Object { $_.Address -ne '127.0.0.1' }).Count -gt 0) {
                Write-Error ("hosts 已将 {0} 指向其他地址；为避免覆盖用户设置，安装已停止。" -f $targetHost)
                exit 20
            }
            Write-Host 'hosts 已有相同的 127.0.0.1 映射；安装器将复用它，但卸载时不会删除。'
            ipconfig.exe /flushdns | Out-Null
            exit 10
        }

        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path $BackupDirectory ("hosts-before-install-{0}.bak" -f $stamp)
        Copy-Item -LiteralPath $hostsPath -Destination $backupPath -Force

        $text = $fileInfo.Text
        if ($text.Length -gt 0 -and -not $text.EndsWith($fileInfo.NewLine)) {
            $text += $fileInfo.NewLine
        }
        $text += $beginMarker + $fileInfo.NewLine
        $text += "127.0.0.1 $targetHost" + $fileInfo.NewLine
        $text += $endMarker + $fileInfo.NewLine
        [IO.File]::WriteAllText($hostsPath, $text, $fileInfo.Encoding)
        ipconfig.exe /flushdns | Out-Null
        Write-Host ("已添加 hosts 映射，备份位于: {0}" -f $backupPath)
        exit 0
    }

    $lines = [Text.RegularExpressions.Regex]::Split($fileInfo.Text, '\r\n|\n|\r')
    $output = New-Object System.Collections.Generic.List[string]
    $inside = $false
    $found = $false
    foreach ($line in $lines) {
        if ($line.Trim() -eq $beginMarker) {
            if ($inside) { throw 'hosts 中存在嵌套的 ChatGPT via SOT 标记。' }
            $inside = $true
            $found = $true
            continue
        }
        if ($line.Trim() -eq $endMarker) {
            if (-not $inside) { throw 'hosts 中存在不完整的 ChatGPT via SOT 标记。' }
            $inside = $false
            continue
        }
        if (-not $inside) { $output.Add($line) }
    }
    if ($inside) { throw 'hosts 中存在未闭合的 ChatGPT via SOT 标记。' }

    if ($found) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = Join-Path $BackupDirectory ("hosts-before-uninstall-{0}.bak" -f $stamp)
        Copy-Item -LiteralPath $hostsPath -Destination $backupPath -Force
        $newText = [string]::Join($fileInfo.NewLine, $output)
        [IO.File]::WriteAllText($hostsPath, $newText, $fileInfo.Encoding)
        Write-Host ("已删除本工具管理的 hosts 区块，备份位于: {0}" -f $backupPath)
    } else {
        Write-Host '未找到本工具管理的 hosts 区块，无需修改。'
    }
    ipconfig.exe /flushdns | Out-Null
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 20
}
