#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Установка OpenSSH Server на Windows (WS-WIN, SRV-WIN).

.DESCRIPTION
    Ставит компонент OpenSSH.Server, включает службу sshd с автозапуском,
    открывает TCP 22 в брандмауэре, по желанию назначает PowerShell
    оболочкой по умолчанию и статический IP для сети MGMT.

.PARAMETER SshPort
    Порт SSH. По умолчанию 22.

.PARAMETER SetPowerShellDefault
    Назначить PowerShell оболочкой по умолчанию для SSH-сессий.

.PARAMETER MgmtIP
    Необязательный статический IPv4 для интерфейса без шлюза (Host-Only).
    Например: 192.168.56.10 для WS-WIN, 192.168.56.20 для SRV-WIN.

.PARAMETER MgmtPrefixLength
    Длина маски для MgmtIP. По умолчанию 24.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-ssh-windows.ps1

.EXAMPLE
    .\install-ssh-windows.ps1 -SetPowerShellDefault -MgmtIP 192.168.56.10
#>
[CmdletBinding()]
param(
    [int]$SshPort = 22,
    [switch]$SetPowerShellDefault,
    [string]$MgmtIP = '',
    [int]$MgmtPrefixLength = 24
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }

# 1. Права администратора
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[x] Нужны права администратора: запустите PowerShell от имени администратора." -ForegroundColor Red
    exit 1
}

# 2. ОС
$os = Get-CimInstance Win32_OperatingSystem
Write-Step "Система: $($os.Caption) ($($os.Version))"

# 3. Компонент OpenSSH.Server (с проверкой и запасным путём)
function Test-SshdService {
    return [bool](Get-Service -Name sshd -ErrorAction SilentlyContinue)
}

function Install-Win32OpenSSH {
    $zip    = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
    $parent = 'C:\Program Files'
    $dest   = Join-Path $parent 'OpenSSH'
    $url    = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip'

    Write-Step "Скачиваю официальный Win32-OpenSSH..."
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    Write-Step "Распаковываю..."
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $parent -Force

    $extracted = Join-Path $parent 'OpenSSH-Win64'
    if (-not (Test-Path $extracted)) { throw "После распаковки не найден каталог $extracted" }
    Move-Item -Path $extracted -Destination $dest -Force

    Write-Step "Регистрирую службу sshd (Install-sshd.ps1)..."
    & (Join-Path $dest 'Install-sshd.ps1')
}

Write-Step "Проверяю компонент OpenSSH Server..."
try {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
} catch {
    $cap = $null
    Write-Warn "Get-WindowsCapability недоступен: $($_.Exception.Message)"
}

$ready = Test-SshdService
if (-not $ready -and $cap -and $cap.State -eq 'Installed') {
    $ready = $true
}

if (-not $ready) {
    if ($cap) {
        Write-Step "Устанавливаю компонент OpenSSH Server (может занять минуту)..."
        try {
            Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
        } catch {
            Write-Warn "Компонент не установился: $($_.Exception.Message)"
        }
    } else {
        Write-Warn "Компонент OpenSSH.Server не найден в списке."
    }
    $ready = Test-SshdService
}

if (-not $ready) {
    Write-Warn "Служба sshd не появилась — ставлю официальный Win32-OpenSSH."
    Install-Win32OpenSSH
    $ready = Test-SshdService
}

if (-not $ready) {
    throw "Не удалось установить OpenSSH Server ни компонентом Windows, ни Win32-OpenSSH."
}
Write-Step "OpenSSH Server установлен, служба sshd найдена."

# 4. Служба sshd
Write-Step "Включаю службу sshd и автозапуск..."
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# 5. Брандмауэр
Write-Step "Правило брандмауэра для TCP $SshPort..."
$ruleName = 'OpenSSH-Server-In-TCP'
if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name $ruleName -Enabled True -Action Allow `
        -Direction Inbound -Protocol TCP -LocalPort $SshPort -Profile Any
    Write-Step "Правило уже было — включено."
} else {
    New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow `
        -LocalPort $SshPort -Profile Any | Out-Null
    Write-Step "Правило создано."
}

# 6. PowerShell по умолчанию
if ($SetPowerShellDefault) {
    Write-Step "Назначаю PowerShell оболочкой по умолчанию..."
    $reg = 'HKLM:\SOFTWARE\OpenSSH'
    if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }
    New-ItemProperty -Path $reg -Name DefaultShell `
        -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -PropertyType String -Force | Out-Null
}

# 7. Статический IP для MGMT (необязательно)
if ($MgmtIP) {
    Write-Step "Настраиваю статический IP $MgmtIP/$MgmtPrefixLength для MGMT..."
    $withGw = @(Get-NetIPConfiguration |
        Where-Object { $_.IPv4DefaultGateway } |
        ForEach-Object { $_.InterfaceAlias })
    $cands = @(Get-NetAdapter |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
        Where-Object { $withGw -notcontains $_.Name })

    if ($cands.Count -eq 0) {
        Write-Warn "Не найден интерфейс без шлюза — пропускаю настройку IP."
    } elseif ($cands.Count -eq 1) {
        $iface = $cands[0].Name
        $existing = Get-NetIPAddress -InterfaceAlias $iface -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($existing -and ($existing.IPAddress -contains $MgmtIP)) {
            Write-Step "IP $MgmtIP уже назначен на $iface."
        } else {
            New-NetIPAddress -InterfaceAlias $iface -IPAddress $MgmtIP `
                -PrefixLength $MgmtPrefixLength | Out-Null
            Write-Step "IP $MgmtIP/$MgmtPrefixLength назначен на $iface."
        }
    } else {
        Write-Warn "Несколько кандидатов: $($cands.Name -join ', '). Укажите интерфейс вручную."
    }
}

# 8. Перезапуск и итог
Restart-Service sshd
$svc = Get-Service sshd
Write-Step "Служба sshd: $($svc.Status), запуск: $($svc.StartType)"

Write-Step "IPv4-адреса:"
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '127.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength |
    Format-Table -AutoSize

Write-Host "`nПодключение с ADMIN-WS:" -ForegroundColor Cyan
Write-Host "    ssh $env:USERNAME@<IP-адрес-интерфейса-MGMT>`n"
