#Requires -Version 5.1
<#
.SYNOPSIS
    Desinstala PC Optimizer: elimina la tarea programada y la carpeta de instalación.

.PARAMETER KeepLogs
    Conserva la carpeta de logs y el config.json.
#>
[CmdletBinding()]
param([switch]$KeepLogs)

$TaskName   = 'PCOptimizer'
$InstallDir = Join-Path $env:ProgramData 'PCOptimizer'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($KeepLogs) { $argList += '-KeepLogs' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    exit
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Tarea '$TaskName' eliminada." -ForegroundColor Green
}

if (Test-Path -LiteralPath $InstallDir) {
    if ($KeepLogs) {
        Remove-Item -LiteralPath (Join-Path $InstallDir 'Optimize-PC.ps1'), (Join-Path $InstallDir 'PCOptimizer.psm1') -Force -ErrorAction SilentlyContinue
        Write-Host "Scripts eliminados; se conservan logs y config en $InstallDir"
    } else {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Carpeta $InstallDir eliminada." -ForegroundColor Green
    }
}
Write-Host 'PC Optimizer desinstalado.'
