param(
    [string] $Bundle = 'build/windows/x64/runner/Release',
    [string] $Destination = 'dist/windows/Segmeris-windows-x64.zip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-X64Pe([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $Path))
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "Invalid PE file: $Path"
    }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or
        [BitConverter]::ToUInt32($bytes, $offset) -ne 0x00004550 -or
        [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) {
        throw "Expected a Windows x64 PE binary: $Path"
    }
}

foreach ($file in @('segmeris.exe', 'flutter_windows.dll', 'rust_lib_segmeris.dll',
                    'data/icudtl.dat', 'data/app.so', 'data/flutter_assets/AssetManifest.bin')) {
    if (-not (Test-Path (Join-Path $Bundle $file) -PathType Leaf)) { throw "Missing bundled runtime: $file" }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Could not locate the Visual C++ runtime installation.' }
$redistRoot = Join-Path $installation 'VC/Redist/MSVC'
$redist = Get-ChildItem $redistRoot -Directory | Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
    Sort-Object { [version]$_.Name } -Descending | ForEach-Object {
        Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
    } | Select-Object -First 1
if (-not $redist) { throw 'Could not locate redistributable x64 Microsoft.VC*.CRT DLLs.' }
Get-ChildItem $redist.FullName -Filter '*.dll' | Copy-Item -Destination $Bundle -Force
foreach ($file in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not (Test-Path (Join-Path $Bundle $file))) { throw "Missing Visual C++ runtime: $file" }
}
$runtime = Join-Path (Resolve-Path -LiteralPath $Bundle) 'runtime'
$bootstrapper = Join-Path $runtime 'MicrosoftEdgeWebview2Setup.exe'
Get-ChildItem $Bundle -Recurse -File | Where-Object {
    $_.Extension -in @('.dll', '.exe') -and $_.FullName -ne $bootstrapper
} |
    ForEach-Object { Assert-X64Pe $_.FullName }

# WebView2Loader.dll is normally supplied by the plugin (some SDKs link it statically).
# The Evergreen browser runtime is a separate Microsoft installation, not that loader.
New-Item -ItemType Directory -Force $runtime | Out-Null
Invoke-WebRequest 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $bootstrapper
$signature = Get-AuthenticodeSignature $bootstrapper
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
    throw 'WebView2 bootstrapper must have a valid Microsoft Authenticode signature.'
}
# The Evergreen bootstrapper itself may be x86; it installs the correct system runtime.
@'
Segmeris for Windows 10/11 x64

Extract the whole zip, then start segmeris.exe. Keep data/ and all DLLs together.
The archive includes Flutter, the Rust bridge, plugins and app-local Visual C++
runtime DLLs. Windows supplies the Universal CRT.

The embedded browser requires Microsoft Edge WebView2 Evergreen Runtime. If it
is missing, run runtime/MicrosoftEdgeWebview2Setup.exe (Microsoft-signed; internet
access required), then restart Segmeris. For offline installation obtain the x64
Evergreen Standalone Installer from https://developer.microsoft.com/microsoft-edge/webview2/.
The browser runtime is not bundled as a fixed-version offline browser.

GitHub release builds include FFmpeg and ffprobe in tools/. Install yt-dlp separately for sites that use it.
Segmeris itself is not Authenticode signed; Windows may show publisher warnings.
'@ | Set-Content (Join-Path $Bundle 'README-runtime.txt') -Encoding utf8
New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
Compress-Archive -Path (Join-Path $Bundle '*') -DestinationPath $Destination -Force
Write-Output "Packaged Windows runtime: $Destination"
