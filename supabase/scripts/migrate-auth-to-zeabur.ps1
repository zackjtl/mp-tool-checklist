# Migrate auth.users + auth.identities from official Supabase to Zeabur
#
# Prerequisites:
#   1. PostgreSQL client (pg_dump / psql)
#   2. Business data already imported (migrate-data-to-zeabur.ps1 completed)
#   3. SOURCE_DB and TARGET_DB set (same as migrate-data-to-zeabur.ps1)
#
# Usage:
#   $env:SOURCE_DB = "postgresql://postgres.[ref]:[password]@...supabase.co:5432/postgres"
#   $env:TARGET_DB = "postgresql://postgres:[password]@[zeabur-host]:5432/postgres"
#   .\supabase\scripts\migrate-auth-to-zeabur.ps1
#
# Notes:
#   - auth.users and auth.identities are global in the shared Supabase instance
#   - Users are inserted with ON CONFLICT DO NOTHING (safe to re-run)
#   - After import, profiles backfill runs to fill any gaps
#   - Old JWT tokens from official Supabase will be invalid; users must re-login

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

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Read-SqlUtf8 {
  param([string]$Path)
  [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
}

function Write-SqlUtf8 {
  param([string]$Path, [string]$Content)
  [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

function Extract-InsertStatements {
  param([string]$Sql)
  $lines = $Sql -split "`r?`n"
  ($lines | Where-Object { $_ -match '^\s*INSERT INTO ' }) -join [Environment]::NewLine
}

# Add ON CONFLICT DO NOTHING to every INSERT statement
function Add-OnConflictDoNothing {
  param([string]$Sql)
  $Sql -replace '(?m);(\s*)$', ' ON CONFLICT DO NOTHING;$1'
}

# ---- Step 1: verify source tables exist ----
Write-Host '==> 1/4 Verifying source auth tables...'
foreach ($t in @('auth.users', 'auth.identities')) {
  $schema, $table = $t -split '\.'
  $exists = psql $SourceDb -tAc "SELECT 1 FROM pg_tables WHERE schemaname='$schema' AND tablename='$table' LIMIT 1;"
  if ($exists -ne '1') {
    Write-Error "Table $t not found in SOURCE_DB. Check your connection string."
    exit 1
  }
}
Write-Host '    auth.users and auth.identities found.'

# ---- Step 2: dump auth tables ----
Write-Host '==> 2/4 Exporting auth data from source (this may take a moment)...'

$dumpUsers = Join-Path $OutDir 'auth_users_raw.sql'
$dumpIdentities = Join-Path $OutDir 'auth_identities_raw.sql'

pg_dump $SourceDb `
  --data-only --column-inserts --no-owner --no-privileges `
  --table=auth.users `
  -f $dumpUsers
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

pg_dump $SourceDb `
  --data-only --column-inserts --no-owner --no-privileges `
  --table=auth.identities `
  -f $dumpIdentities
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Count rows for sanity check
$userCount = (psql $SourceDb -tAc "SELECT COUNT(*) FROM auth.users;").Trim()
$identityCount = (psql $SourceDb -tAc "SELECT COUNT(*) FROM auth.identities;").Trim()
Write-Host "    Source: $userCount users, $identityCount identities"

# ---- Step 3: process SQL (extract INSERTs + add ON CONFLICT) ----
Write-Host '==> 3/4 Processing SQL...'

$usersInserts = Extract-InsertStatements (Read-SqlUtf8 $dumpUsers)
$identitiesInserts = Extract-InsertStatements (Read-SqlUtf8 $dumpIdentities)

# Filter out transaction_timeout (unsupported in some Postgres versions)
$usersInserts = $usersInserts -replace '(?m)^.*transaction_timeout.*$', ''
$identitiesInserts = $identitiesInserts -replace '(?m)^.*transaction_timeout.*$', ''

$usersInserts = Add-OnConflictDoNothing $usersInserts
$identitiesInserts = Add-OnConflictDoNothing $identitiesInserts

$importParts = @(
  'SET client_encoding = ''UTF8'';',
  '-- Disable FK/trigger checks so identities can reference users freely',
  'SET session_replication_role = replica;',
  '',
  '-- auth.users (ON CONFLICT DO NOTHING = safe re-run)',
  $usersInserts,
  '',
  '-- auth.identities',
  $identitiesInserts,
  '',
  'SET session_replication_role = DEFAULT;'
)

$importFile = Join-Path $OutDir '_import_auth.sql'
Write-SqlUtf8 $importFile ($importParts -join [Environment]::NewLine)

# ---- Step 4: import into Zeabur ----
Write-Host '==> 4/4 Importing into Zeabur...'
psql $TargetDb -v ON_ERROR_STOP=1 -f $importFile
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Verify counts on target
$targetUserCount = (psql $TargetDb -tAc "SELECT COUNT(*) FROM auth.users;").Trim()
$targetIdentityCount = (psql $TargetDb -tAc "SELECT COUNT(*) FROM auth.identities;").Trim()
Write-Host "    Target after import: $targetUserCount users, $targetIdentityCount identities"

# ---- Backfill profiles (in case earlier migration ran before auth existed) ----
Write-Host '==> Backfilling mp_checklist.profiles for any missing auth users...'
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

Write-Host ''
Write-Host '=== Auth migration complete ==='
Write-Host "Source: $userCount users / $identityCount identities"
Write-Host "Target: $targetUserCount users / $targetIdentityCount identities"
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  1. Set up Google OAuth callback in Zeabur GoTrue (GOTRUE_EXTERNAL_GOOGLE_*)'
Write-Host '  2. Set SITE_URL and ADDITIONAL_REDIRECT_URLS in Zeabur Supabase env'
Write-Host '  3. Add Zeabur callback URL to Google Cloud Console Authorized Redirect URIs'
Write-Host '  4. If using Magic Link, configure SMTP in Zeabur'
Write-Host '  5. Old JWT tokens from official Supabase are invalid -- users must re-login'
