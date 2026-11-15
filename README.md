# PC Optimizer

Optimizador ligero para Windows 10/11 que **se ejecuta automáticamente en cada inicio de sesión** y deja el equipo limpio para la nueva sesión. Escrito en PowerShell, sin dependencias ni programas de terceros.

## Qué hace

| Acción | Por defecto | Requiere admin |
|---|---|---|
| Borra archivos temporales antiguos (`%TEMP%`, `C:\Windows\Temp`, volcados de errores, caché de INet, informes de errores de Windows) | ✅ Activado | Parcial |
| Vacía la caché DNS | ✅ Activado | No |
| TRIM de las unidades SSD (como máximo una vez cada 7 días) | ✅ Activado | Sí |
| Avisa si queda poco espacio en el disco del sistema | ✅ Activado (15 GB) | No |
| Notificación con el resumen (espacio liberado) | ✅ Activado | No |
| Vaciar la papelera de reciclaje | ⬜ Desactivado | No |
| Limpiar la caché de descargas de Windows Update | ⬜ Desactivado | Sí |
| Activar un plan de energía (Equilibrado / Alto rendimiento / Máximo rendimiento) | ⬜ Desactivado | No |
| Cerrar procesos que no quieras al iniciar | ⬜ Desactivado | No |

### Medidas de seguridad

- Solo borra archivos **con más de N días** (2 por defecto), así no toca lo que usan los programas que acaban de arrancar.
- Los archivos en uso se omiten sin error.
- **No sigue enlaces simbólicos ni uniones**: nunca sale de la carpeta indicada.
- Se niega a limpiar raíces de unidad, `C:\Windows`, `System32`, `Program Files` o carpetas de perfil completas, aunque se configuren por error.
- Todo admite **modo simulación** (`-WhatIf`) para ver qué haría sin cambiar nada.
- La carpeta de instalación solo la pueden modificar los administradores, ya que el script se ejecuta con privilegios elevados.

> **Lo que no hace, a propósito:** «liberar RAM», borrar la carpeta Prefetch, desactivar servicios o tocar el registro. Esas «optimizaciones» suelen hacer Windows más lento o inestable.

## Instalación

1. Descarga el repositorio (**Code → Download ZIP**) y descomprímelo.
2. Haz doble clic en **`install.cmd`** y acepta el aviso de administrador.

O desde PowerShell:

```powershell
.\install.ps1            # instala (espera 60 s tras iniciar sesión)
.\install.ps1 -RunNow    # instala y optimiza ahora mismo
.\install.ps1 -DelaySeconds 30
```

El instalador:

- copia los archivos a `C:\ProgramData\PCOptimizer`;
- crea la tarea programada **`PCOptimizer`**, que se lanza **en cada inicio de sesión**, oculta y con privilegios elevados (sin aviso de UAC en cada arranque).

Puedes verla en el **Programador de tareas** o con `Get-ScheduledTask PCOptimizer`.

## Configuración

Edita `C:\ProgramData\PCOptimizer\config.json` (como administrador):

```json
{
    "tempCleanup": { "enabled": true, "olderThanDays": 2, "paths": ["%TEMP%", "%SystemRoot%\\Temp"] },
    "recycleBin": { "enabled": false },
    "dnsFlush": { "enabled": true },
    "windowsUpdateCache": { "enabled": false, "olderThanDays": 10 },
    "powerPlan": { "enabled": false, "plan": "HighPerformance" },
    "closeProcesses": { "enabled": false, "names": ["OneDrive", "Teams"] },
    "ssdTrim": { "enabled": true, "intervalDays": 7 },
    "lowDiskWarningGB": 15,
    "notification": { "enabled": true },
    "logRetentionDays": 30
}
```

- `powerPlan.plan`: `Balanced`, `HighPerformance`, `PowerSaver` o `Ultimate`.
- `closeProcesses.names`: nombres de proceso sin `.exe`.
- Las rutas admiten variables de entorno (`%TEMP%`, `%LOCALAPPDATA%`…).

Si reinstalas, tu `config.json` se conserva.

## Uso manual

```powershell
# Simulación: muestra qué haría sin borrar nada
& "$env:ProgramData\PCOptimizer\Optimize-PC.ps1" -WhatIf -Verbose

# Ejecutar la tarea ahora
Start-ScheduledTask PCOptimizer
```

Los registros quedan en `C:\ProgramData\PCOptimizer\logs` (se guardan 30 días).

## Desinstalación

```powershell
.\uninstall.ps1             # quita la tarea y la carpeta
.\uninstall.ps1 -KeepLogs   # conserva logs y configuración
```

## Desarrollo

```
src/
  Optimize-PC.ps1     # punto de entrada (lo ejecuta la tarea programada)
  PCOptimizer.psm1    # funciones de optimización
  config.json         # configuración por defecto
tests/                # pruebas Pester 5
install.ps1 / install.cmd / uninstall.ps1
```

Ejecutar las pruebas:

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester ./tests
```

La integración continua (GitHub Actions) ejecuta PSScriptAnalyzer, las pruebas y una simulación completa en Windows PowerShell 5.1 y PowerShell 7.

## Licencia

MIT
