#Requires -Version 5.1
<#
.SYNOPSIS
    Instala PC Optimizer y lo registra para que se ejecute en cada inicio de sesión de Windows.

.DESCRIPTION
    - Copia los archivos a %ProgramData%\PCOptimizer
    - Crea la tarea programada "PCOptimizer" que se lanza al iniciar sesión,
      con privilegios elevados y sin ventana (no muestra aviso de UAC en cada arranque).
    - Conserva tu config.json si ya existía.

.PARAMETER DelaySeconds
    Espera tras el inicio de sesión antes de optimizar (para no competir con el arranque). Por defecto 60.

.PARAMETER RunNow
    Ejecuta una optimización inmediatamente después de instalar.
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 3600)][int]$DelaySeconds = 60,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$TaskName   = 'PCOptimizer'
$InstallDir = Join-Path $env:ProgramData 'PCOptimizer'
$SourceDir  = Join-Path $PSScriptRoot 'src'

# --- Auto-elevación ---------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Se necesitan permisos de administrador. Solicitando elevación...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-DelaySeconds', $DelaySeconds)
    if ($RunNow)   { $argList += '-RunNow' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    exit
}

# --- Copiar archivos --------------------------------------------------------
Write-Host "Instalando en $InstallDir" -ForegroundColor Cyan
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $SourceDir 'Optimize-PC.ps1'), (Join-Path $SourceDir 'PCOptimizer.psm1') -Destination $InstallDir -Force

$targetConfig = Join-Path $InstallDir 'config.json'
if (Test-Path -LiteralPath $targetConfig) {
    Write-Host 'Se conserva tu config.json existente.' -ForegroundColor DarkGray
} else {
    Copy-Item -Path (Join-Path $SourceDir 'config.json') -Destination $targetConfig
}

# Solo administradores y SYSTEM pueden modificar los scripts (se ejecutan elevados)
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null

# --- Tarea programada -------------------------------------------------------
$script = Join-Path $InstallDir 'Optimize-PC.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

# Se ejecuta como el usuario actual (para limpiar SU carpeta temporal) pero con privilegios elevados
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
if ($DelaySeconds -gt 0) { $trigger.Delay = 'PT{0}S' -f $DelaySeconds }

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -Priority 7

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $taskPrincipal `
    -Settings $settings -Description 'Optimiza el PC en cada inicio de sesión (PC Optimizer).' -Force | Out-Null

Write-Host "Tarea '$TaskName' registrada: se ejecutará en cada inicio de sesión ($DelaySeconds s de espera)." -ForegroundColor Green
Write-Host "Configuración: $targetConfig"
Write-Host "Logs:          $(Join-Path $InstallDir 'logs')"

if ($RunNow) {
    Write-Host 'Ejecutando una optimización ahora...' -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
}
