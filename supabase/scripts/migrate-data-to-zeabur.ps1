# Export from official Supabase (public schema) and import to Zeabur (mp_checklist schema)
#
# Prerequisites:
#   1. PostgreSQL client (pg_dump / psql)
#   2. Run supabase/migrations/000_mp_checklist_schema.sql on Zeabur
#   3. Set PGRST_DB_SCHEMAS=public,mp_checklist on Zeabur
#
# Usage:
#   $env:SOURCE_DB = "postgresql://postgres.[ref]:[password]@...supabase.co:5432/postgres"
#   $env:TARGET_DB = "postgresql://postgres:[password]@[zeabur-host]:5432/postgres"
#   .\supabase\scripts\migrate-data-to-zeabur.ps1

param(
  [string]$SourceDb = $env:SOURCE_DB,
  [string]$TargetDb = $env:TARGET_DB,
  [string]$OutDir = (Join-Path $PSScriptRoot '..\..\tmp\migration')
)

if (-not $SourceDb -or -not $TargetDb) {
  Write-Error 'Set SOURCE_DB and TARGET_DB environment variables, or pass them as parameters.'
  exit 1
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$tables = @(
  'profiles',
  'checklists',
  'mp_tool_checklist',
  'checklist_collaborators'
)

Write-Host '==> 1/4 Exporting public schema data from source...'
foreach ($t in $tables) {
  pg_dump $SourceDb `
    --data-only --column-inserts --no-owner --no-privileges `
    --table="public.$t" `
    -f (Join-Path $OutDir "public_$t.sql")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host '==> 2/4 Rewriting schema: public -> mp_checklist...'
foreach ($t in $tables) {
  $src = Join-Path $OutDir "public_$t.sql"
  $dst = Join-Path $OutDir "mp_checklist_$t.sql"
  (Get-Content $src -Raw) `
    -replace 'INSERT INTO public\.', 'INSERT INTO mp_checklist.' `
    -replace 'public\.', 'mp_checklist.' |
    Set-Content $dst -Encoding UTF8
}

Write-Host '==> 3/4 Importing into Zeabur (disable FK/trigger checks)...'
$importParts = @('SET session_replication_role = replica;')

foreach ($t in $tables) {
  $tableSql = Join-Path $OutDir "mp_checklist_$t.sql"
  $importParts += Get-Content $tableSql -Raw
}

$importParts += 'SET session_replication_role = DEFAULT;'
$importParts += ''
$importParts += '-- fix mp_tool_checklist.id sequence'
$importParts += "SELECT setval(pg_get_serial_sequence('mp_checklist.mp_tool_checklist', 'id'), COALESCE((SELECT MAX(id) FROM mp_checklist.mp_tool_checklist), 1));"

$importFile = Join-Path $OutDir '_import_all.sql'
Set-Content $importFile ($importParts -join [Environment]::NewLine) -Encoding UTF8

psql $TargetDb -v ON_ERROR_STOP=1 -f $importFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '==> 4/4 Backfilling missing profiles...'
$backfillSql = @'
INSERT INTO mp_checklist.profiles (id, email)
SELECT DISTINCT c.user_id, u.email
FROM mp_checklist.checklists c
JOIN auth.users u ON u.id = c.user_id
LEFT JOIN mp_checklist.profiles p ON p.id = c.user_id
WHERE p.id IS NULL
ON CONFLICT (id) DO NOTHING;
'@

psql $TargetDb -v ON_ERROR_STOP=1 -c $backfillSql
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host 'Done. Update frontend Supabase URL/KEY and use schema(''mp_checklist'').'
