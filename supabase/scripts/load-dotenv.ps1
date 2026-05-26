# Load repo root .env into current process (for migration scripts)
param([string]$EnvFile = (Join-Path $PSScriptRoot '..\..\.env'))

if (-not (Test-Path $EnvFile)) {
  Write-Error "Missing .env at $EnvFile"
  exit 1
}

Get-Content $EnvFile | ForEach-Object {
  $line = $_.Trim()
  if (-not $line -or $line.StartsWith('#')) { return }
  $eq = $line.IndexOf('=')
  if ($eq -lt 1) { return }
  $name = $line.Substring(0, $eq).Trim()
  $value = $line.Substring($eq + 1).Trim()
  Set-Item -Path "Env:$name" -Value $value
}
