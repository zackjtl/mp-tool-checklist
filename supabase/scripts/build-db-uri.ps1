# Build postgresql:// URI from parts (avoids special-char bugs in hand-edited URIs)
param(
  [string]$User = 'postgres',
  [string]$Password,
  [string]$Host,
  [string]$Port = '5432',
  [string]$Database = 'postgres'
)

if (-not $Password -or -not $Host) {
  Write-Error 'Password and Host are required.'
}
$enc = [Uri]::EscapeDataString($Password)
"postgresql://${User}:${enc}@${Host}:${Port}/${Database}"
