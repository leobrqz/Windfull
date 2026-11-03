param(
    [string]$PerlBin
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$server = Join-Path $root 'server'
$bundle = Join-Path $server 'build\windows\x64\runner\Release'
$output = Join-Path $root 'output\windows'
$archive = Join-Path $output 'Windfull-Windows-x64.zip'
$bridgeManifest = Join-Path $server 'native\samsung\Cargo.toml'
$bridgeExecutable = Join-Path $server 'native\samsung\target\release\windfull-samsung-ocf.exe'
$processPath = $env:PATH

function Resolve-StrawberryPerlBin([string]$RequestedPath) {
    $candidates = @()
    if ($RequestedPath) {
        $candidates += $RequestedPath
    }
    else {
        $candidates += @(
            (Join-Path $env:LOCALAPPDATA 'WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin'),
            'C:\Strawberry\perl\bin',
            (Join-Path $env:ProgramFiles 'Strawberry\perl\bin')
        )
        if (${env:ProgramFiles(x86)}) {
            $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Strawberry\perl\bin')
        }
        $pathPerl = Get-Command perl.exe -ErrorAction SilentlyContinue
        if ($pathPerl -and $pathPerl.Source -match '(?i)strawberry') {
            $candidates += (Split-Path -Parent $pathPerl.Source)
        }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $resolved = [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"'))
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            if ((Split-Path -Leaf $resolved) -ieq 'perl.exe') {
                return (Split-Path -Parent (Resolve-Path -LiteralPath $resolved).Path)
            }
            continue
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            $perlExe = Join-Path $resolved 'perl.exe'
            if (Test-Path -LiteralPath $perlExe -PathType Leaf) {
                return (Resolve-Path -LiteralPath $resolved).Path
            }
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $bridgeManifest -PathType Leaf)) {
    throw "Samsung bridge Cargo manifest is missing: $bridgeManifest"
}

$resolvedPerlBin = Resolve-StrawberryPerlBin $PerlBin
if (-not $resolvedPerlBin) {
    throw @'
Strawberry Perl is required to build the Samsung OpenSSL bridge.
Install Strawberry Perl or pass -PerlBin <path-to-perl-bin>.
The supported portable location is %LOCALAPPDATA%\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin.
'@
}
$perlExecutable = Join-Path $resolvedPerlBin 'perl.exe'
if (-not (Test-Path -LiteralPath $perlExecutable -PathType Leaf)) {
    throw "Perl executable not found in selected directory: $resolvedPerlBin"
}
if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) {
    throw 'Rust/Cargo is required. Install the Rust MSVC toolchain and restart PowerShell.'
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
try {
    # Expose Strawberry only to child processes started by this build script.
    $env:PATH = "$resolvedPerlBin;$processPath"
    & cargo build --release --locked --manifest-path $bridgeManifest
    if ($LASTEXITCODE -ne 0) {
        throw "Samsung bridge cargo build failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $bridgeExecutable -PathType Leaf)) {
        throw "Cargo completed without producing the required Samsung bridge: $bridgeExecutable"
    }

    Push-Location $server
    try {
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { throw "Flutter dependency resolution failed ($LASTEXITCODE)." }
        & flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw "Windows Flutter build failed ($LASTEXITCODE)." }
    }
    finally { Pop-Location }

    $serverExecutable = Join-Path $bundle 'windfull_server.exe'
    if (-not (Test-Path -LiteralPath $serverExecutable -PathType Leaf)) {
        throw "Windows Flutter bundle is missing the server executable: $serverExecutable"
    }
    Copy-Item -LiteralPath $bridgeExecutable -Destination (Join-Path $bundle 'windfull-samsung-ocf.exe') -Force
    if (-not (Test-Path -LiteralPath (Join-Path $bundle 'windfull-samsung-ocf.exe') -PathType Leaf)) {
        throw 'Failed to place windfull-samsung-ocf.exe beside windfull_server.exe.'
    }

    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $archive -Force
    $checksum = "$((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash)  $(Split-Path -Leaf $archive)"
    Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Value $checksum -Encoding ascii
    Get-Item -LiteralPath $archive, (Join-Path $output 'SHA256SUMS.txt')
}
finally {
    $env:PATH = $processPath
}
