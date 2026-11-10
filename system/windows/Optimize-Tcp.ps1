[CmdletBinding()]
param (
    [int]$TimeWaitDelay = 30,
    [int]$DynamicPortStart = 1024,
    [int]$DynamicPortRange = 64139,
    [switch]$Force
)

# 权限校验
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Error: Administrator privileges required."
    exit 1
}

Write-Host "Applying TCP/IP performance adjustments..." -ForegroundColor Cyan

# 1. 扩充动态端口范围
netsh int ipv4 set dynamicport tcp start=$DynamicPortStart num=$DynamicPortRange | Out-Null
netsh int ipv6 set dynamicport tcp start=$DynamicPortStart num=$DynamicPortRange | Out-Null

# 2. 缩短 TIME_WAIT 延迟
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
Set-ItemProperty -Path $regPath -Name "TcpTimedWaitDelay" -Value $TimeWaitDelay -Type DWord -Force

# 3. 启用 TCP 全局优化选项
netsh int tcp set global autotuninglevel=normal | Out-Null
netsh int tcp set global rss=enabled | Out-Null

# 4. 设置拥塞控制算法为 CUBIC
try {
    Set-NetTCPSetting -SettingName Internet -CongestionProvider CUBIC -ErrorAction Stop
} catch {
    Get-NetTCPSetting | ForEach-Object {
        Set-NetTCPSetting -SettingName $_.SettingName -CongestionProvider CUBIC -ErrorAction SilentlyContinue
    }
}

Write-Host "Optimization applied successfully." -ForegroundColor Green

# 5. 重启逻辑
if (-not $Force) {
    Write-Host "`nSystem reboot is required to complete changes." -ForegroundColor Yellow
    Write-Host "Rebooting in 30 seconds... Press [ESC] or [Ctrl+C] to abort."
    
    $timeout = 30
    while ($timeout -gt 0) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Escape' -or ($key.Modifiers -eq 'Control' -and $key.Key -eq 'C')) {
                Write-Host "`nReboot cancelled by user." -ForegroundColor Yellow
                exit 0
            }
        }
        Write-Host -NoNewline "`rCountdown: $timeout s  "
        Start-Sleep -Seconds 1
        $timeout--
    }
    Write-Host ""
}

Restart-Computer -Force