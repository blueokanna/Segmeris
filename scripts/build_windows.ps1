param([switch] $NoPub)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & (Join-Path $PSScriptRoot 'setup_nuget.ps1')
    $flutterCommand = Get-Command flutter -CommandType Application -ErrorAction Stop
    $env:FLUTTER_ROOT = Split-Path -Parent (Split-Path -Parent $flutterCommand.Source)
    if (-not $NoPub) {
        & flutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }
    }
    & flutter build windows --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
} finally {
    Pop-Location
}
