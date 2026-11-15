#Requires -Version 5.1
<#
    PCOptimizer.psm1
    Funciones de optimización que se ejecutan al iniciar sesión en Windows.
    Todas las acciones respetan -WhatIf (modo simulación).
#>

Set-StrictMode -Version Latest

$script:LogFile = $null

# --------------------------------------------------------------------------
# Registro (log)
# --------------------------------------------------------------------------
function Initialize-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [int]$RetentionDays = 30
    )
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $script:LogFile = Join-Path $LogDirectory ("optimize-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

    # Rotación: borrar logs antiguos
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $LogDirectory -Filter 'optimize-*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    return $script:LogFile
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Verbose $line
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------------
# Utilidades
# --------------------------------------------------------------------------
function Format-Bytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return '{0:N0} B' -f $Bytes
}

function Expand-ConfigPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded) -or $expanded -match '%[^%]+%') {
        return $null   # variable sin definir: no se toca nada
    }
    try { return [System.IO.Path]::GetFullPath($expanded).TrimEnd('\', '/') } catch { return $null }
}

function Test-SafeCleanupPath {
    <#
        Devuelve $true solo si es razonablemente seguro borrar contenido dentro de la ruta.
        Rechaza raíces de unidad, carpetas del sistema y perfiles de usuario completos.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($full)) { return $false }

    # Raíz de unidad (C:, C:\, /)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root) -or $full -eq $root.TrimEnd('\', '/')) { return $false }

    $protected = @(
        $env:SystemRoot, $env:windir,
        $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32' }),
        $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'SysWOW64' }),
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
        $env:USERPROFILE, $env:HOME, $env:APPDATA, $env:LOCALAPPDATA, $env:PUBLIC,
        $(if ($env:SystemDrive) { Join-Path $env:SystemDrive 'Users' })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') }

    foreach ($p in $protected) {
        if ([string]::Equals($full, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    # Nunca dentro de System32 / SysWOW64
    foreach ($sys in @('System32', 'SysWOW64')) {
        if ($env:SystemRoot) {
            $sysPath = Join-Path $env:SystemRoot $sys
            if ($full.StartsWith($sysPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    return $true
}

function Get-OldFiles {
    <#
        Enumera archivos con antigüedad mayor a N días SIN seguir enlaces simbólicos
        ni uniones (junctions), para no salir nunca de la carpeta indicada.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$OlderThanDays = 0
    )
    $limit = (Get-Date).AddDays(-$OlderThanDays)
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push([System.IO.DirectoryInfo]::new($Path))

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($e -is [System.IO.DirectoryInfo]) {
                $stack.Push($e)
            }
            elseif ($e.LastWriteTime -lt $limit) {
                $e
            }
        }
    }
}

function Remove-EmptyDirectories {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [int]$OlderThanDays = 0)
    $limit = (Get-Date).AddDays(-$OlderThanDays)
    $dirs = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push([System.IO.DirectoryInfo]::new($Path))
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $subs = $d.GetDirectories() } catch { continue }
        foreach ($s in $subs) {
            if ($s.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $dirs.Add($s); $stack.Push($s)
        }
    }
    # Los más profundos primero
    foreach ($d in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
        try {
            $d.Refresh()
            if ($d.LastWriteTime -lt $limit -and -not $d.EnumerateFileSystemInfos().GetEnumerator().MoveNext()) {
                if ($PSCmdlet.ShouldProcess($d.FullName, 'Eliminar carpeta vacía')) { $d.Delete() }
            }
        } catch { }
    }
}

function Clear-FolderContent {
    <#
        Borra archivos antiguos dentro de una carpeta. Los archivos en uso se omiten.
        Devuelve un objeto con bytes liberados y archivos borrados/omitidos.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$OlderThanDays = 0
    )
    $result = [pscustomobject]@{ Path = $Path; Bytes = [long]0; Deleted = 0; Skipped = 0 }

    if (-not (Test-SafeCleanupPath -Path $Path)) {
        Write-Log "Ruta rechazada por seguridad: $Path" -Level WARN
        return $result
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }

    foreach ($f in (Get-OldFiles -Path $Path -OlderThanDays $OlderThanDays)) {
        $size = $f.Length
        if ($PSCmdlet.ShouldProcess($f.FullName, 'Eliminar archivo')) {
            try {
                if ($f.IsReadOnly) { $f.IsReadOnly = $false }
                $f.Delete()
                $result.Bytes += $size; $result.Deleted++
            } catch {
                $result.Skipped++   # en uso o sin permisos
            }
        } else {
            $result.Bytes += $size; $result.Deleted++
        }
    }
    Remove-EmptyDirectories -Path $Path -OlderThanDays $OlderThanDays -WhatIf:$WhatIfPreference
    return $result
}

