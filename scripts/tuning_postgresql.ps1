<#
    tuning_postgresql.ps1 — SECOP Integrado

    Aplica el bloque de tuning para carga masiva sobre postgresql.conf y reinicia
    el servicio. Es idempotente: si el bloque ya existe, lo reemplaza en vez de
    duplicarlo, asi que se puede correr las veces que haga falta.

    El bloque va al FINAL del archivo, sobrescribiendo los valores de fabrica.
    postgresql.conf original queda intacto y auditable arriba.

    Uso (desde cualquier PowerShell, incluso sin permisos):
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tuning_postgresql.ps1

    Si no corre como Administrador, el script se relanza solo con RunAs y
    aparece el aviso de UAC. Aceptalo y continua.

    Requires -Version 5.1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
$Conf        = 'C:\Program Files\PostgreSQL\18\data\postgresql.conf'
$Servicio    = 'postgresql-x64-18'
$Binario     = 'C:\Program Files\PostgreSQL\18\bin'
$MarcaIni    = '# >>> SECOP-INTEGRADO tuning >>>'
$MarcaFin    = '# <<< SECOP-INTEGRADO tuning <<<'

# Valores de la sesion 1. La justificacion de cada uno esta en
# docs/instalacion-postgresql-dbeaver.md, seccion 3.1.
$ValoresOptimistas = @'
# --- Memoria ---
shared_buffers = 4GB
work_mem = 64MB
maintenance_work_mem = 1GB
effective_cache_size = 10GB

# --- WAL y checkpoints (carga masiva) ---
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_compression = on

# --- Planificador (SSD, no rotacional) ---
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 200

# --- Paralelismo ---
max_worker_processes = 8
max_parallel_workers = 6
max_parallel_workers_per_gather = 2

# --- Red: solo local, ver seccion 1.4 de la guia ---
listen_addresses = 'localhost'
port = 5432
max_connections = 100

# --- Diagnostico: registra consultas que tardan mas de 5 s (RNF-02) ---
log_min_duration_statement = 5000

# --- Autovacuum: la tabla se crea y se llena de una vez ---
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
'@

# Si hay poca RAM libre, estos. shared_buffers de 4 GB con menos de 5 GB libres
# hace que Windows empiece a intercambiar y la carga se frena.
$ValoresConservadores = @'
# --- Memoria (REBAJADA: habia menos de 5 GB libres al aplicar) ---
shared_buffers = 2GB
work_mem = 32MB
maintenance_work_mem = 1GB
effective_cache_size = 6GB

# --- WAL y checkpoints (carga masiva) ---
max_wal_size = 4GB
min_wal_size = 1GB
checkpoint_completion_target = 0.9
wal_compression = on

# --- Planificador (SSD, no rotacional) ---
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 200

# --- Paralelismo ---
max_worker_processes = 8
max_parallel_workers = 6
max_parallel_workers_per_gather = 2

# --- Red: solo local, ver seccion 1.4 de la guia ---
listen_addresses = 'localhost'
port = 5432
max_connections = 100

# --- Diagnostico: registra consultas que tardan mas de 5 s (RNF-02) ---
log_min_duration_statement = 5000

# --- Autovacuum: la tabla se crea y se llena de una vez ---
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
'@

# ---------------------------------------------------------------------------
# 1. Elevacion
# ---------------------------------------------------------------------------
$Actual = [Security.Principal.WindowsIdentity]::GetCurrent()
$EsAdmin = ([Security.Principal.WindowsPrincipal]$Actual).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host ' SECOP Integrado - tuning de PostgreSQL 18.6' -ForegroundColor Cyan
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host ''

if (-not $EsAdmin) {
    Write-Host 'No se tiene permisos de Administrador. Relanzando con RunAs...' -ForegroundColor Yellow
    Write-Host 'Aparece el aviso de UAC: seleccion "Si".' -ForegroundColor Yellow
    Write-Host ''
    $Argumentos = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', ('"{0}"' -f $PSCommandPath)
    )
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $Argumentos -Wait
    } catch {
        Write-Host ''
        Write-Host 'Se cancelo la elevacion o fallo. Correr esto en PowerShell como Administrador:' -ForegroundColor Red
        Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -ForegroundColor Yellow
        Write-Host ''
        Read-Host 'Enter para salir'
    }
    exit
}

Write-Host '[1/6] Administrador: SI' -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Comprobaciones previas
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Conf)) {
    Write-Host "No se encuentra $Conf" -ForegroundColor Red
    Read-Host 'Enter para salir'; exit 1
}

$Servicio_ = Get-Service -Name $Servicio -ErrorAction SilentlyContinue
if (-not $Servicio_) {
    Write-Host "No existe el servicio $Servicio" -ForegroundColor Red
    Read-Host 'Enter para salir'; exit 1
}
Write-Host "[2/6] postgresql.conf encontrado. Servicio: $($Servicio_.Status)" -ForegroundColor Green

$Sistema = Get-CimInstance Win32_OperatingSystem
$RamLibreGB = [math]::Round($Sistema.FreePhysicalMemory / 1MB, 1)
$RamTotalGB = [math]::Round($Sistema.TotalVisibleMemorySize / 1MB, 1)
Write-Host ("        RAM total {0} GB / libre ahora {1} GB" -f $RamTotalGB, $RamLibreGB)

