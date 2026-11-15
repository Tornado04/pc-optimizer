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
    Ejecuta una optimización inmediatamente después de instalar y comprueba que funcionó.

.PARAMETER NoPause
    No esperar a que se pulse una tecla al terminar (para instalaciones automatizadas).
#>
[CmdletBinding()]
param(
    [ValidateRange(0, 3600)][int]$DelaySeconds = 60,
    [switch]$RunNow,
    [switch]$NoPause
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
    if ($NoPause)  { $argList += '-NoPause' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    } catch {
        Write-Host 'No se concedieron permisos de administrador; no se instaló nada.' -ForegroundColor Red
    }
    exit
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$installLog = Join-Path $InstallDir 'install.log'
Start-Transcript -Path $installLog -Force | Out-Null
$exitCode = 0
try {
# --- Copiar archivos --------------------------------------------------------
Write-Host "Instalando en $InstallDir" -ForegroundColor Cyan
Copy-Item -Path (Join-Path $SourceDir 'Optimize-PC.ps1'), (Join-Path $SourceDir 'PCOptimizer.psm1') -Destination $InstallDir -Force

$targetConfig = Join-Path $InstallDir 'config.json'
if (Test-Path -LiteralPath $targetConfig) {
    Write-Host 'Se conserva tu config.json existente.' -ForegroundColor DarkGray
} else {
    Copy-Item -Path (Join-Path $SourceDir 'config.json') -Destination $targetConfig
}
# Quitar la marca "descargado de Internet" para que Windows no bloquee los scripts
Get-ChildItem -LiteralPath $InstallDir -File | Unblock-File -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $InstallDir 'logs') -Force | Out-Null

# Solo administradores y SYSTEM pueden modificar los scripts (se ejecutan elevados)
$icaclsOut = & icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 2>&1
if ($LASTEXITCODE -ne 0) { Write-Warning "icacls devolvió ${LASTEXITCODE}: $icaclsOut" }

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

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { throw "La tarea '$TaskName' no aparece en el Programador de tareas tras registrarla." }
Write-Host "Usuario de la tarea: $user   Estado: $($task.State)"

if ($RunNow) {
    Write-Host 'Ejecutando una optimización ahora para comprobar que funciona...' -ForegroundColor Cyan
    $logsDir = Join-Path $InstallDir 'logs'
    $before = @(Get-ChildItem -LiteralPath $logsDir -Filter 'optimize-*.log' -ErrorAction SilentlyContinue).Count
    Start-ScheduledTask -TaskName $TaskName

    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskName $TaskName).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    $info  = Get-ScheduledTaskInfo -TaskName $TaskName
    $after = @(Get-ChildItem -LiteralPath $logsDir -Filter 'optimize-*.log' -ErrorAction SilentlyContinue).Count
    $result = '0x{0:X}' -f $info.LastTaskResult
    if ($info.LastTaskResult -eq 0 -and $after -gt $before) {
        $last = Get-ChildItem -LiteralPath $logsDir -Filter 'optimize-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1
        Write-Host "Prueba correcta. Resumen:" -ForegroundColor Green
        Get-Content -LiteralPath $last.FullName -Tail 1 | Write-Host
    } else {
        Write-Host "La prueba NO funcionó (resultado de la tarea: $result, estado: $state)." -ForegroundColor Red
        $fatal = Join-Path $logsDir 'error.log'
        if (Test-Path -LiteralPath $fatal) { Get-Content -LiteralPath $fatal -Tail 20 | Write-Host }
        Write-Host 'Ejecutando el script directamente para ver el error:' -ForegroundColor Yellow
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Verbose -NoNotification
        $exitCode = 1
    }
}
}
catch {
    Write-Host "ERROR durante la instalación: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 1
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Registro de la instalación: $installLog"
    if (-not $NoPause) { Read-Host 'Pulsa Enter para cerrar' | Out-Null }
}
exit $exitCode
