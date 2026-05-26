# Test Zeabur Postgres external connection (loads .env, does not print passwords)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'load-dotenv.ps1')

$pgBin = @(
  'C:\Program Files\PostgreSQL\18\bin',
  'C:\Program Files\PostgreSQL\17\bin'
) | Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
if (-not $pgBin) { Write-Error 'psql not found.' }
$psql = Join-Path $pgBin 'psql.exe'

$pgHost = $env:TARGET_PG_HOST
$port = if ($env:TARGET_PG_PORT) { $env:TARGET_PG_PORT } else { '30206' }
$user = if ($env:TARGET_PG_USER) { $env:TARGET_PG_USER } else { 'postgres' }
$db = if ($env:TARGET_PG_DATABASE) { $env:TARGET_PG_DATABASE } else { 'postgres' }
$pwd = $env:TARGET_PG_PASSWORD

if (-not $pgHost -and $env:TARGET_DB) {
  if ($env:TARGET_DB -match '@([^:/]+):(\d+)/([^?]+)') {
    $pgHost = $Matches[1]
    $port = $Matches[2]
    $db = $Matches[3]
  }
}

if (-not $pwd -and $env:TARGET_DB -match 'postgresql://([^:]+):([^@]+)@') {
  $user = $Matches[1]
  $pwd = [Uri]::UnescapeDataString($Matches[2])
}

Write-Host "Host: $pgHost  Port: $port  User: $user  Database: $db"
if (-not $pgHost -or -not $pwd) {
  Write-Host ''
  Write-Host 'Set in .env either TARGET_DB or all of:'
  Write-Host '  TARGET_PG_HOST=8.213.234.32'
  Write-Host '  TARGET_PG_PORT=30206'
  Write-Host '  TARGET_PG_USER=postgres'
  Write-Host '  TARGET_PG_PASSWORD=<from Zeabur Postgres POSTGRES_PASSWORD>'
  Write-Host '  TARGET_PG_DATABASE=postgres'
  exit 1
}

$env:PGPASSWORD = $pwd
& $psql -h $pgHost -p $port -U $user -d $db -v ON_ERROR_STOP=1 -c 'SELECT current_user, current_database();'
$code = $LASTEXITCODE
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue

if ($code -eq 0) {
  Write-Host 'OK: password and connection work. You can run run-migration.ps1.'
} else {
  Write-Host ''
  Write-Host 'Still failing? In Zeabur open the POSTGRES service (database container):'
  Write-Host '  Variables -> POSTGRES_PASSWORD (copy exact value, no spaces)'
  Write-Host '  Do NOT use SUPABASE_ANON_KEY or JWT_SECRET.'
  Write-Host '  After changing password in Zeabur, redeploy Postgres then retry.'
  exit $code
}
