param(
    [string]$PerlBin,
    [string]$ReleaseNotes
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$server = Join-Path $root 'server'
$bundle = Join-Path $server 'build\windows\x64\runner\Release'
$output = Join-Path $root 'output\windows'
$archive = Join-Path $output 'Windfull-Windows-x64.zip'
$packageId = 'io.github.leobrqz.windfull.windows'
$versionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $server 'pubspec.yaml')), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'Windows product version is invalid.' }
$version = $versionMatch.Groups[1].Value
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
$toolManifest = Join-Path $root '.config\dotnet-tools.json'
$dotnetCommand = (Get-Command dotnet.exe -ErrorAction SilentlyContinue).Source
$localDotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if ((-not $dotnetCommand -or -not (& $dotnetCommand --list-sdks)) -and (Test-Path -LiteralPath $localDotnet)) {
    $dotnetCommand = $localDotnet
}
if (-not $dotnetCommand -or -not (& $dotnetCommand --list-sdks)) {
    throw 'The .NET SDK is required for the pinned Velopack packager.'
}
& $dotnetCommand tool restore --tool-manifest $toolManifest
if ($LASTEXITCODE -ne 0) { throw 'Pinned Velopack CLI restore failed.' }
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

    foreach ($required in @('velopack_libc.dll', 'LICENSE.velopack')) {
        if (-not (Test-Path -LiteralPath (Join-Path $bundle $required) -PathType Leaf)) {
            throw "Windows bundle is missing updater runtime file: $required"
        }
    }

    $packDirectory = Join-Path $server ("build\velopack\" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $packDirectory | Out-Null
    $packArguments = @('tool', 'run', 'vpk', '--', 'pack',
        '--packId', $packageId, '--packVersion', $version, '--packDir', $bundle,
        '--mainExe', 'windfull_server.exe', '--packTitle', 'WindFull', '--packAuthors', 'leobrqz',
        '--runtime', 'win-x64', '--channel', 'win-x64', '--delta', 'None', '--noInst',
        '--exclude', '.*\.pdb$', '--icon', (Join-Path $server 'windows\runner\resources\app_icon.ico'),
        '--outputDir', $packDirectory)
    if ($ReleaseNotes) {
        $notesPath = (Resolve-Path -LiteralPath $ReleaseNotes).Path
        $packArguments += @('--releaseNotes', $notesPath)
    }
    Push-Location $root
    try { & $dotnetCommand @packArguments }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Velopack packaging failed.' }

    $portable = Join-Path $packDirectory "$packageId-win-x64-Portable.zip"
    $fullPackage = Join-Path $packDirectory "$packageId-$version-win-x64-full.nupkg"
    $feed = Join-Path $packDirectory 'releases.win-x64.json'
    foreach ($artifact in @($portable, $fullPackage, $feed)) {
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
            throw "Velopack output is missing: $(Split-Path -Leaf $artifact)"
        }
    }
    Copy-Item -LiteralPath $portable -Destination $archive -Force
    Copy-Item -LiteralPath $fullPackage, $feed -Destination $output -Force

    $readme = @'
# WindFull para Windows

Extraia o ZIP completo em uma pasta com permissao de escrita e abra o WindFull.exe na raiz. Mantenha juntos o launcher, `Update.exe`, `current/` e `packages/` para preservar o atualizador.

O host fica na bandeja do sistema. Pareamentos, identidade do servidor e ajustes permanecem nos dados locais do usuario entre atualizacoes.

Esta e a primeira versao com atualizacao integrada. Se voce ja usava o ZIP anterior, feche o WindFull, extraia este pacote em uma pasta nova e abra pelo launcher incluido. Os dados do usuario nao sao apagados. Nas proximas versoes, aprove o download e a instalacao na aba **Atualizacoes** do app.

No Android, instale esta versao oficial uma vez para estabelecer a chave de assinatura permanente. O Android exige a mesma chave em cada atualizacao posterior.

Os hashes SHA-256 dos artefatos Windows estão em `SHA256SUMS.txt`.
'@
    Set-Content -LiteralPath (Join-Path $output 'README.md') -Value $readme -Encoding utf8
    $checksums = foreach ($artifact in @($archive, (Join-Path $output (Split-Path -Leaf $fullPackage)), (Join-Path $output (Split-Path -Leaf $feed)))) {
        "$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $(Split-Path -Leaf $artifact)"
    }
    Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Value $checksums -Encoding ascii
    Get-Item -LiteralPath $archive, (Join-Path $output 'SHA256SUMS.txt')
}
finally {
    $env:PATH = $processPath
}
