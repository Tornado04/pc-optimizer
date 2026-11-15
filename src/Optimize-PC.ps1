#Requires -Version 5.1
<#
.SYNOPSIS
    Optimiza el PC al iniciar sesión en Windows.

.DESCRIPTION
    Lo ejecuta automáticamente la tarea programada "PCOptimizer" en cada inicio de sesión.
    Las acciones se activan o desactivan en config.json (junto a este script).

.PARAMETER ConfigPath
    Ruta del archivo de configuración. Por defecto, config.json en la misma carpeta.

.PARAMETER NoNotification
    No mostrar la notificación final.

.EXAMPLE
    .\Optimize-PC.ps1 -WhatIf -Verbose
    Simula la optimización sin borrar ni cambiar nada y muestra el detalle.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$LogDirectory = (Join-Path $PSScriptRoot 'logs'),
    [switch]$NoNotification
)

$ErrorActionPreference = 'Continue'

# Cualquier error que impida arrancar queda en logs\error.log (si no, la tarea fallaría en silencio)
trap {
    try {
        if (-not (Test-Path -LiteralPath $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }
        $msg = '{0:yyyy-MM-dd HH:mm:ss} [FATAL] {1}{2}{3}' -f (Get-Date), $_.Exception.Message, [Environment]::NewLine, $_.ScriptStackTrace
        Add-Content -LiteralPath (Join-Path $LogDirectory 'error.log') -Value $msg -Encoding UTF8
    } catch { }
    Write-Error $_
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'PCOptimizer.psm1') -Force -ErrorAction Stop

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$config  = Get-OptimizerConfig -Path $ConfigPath
$logFile = Initialize-Log -LogDirectory $LogDirectory -RetentionDays ([int]$config.logRetentionDays)
$started = Get-Date
$freed   = [long]0
$freeBefore = Get-SystemDriveFreeGB

Write-Log ("=== PC Optimizer: inicio de sesión de {0} (admin: {1}, simulación: {2}) ===" -f $env:USERNAME, $isAdmin, [bool]$WhatIfPreference)
if (-not $isAdmin) {
    Write-Log 'Sin privilegios de administrador: se omiten las tareas que los requieren' -Level WARN
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    try { & $Action }
    catch { Write-Log "$Name falló: $($_.Exception.Message)" -Level ERROR }
}

if ($config.tempCleanup.enabled) {
    Invoke-Step 'Limpieza de temporales' { $script:freed += Invoke-TempCleanup -Settings $config.tempCleanup -WhatIf:$WhatIfPreference }
}
if ($config.windowsUpdateCache.enabled -and $isAdmin) {
    Invoke-Step 'Caché de Windows Update' { $script:freed += Invoke-WindowsUpdateCacheCleanup -Settings $config.windowsUpdateCache -WhatIf:$WhatIfPreference }
}
if ($config.recycleBin.enabled) {
    Invoke-Step 'Papelera' { Invoke-RecycleBinCleanup -WhatIf:$WhatIfPreference }
}
if ($config.dnsFlush.enabled) {
    Invoke-Step 'DNS' { Invoke-DnsFlush -WhatIf:$WhatIfPreference }
}
if ($config.powerPlan.enabled) {
    Invoke-Step 'Plan de energía' { Set-OptimizerPowerPlan -Plan $config.powerPlan.plan -WhatIf:$WhatIfPreference }
}
if ($config.closeProcesses.enabled -and @($config.closeProcesses.names).Count -gt 0) {
    Invoke-Step 'Cierre de procesos' { Stop-UnwantedProcesses -Names $config.closeProcesses.names -WhatIf:$WhatIfPreference }
}
if ($config.ssdTrim.enabled -and $isAdmin) {
    Invoke-Step 'TRIM SSD' {
        Invoke-SsdTrim -IntervalDays ([int]$config.ssdTrim.intervalDays) -StatePath (Join-Path $LogDirectory 'state.json') -WhatIf:$WhatIfPreference
    }
}

$freeAfter = Get-SystemDriveFreeGB
$elapsed   = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
$summary   = "Liberados {0} en {1} s." -f (Format-Bytes $freed), $elapsed
if ($null -ne $freeAfter) { $summary += " Espacio libre: $freeAfter GB." }

$lowDisk = ($null -ne $freeAfter -and $freeAfter -lt [double]$config.lowDiskWarningGB)
if ($lowDisk) {
    Write-Log "Poco espacio en disco: $freeAfter GB libres (umbral $($config.lowDiskWarningGB) GB)" -Level WARN
    $summary += ' ¡Poco espacio en disco!'
}
Write-Log "=== Fin: $summary (antes: $freeBefore GB) ===" -Level OK

if ($config.notification.enabled -and -not $NoNotification -and -not $WhatIfPreference) {
    Show-OptimizerNotification -Title 'PC optimizado para la nueva sesión' -Message $summary
}

if ($WhatIfPreference) { Write-Host "[Simulación] $summary  Log: $logFile" }
