# List tables on SOURCE_DB (verify correct Supabase project before migration)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'load-dotenv.ps1')
$pgBin = @('C:\Program Files\PostgreSQL\18\bin', 'C:\Program Files\PostgreSQL\17\bin') |
  Where-Object { Test-Path (Join-Path $_ 'psql.exe') } | Select-Object -First 1
$env:Path = "$pgBin;$env:Path"

$expected = @('profiles', 'checklists', 'mp_tool_checklist', 'checklist_collaborators')
Write-Host 'SOURCE_DB user/host (from URI):'
if ($env:SOURCE_DB -match 'postgresql://([^:@]+)@([^:/]+)') {
  Write-Host "  user: $($Matches[1])"
  Write-Host "  host: $($Matches[2])"
}
Write-Host ''
Write-Host 'Expected tables (public schema):'
foreach ($t in $expected) {
  $n = psql $env:SOURCE_DB -tAc "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename='$t';"
  $mark = if ($n -eq '1') { 'OK' } else { 'MISSING' }
  Write-Host "  $t : $mark"
}
Write-Host ''
Write-Host 'Other public tables on this database:'
psql $env:SOURCE_DB -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"