# --------------------------------------------------------------------------
# Configuración
# --------------------------------------------------------------------------
function Get-DefaultConfig {
    return [ordered]@{
        tempCleanup        = [ordered]@{
            enabled       = $true
            olderThanDays = 2
            paths         = @(
                '%TEMP%',
                '%SystemRoot%\Temp',
                '%LOCALAPPDATA%\CrashDumps',
                '%LOCALAPPDATA%\Microsoft\Windows\INetCache',
                '%ProgramData%\Microsoft\Windows\WER\ReportArchive',
                '%ProgramData%\Microsoft\Windows\WER\ReportQueue'
            )
        }
        recycleBin         = [ordered]@{ enabled = $false }
        dnsFlush           = [ordered]@{ enabled = $true }
        windowsUpdateCache = [ordered]@{ enabled = $false; olderThanDays = 10 }
        powerPlan          = [ordered]@{ enabled = $false; plan = 'HighPerformance' }
        closeProcesses     = [ordered]@{ enabled = $false; names = @() }
        ssdTrim            = [ordered]@{ enabled = $true; intervalDays = 7 }
        lowDiskWarningGB   = 15
        notification       = [ordered]@{ enabled = $true }
        logRetentionDays   = 30
    }
}

function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @(foreach ($i in $InputObject) { ConvertTo-Hashtable $i })
    }
    return $InputObject
}

function Merge-Config {
    param($Base, $Override)
    foreach ($key in @($Override.Keys)) {
        if ($Base.Contains($key) -and $Base[$key] -is [System.Collections.IDictionary] -and $Override[$key] -is [System.Collections.IDictionary]) {
            Merge-Config -Base $Base[$key] -Override $Override[$key] | Out-Null
        } else {
            $Base[$key] = $Override[$key]
        }
    }
    return $Base
}

function Get-OptimizerConfig {
    <# Carga config.json y lo combina con los valores por defecto. #>
    [CmdletBinding()]
    param([string]$Path)
    $config = Get-DefaultConfig
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $config = Merge-Config -Base $config -Override (ConvertTo-Hashtable $json)
        } catch {
            Write-Log "config.json inválido, se usan valores por defecto: $($_.Exception.Message)" -Level WARN
        }
    }
    return $config
}

# --------------------------------------------------------------------------
# Tareas de optimización
# --------------------------------------------------------------------------
function Invoke-TempCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Settings)
    $total = [long]0
    foreach ($raw in $Settings.paths) {
        $path = Expand-ConfigPath -Path $raw
        if (-not $path) { continue }
        $r = Clear-FolderContent -Path $path -OlderThanDays ([int]$Settings.olderThanDays) -WhatIf:$WhatIfPreference
        if ($r.Deleted -gt 0 -or $r.Skipped -gt 0) {
            Write-Log ("Temporales {0}: {1} archivos, {2} liberados, {3} en uso" -f $path, $r.Deleted, (Format-Bytes $r.Bytes), $r.Skipped)
        }
        $total += $r.Bytes
    }
    return $total
}

function Invoke-RecycleBinCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Papelera de reciclaje', 'Vaciar')) {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log 'Papelera de reciclaje vaciada' -Level OK
    }
}

function Invoke-DnsFlush {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Caché DNS', 'Vaciar')) {
        if (Get-Command Clear-DnsClientCache -ErrorAction SilentlyContinue) {
            Clear-DnsClientCache -ErrorAction SilentlyContinue
        } else {
            ipconfig.exe /flushdns | Out-Null
        }
        Write-Log 'Caché DNS vaciada' -Level OK
    }
}

function Invoke-WindowsUpdateCacheCleanup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Settings)
    $path = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    if (-not (Test-Path -LiteralPath $path)) { return [long]0 }

    # No interferir si Windows Update está trabajando
    $wu = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    if ($wu -and $wu.Status -eq 'Running') {
        Write-Log 'Windows Update está activo; se omite la limpieza de su caché' -Level INFO
        return [long]0
    }
    $r = Clear-FolderContent -Path $path -OlderThanDays ([int]$Settings.olderThanDays) -WhatIf:$WhatIfPreference
    Write-Log ("Caché de Windows Update: {0} liberados" -f (Format-Bytes $r.Bytes))
    return $r.Bytes
}