if ($RamLibreGB -lt 5) {
    $Valores = $ValoresConservadores
    Write-Host ''
    Write-Host "ATENCION: hay menos de 5 GB libres ($RamLibreGB GB)." -ForegroundColor Yellow
    Write-Host 'Se aplican los valores CONSERVADORES (shared_buffers = 2GB,' -ForegroundColor Yellow
    Write-Host 'work_mem = 32MB) para que Windows no empiece a intercambiar.' -ForegroundColor Yellow
    Write-Host 'Si cerra las aplicaciones pesadas, puede volver a correr este' -ForegroundColor Yellow
    Write-Host 'script y subira a los valores completos.' -ForegroundColor Yellow
} else {
    $Valores = $ValoresOptimistas
    Write-Host '        Se aplican los valores COMPLETOS (shared_buffers = 4GB, work_mem = 64MB)' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 3. Backup
# ---------------------------------------------------------------------------
$Marca = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = "$Conf.pre-secop-$Marca"
Copy-Item -LiteralPath $Conf -Destination $Backup -Force
Write-Host "[3/6] Backup creado: $Backup" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Quitar el bloque anterior, si habia uno
# ---------------------------------------------------------------------------
$Lineas = [System.IO.File]::ReadAllLines($Conf)
$Ini = [Array]::IndexOf($Lineas, $MarcaIni)
$Fin = [Array]::IndexOf($Lineas, $MarcaFin)

if ($Ini -ge 0 -and $Fin -ge 0 -and $Fin -gt $Ini) {
    Write-Host "[4/6] Bloque SECOP anterior encontrado en las lineas $($Ini + 1)-$($Fin + 1). Se reemplaza." -ForegroundColor Green
    $Nueva = @()
    $Nueva += $Lineas[0..($Ini - 1)]
    $Nueva += $Lineas[($Fin + 1)..($Lineas.Length - 1)]
    $Lineas = $Nueva
} elseif ($Ini -ge 0 -or $Fin -ge 0) {
    throw "Se encontro solo una de las dos marcas ($MarcaIni / $MarcaFin). Revisar $Conf a mano antes de seguir."
} else {
    Write-Host '[4/6] No hay bloque SECOP previo. Se agrega al final.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 5. Escribir el bloque
# ---------------------------------------------------------------------------
$Encabezado = @(
    ''
    ''
    '# ============================================================'
    '# SECOP Integrado - tuning para carga de 16.025.993 filas'
    "# Aplicado: $(Get-Date -Format 'dd/MM/yyyy HH:mm') - responsable: Jose (ETL)"
    '# Justificacion de cada valor: docs/instalacion-postgresql-dbeaver.md 3.1'
    '# Este bloque va al final y sobrescribe los valores de fabrica.'
    '# Los valores originales de arriba NO se modifican.'
    '# ============================================================'
    $MarcaIni
)

$Salida = @()
$Salida += $Lineas
$Salida += $Encabezado
foreach ($Linea in ($Valores -split "`r?`n")) { $Salida += $Linea }
$Salida += $MarcaFin
$Salida += ''

[System.IO.File]::WriteAllLines($Conf, $Salida, (New-Object System.Text.UTF8Encoding $false))
Write-Host "[5/6] Bloque escrito en $Conf" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. Reiniciar y comprobar
# ---------------------------------------------------------------------------
Write-Host '[6/6] Reiniciando el servicio...' -ForegroundColor Green
Restart-Service -Name $Servicio -Force
Start-Sleep -Seconds 6

$Despues = Get-Service -Name $Servicio
Write-Host "        Servicio: $($Despues.Status)" -ForegroundColor Green

$IsReady = & "$Binario\pg_isready.exe" -h localhost -p 5432 2>&1
Write-Host "        $IsReady" -ForegroundColor Green

# shared_buffers solo se aplica al arrancar: si el servicio levanto, la config
# es valida. El detalle de cada valor se verifica despues con:
#   SELECT name, setting FROM pg_settings WHERE name IN (...);
Write-Host ''
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host ' Tuning aplicado. Verificar los valores con:' -ForegroundColor Cyan
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  SELECT name, setting, unit FROM pg_settings'
Write-Host "   WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem',"
Write-Host "                 'effective_cache_size','max_wal_size','min_wal_size',"
Write-Host "                 'random_page_cost','listen_addresses','max_parallel_workers',"
Write-Host "                 'wal_compression','log_min_duration_statement')"
Write-Host '   ORDER BY name;'
Write-Host ''
Write-Host "Backup del archivo original: $Backup"
Write-Host ''

# Informe en archivo: permite verificar el resultado sin depender de la
# ventana, que en una ejecucion elevada no se puede leer desde afuera.
$Informe = Join-Path $PSScriptRoot '..\logs\tuning_resultado.txt'
try {
    $Directorio = Split-Path -Parent $Informe
    if (-not (Test-Path -LiteralPath $Directorio)) {
        New-Item -ItemType Directory -Path $Directorio -Force | Out-Null
    }
    @(
        "aplicado   = $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "perfil     = $(if ($RamLibreGB -lt 5) { 'conservador' } else { 'completo' })"
        "ram_libre  = $RamLibreGB GB de $RamTotalGB GB"
        "backup     = $Backup"
        "servicio   = $($Despues.Status)"
        "isready    = $IsReady"
        "líneas     = $(([System.IO.File]::ReadAllLines($Conf)).Length)"
    ) | Set-Content -LiteralPath $Informe -Encoding UTF8
    Write-Host "Informe escrito en: $Informe" -ForegroundColor Green
} catch {
    Write-Host "No se pudo escribir el informe: $($_.Exception.Message)" -ForegroundColor Yellow
}
