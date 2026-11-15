#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\PCOptimizer.psm1') -Force
}

Describe 'Test-SafeCleanupPath' {
    It 'rechaza rutas vacías' {
        Test-SafeCleanupPath -Path '' | Should -BeFalse
        Test-SafeCleanupPath -Path $null | Should -BeFalse
    }
    It 'rechaza la raíz de la unidad' {
        $root = [System.IO.Path]::GetPathRoot((Get-Location).Path)
        Test-SafeCleanupPath -Path $root | Should -BeFalse
    }
    It 'rechaza la carpeta de Windows y System32' -Skip:(-not $env:SystemRoot) {
        Test-SafeCleanupPath -Path $env:SystemRoot | Should -BeFalse
        Test-SafeCleanupPath -Path (Join-Path $env:SystemRoot 'System32') | Should -BeFalse
        Test-SafeCleanupPath -Path (Join-Path $env:SystemRoot 'System32\drivers') | Should -BeFalse
    }
    It 'rechaza el perfil de usuario completo' -Skip:(-not $env:USERPROFILE) {
        Test-SafeCleanupPath -Path $env:USERPROFILE | Should -BeFalse
    }
    It 'acepta una carpeta temporal' {
        Test-SafeCleanupPath -Path (Join-Path $TestDrive 'temp') | Should -BeTrue
    }
}

Describe 'Expand-ConfigPath' {
    It 'expande variables de entorno' {
        $env:PCOPT_TEST = $TestDrive
        Expand-ConfigPath -Path '%PCOPT_TEST%\sub' | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $TestDrive 'sub')))
    }
    It 'devuelve $null si la variable no existe' {
        Expand-ConfigPath -Path '%PCOPT_NO_EXISTE_123%\x' | Should -BeNullOrEmpty
    }
}

Describe 'Clear-FolderContent' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force | Out-Null
        $old = Join-Path $dir 'old.tmp'
        $oldSub = Join-Path $dir 'sub\old2.tmp'
        $new = Join-Path $dir 'new.tmp'
        Set-Content -Path $old -Value ('x' * 1000)
        Set-Content -Path $oldSub -Value ('y' * 500)
        Set-Content -Path $new -Value 'z'
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-10)
        (Get-Item $oldSub).LastWriteTime = (Get-Date).AddDays(-10)
    }

    It 'borra solo los archivos más antiguos que el límite' {
        $r = Clear-FolderContent -Path $dir -OlderThanDays 2
        $r.Deleted | Should -Be 2
        $r.Bytes | Should -BeGreaterThan 1000
        Test-Path $old | Should -BeFalse
        Test-Path $oldSub | Should -BeFalse
        Test-Path $new | Should -BeTrue
    }

    It 'no borra nada con -WhatIf' {
        $r = Clear-FolderContent -Path $dir -OlderThanDays 2 -WhatIf
        $r.Deleted | Should -Be 2
        Test-Path $old | Should -BeTrue
        Test-Path $oldSub | Should -BeTrue
    }

    It 'no hace nada si la carpeta no existe' {
        $r = Clear-FolderContent -Path (Join-Path $dir 'no-existe') -OlderThanDays 0
        $r.Deleted | Should -Be 0
    }

    It 'no sigue enlaces simbólicos fuera de la carpeta' {
        $outside = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $outside | Out-Null
        $victim = Join-Path $outside 'importante.txt'
        Set-Content -Path $victim -Value 'no borrar'
        (Get-Item $victim).LastWriteTime = (Get-Date).AddDays(-100)
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $dir 'link') -Target $outside -ErrorAction Stop | Out-Null
        } catch {
            Set-ItResult -Skipped -Because 'no se pueden crear enlaces simbólicos en este entorno'
            return
        }
        Clear-FolderContent -Path $dir -OlderThanDays 0 | Out-Null
        Test-Path $victim | Should -BeTrue
    }
}

Describe 'Get-OptimizerConfig' {
    It 'usa valores por defecto si no hay archivo' {
        $c = Get-OptimizerConfig -Path (Join-Path $TestDrive 'nada.json')
        $c.tempCleanup.enabled | Should -BeTrue
        $c.recycleBin.enabled | Should -BeFalse
    }
    It 'combina el archivo con los valores por defecto' {
        $p = Join-Path $TestDrive 'c.json'
        '{ "recycleBin": { "enabled": true }, "tempCleanup": { "olderThanDays": 5 } }' | Set-Content $p
        $c = Get-OptimizerConfig -Path $p
        $c.recycleBin.enabled | Should -BeTrue
        $c.tempCleanup.olderThanDays | Should -Be 5
        $c.tempCleanup.enabled | Should -BeTrue
        @($c.tempCleanup.paths).Count | Should -BeGreaterThan 0
    }
    It 'tolera un JSON inválido' {
        $p = Join-Path $TestDrive 'bad.json'
        '{ esto no es json' | Set-Content $p
        { Get-OptimizerConfig -Path $p } | Should -Not -Throw
    }
    It 'el config.json del repositorio es válido' {
        $p = Join-Path $PSScriptRoot '..\src\config.json'
        { Get-Content $p -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Format-Bytes' {
    It 'formatea tamaños' {
        Format-Bytes 512 | Should -Match 'B$'
        Format-Bytes (5MB) | Should -Match 'MB$'
        Format-Bytes (3GB) | Should -Match 'GB$'
    }
}