function Get-PowerPlanGuid {
    param([string]$Name)
    switch ($Name) {
        'Balanced'        { '381b4222-f694-41f0-9685-ff5bb260df2e' }
        'HighPerformance' { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
        'PowerSaver'      { 'a1841308-3541-4fab-bc81-f71556f20b4a' }
        'Ultimate'        { 'e9a42b02-d5df-448d-aa00-03f14749eb61' }
        default           { $null }
    }
}

function Set-OptimizerPowerPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Plan)
    $guid = Get-PowerPlanGuid -Name $Plan
    if (-not $guid) { Write-Log "Plan de energía desconocido: $Plan" -Level WARN; return }
    if (-not $PSCmdlet.ShouldProcess("Plan de energía $Plan", 'Activar')) { return }

    powercfg.exe /setactive $guid 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -and $Plan -eq 'Ultimate') {
        # "Máximo rendimiento" no existe por defecto: se duplica la plantilla
        $out = powercfg.exe -duplicatescheme $guid 2>$null
        if ($out -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            powercfg.exe /setactive $Matches[1] | Out-Null
        }
    }
    if ($LASTEXITCODE -eq 0) { Write-Log "Plan de energía activo: $Plan" -Level OK }
    else { Write-Log "No se pudo activar el plan de energía $Plan" -Level WARN }
}

function Stop-UnwantedProcesses {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Names)
    foreach ($n in $Names) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($n)
        foreach ($p in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($PSCmdlet.ShouldProcess("$($p.Name) (PID $($p.Id))", 'Cerrar proceso')) {
                try { $p | Stop-Process -Force -ErrorAction Stop; Write-Log "Proceso cerrado: $($p.Name)" -Level OK }
                catch { Write-Log "No se pudo cerrar $($p.Name): $($_.Exception.Message)" -Level WARN }
            }
        }
    }
}

function Get-OptimizerState {
    param([string]$StatePath)
    if (Test-Path -LiteralPath $StatePath) {
        try { return ConvertTo-Hashtable (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json) } catch { }
    }
    return [ordered]@{}
}

function Save-OptimizerState {
    param([string]$StatePath, $State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Invoke-SsdTrim {
    <# Ejecuta TRIM en las unidades SSD como máximo una vez cada N días. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$IntervalDays = 7, [Parameter(Mandatory)][string]$StatePath)

    $state = Get-OptimizerState -StatePath $StatePath
    if ($state.Contains('lastTrim')) {
        $last = [datetime]::MinValue
        if ([datetime]::TryParse([string]$state['lastTrim'], [ref]$last) -and $last -gt (Get-Date).AddDays(-$IntervalDays)) {
            Write-Log "TRIM omitido (último: $($last.ToString('yyyy-MM-dd')))"
            return
        }
    }
    if (-not (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue)) { return }

    $ssdNumbers = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object MediaType -eq 'SSD' | ForEach-Object { [int]$_.DeviceId })
    if ($ssdNumbers.Count -eq 0) { Write-Log 'No se detectaron SSD; TRIM omitido'; return }

    $volumes = Get-Partition -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and ($ssdNumbers -contains [int]$_.DiskNumber) } |
        Select-Object -ExpandProperty DriveLetter -Unique

    foreach ($letter in $volumes) {
        if ($PSCmdlet.ShouldProcess("${letter}:", 'TRIM (Optimize-Volume -ReTrim)')) {
            try { Optimize-Volume -DriveLetter $letter -ReTrim -ErrorAction Stop; Write-Log "TRIM completado en ${letter}:" -Level OK }
            catch { Write-Log "TRIM falló en ${letter}: $($_.Exception.Message)" -Level WARN }
        }
    }
    if (-not $WhatIfPreference) {
        $state['lastTrim'] = (Get-Date).ToString('o')
        Save-OptimizerState -StatePath $StatePath -State $state
    }
}

function Get-SystemDriveFreeGB {
    $drive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd(':') } else { 'C' }
    $d = Get-PSDrive -Name $drive -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($d) { return [math]::Round($d.Free / 1GB, 1) }
    return $null
}

function Show-OptimizerNotification {
    [CmdletBinding()]
    param([string]$Title, [string]$Message)
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName('text')
        $texts.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $texts.Item(1).AppendChild($xml.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Log "No se pudo mostrar la notificación: $($_.Exception.Message)" -Level INFO
    }
}

Export-ModuleMember -Function *
