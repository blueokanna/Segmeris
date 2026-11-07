$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$version = '7.9.0'
$expectedHash = '992d70cac5b06c38efec91806caba64cdcc07e6d963a0959dbbbaf264d33b800'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolDirectory = Join-Path $repositoryRoot "build/tools/nuget/$version"
$executable = Join-Path $toolDirectory 'nuget.exe'

function Test-VerifiedNuGet([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $expectedHash) {
        return $false
    }
    return (Get-AuthenticodeSignature -LiteralPath $Path).Status -eq 'Valid'
}

if (-not (Test-VerifiedNuGet $executable)) {
    New-Item -ItemType Directory -Force -Path $toolDirectory | Out-Null
    $token = [Guid]::NewGuid().ToString('N')
    $package = Join-Path $toolDirectory "$token.nupkg"
    $candidate = Join-Path $toolDirectory "$token.exe"
    $sources = @(
        "https://api.nuget.org/v3-flatcontainer/nuget.commandline/$version/nuget.commandline.$version.nupkg",
        "https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet-public/nuget/v3/flat2/nuget.commandline/$version/nuget.commandline.$version.nupkg"
    )
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($source in $sources) {
            Write-Host "Downloading NuGet $version from $([Uri]::new($source).Host)..."
            & curl.exe --ipv4 --fail --location --proto '=https' --proto-redir '=https' `
                --connect-timeout 15 --max-time 60 --retry 1 --retry-delay 1 `
                --silent --show-error --output $package $source
            if ($LASTEXITCODE -ne 0) { continue }

            $archive = [IO.Compression.ZipFile]::OpenRead($package)
            try {
                $entry = $archive.GetEntry('tools/NuGet.exe')
                if ($null -eq $entry) { throw 'NuGet package has no command-line executable.' }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $candidate, $true)
            } finally {
                $archive.Dispose()
            }
            if (-not (Test-VerifiedNuGet $candidate)) {
                throw 'NuGet SHA-256 or Authenticode verification failed.'
            }
            Move-Item -LiteralPath $candidate -Destination $executable -Force
            break
        }
        if (-not (Test-VerifiedNuGet $executable)) {
            throw 'NuGet download failed from both official sources. Check HTTPS access to api.nuget.org and pkgs.dev.azure.com, then rerun this script.'
        }
    } finally {
        foreach ($temporaryFile in @($package, $candidate)) {
            if (Test-Path -LiteralPath $temporaryFile) {
                Remove-Item -LiteralPath $temporaryFile -Force
            }
        }
    }
}

$env:PATH = "$toolDirectory;$env:PATH"
$env:SEGMERIS_NUGET = $executable
if ($env:GITHUB_PATH) {
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $toolDirectory -Encoding UTF8
}
Write-Host "Verified NuGet ${version}: $executable"
