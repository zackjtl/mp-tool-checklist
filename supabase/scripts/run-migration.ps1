# Run Zeabur data migration (loads .env, adds PostgreSQL bin to PATH)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $repoRoot

. (Join-Path $PSScriptRoot 'load-dotenv.ps1')

$pgCandidates = @(
  'C:\Program Files\PostgreSQL\18\bin',
  'C:\Program Files\PostgreSQL\17\bin',
  'C:\Program Files\PostgreSQL\16\bin'
)
$pgBin = $pgCandidates | Where-Object { Test-Path (Join-Path $_ 'pg_dump.exe') } | Select-Object -First 1
if (-not $pgBin) {
  Write-Error "pg_dump not found. Install PostgreSQL client tools."
}
$env:Path = "$pgBin;$env:Path"

if ($env:TARGET_PG_HOST -and $env:TARGET_PG_PASSWORD) {
  $port = if ($env:TARGET_PG_PORT) { $env:TARGET_PG_PORT } else { '30206' }
  $user = if ($env:TARGET_PG_USER) { $env:TARGET_PG_USER } else { 'postgres' }
  $db = if ($env:TARGET_PG_DATABASE) { $env:TARGET_PG_DATABASE } else { 'postgres' }
  $enc = [Uri]::EscapeDataString($env:TARGET_PG_PASSWORD)
  $env:TARGET_DB = "postgresql://${user}:${enc}@$($env:TARGET_PG_HOST):${port}/${db}"
  Write-Host 'Built TARGET_DB from TARGET_PG_* variables.'
}

if (-not $env:SOURCE_DB -or -not $env:TARGET_DB) {
  Write-Error "Set SOURCE_DB and TARGET_DB (or TARGET_PG_*) in repo root .env"
}

foreach ($label in @('SOURCE_DB', 'TARGET_DB')) {
  $uri = (Get-Item "Env:$label").Value
  if ($uri -match '^postgresql://postgresql://') {
    Write-Error "$label has duplicate 'postgresql://' prefix. Use exactly one, e.g. postgresql://postgres.ref:pass@host:5432/postgres"
  }
  if ($uri -notmatch '^postgresql://[^/]+@[^:/]+:\d+/') {
    Write-Error "$label URI format looks invalid. Copy Session pooler URI from Supabase Connect (one postgresql:// only)."
  }
}

Write-Host "PostgreSQL: $(pg_dump --version)"
function Test-DbConnection {
  param([string]$Label, [string]$Uri)
  Write-Host "Testing $Label..."
  psql $Uri -v ON_ERROR_STOP=1 -tAc "SELECT 1 AS ok" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "${Label} connection failed (exit $LASTEXITCODE). Check .env URI."
  }
}

if ($env:TARGET_DB -match 'zeabur\.internal') {
  Write-Error @"
TARGET_DB uses postgresql.zeabur.internal (Zeabur private host).
From your PC, use the Postgres service External/Public connection string instead.
"@
}

Test-DbConnection -Label 'TARGET_DB' -Uri $env:TARGET_DB
Test-DbConnection -Label 'SOURCE_DB' -Uri $env:SOURCE_DB

$migrateScript = Join-Path $PSScriptRoot 'migrate-data-to-zeabur.ps1'
& $migrateScript
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
