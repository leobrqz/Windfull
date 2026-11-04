param(
    [string]$PerlBin,
    [string]$ReleaseNotes
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$server = Join-Path $root 'server'
$web = Join-Path $server 'web'
$tauri = Join-Path $server 'src-tauri'
$output = Join-Path $root 'output\windows'
$archive = Join-Path $output 'Windfull-Windows-x64.zip'
$packageId = 'io.github.leobrqz.windfull.windows'
$channel = 'win-x64'
$versionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $tauri 'Cargo.toml')), '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"\s*$')
if (-not $versionMatch.Success) { throw 'Tauri host Cargo package version is invalid.' }
$version = $versionMatch.Groups[1].Value
$bridgeManifest = Join-Path $server 'native\samsung\Cargo.toml'
$bridgeExecutable = Join-Path $server 'native\samsung\target\release\windfull-samsung-ocf.exe'
$hostExecutable = Join-Path $tauri 'target\release\windfull_server.exe'
$iconPath = Join-Path $tauri 'icons\windfull.ico'
$velopackLicense = Join-Path $tauri 'LICENSE.velopack'
$stage = Join-Path $tauri ("build\velopack\stage-" + [guid]::NewGuid().ToString('N'))
$processPath = $env:PATH
$tempTauriConfig = Join-Path $env:TEMP ("windfull-tauri-build-" + [guid]::NewGuid().ToString('N') + '.json')

function Resolve-StrawberryPerlBin([string]$RequestedPath) {
    $candidates = @()
    if ($RequestedPath) { $candidates += $RequestedPath }
    else {
        $candidates += @(
            (Join-Path $env:LOCALAPPDATA 'WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin'),
            'C:\Strawberry\perl\bin',
            (Join-Path $env:ProgramFiles 'Strawberry\perl\bin')
        )
        if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Strawberry\perl\bin') }
        $pathPerl = Get-Command perl.exe -ErrorAction SilentlyContinue
        if ($pathPerl -and $pathPerl.Source -match '(?i)strawberry') { $candidates += (Split-Path -Parent $pathPerl.Source) }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $resolved = [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"'))
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            if ((Split-Path -Leaf $resolved) -ieq 'perl.exe') { return (Split-Path -Parent (Resolve-Path -LiteralPath $resolved).Path) }
            continue
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            if (Test-Path -LiteralPath (Join-Path $resolved 'perl.exe') -PathType Leaf) { return (Resolve-Path -LiteralPath $resolved).Path }
        }
    }
    return $null
}

if (-not (Test-Path -LiteralPath $bridgeManifest -PathType Leaf)) { throw "Samsung bridge Cargo manifest is missing: $bridgeManifest" }
if (-not (Test-Path -LiteralPath (Join-Path $tauri 'Cargo.toml') -PathType Leaf)) { throw "Tauri host manifest is missing: $(Join-Path $tauri 'Cargo.toml')" }
if (-not (Test-Path -LiteralPath (Join-Path $web 'package-lock.json') -PathType Leaf)) { throw "Frontend npm lockfile is missing: $(Join-Path $web 'package-lock.json')" }
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'WindFull tray icon is missing from the Tauri build assets.' }
if (-not (Test-Path -LiteralPath $velopackLicense -PathType Leaf)) { throw 'Velopack MIT license notice is missing from the Tauri build assets.' }

$resolvedPerlBin = Resolve-StrawberryPerlBin $PerlBin
if (-not $resolvedPerlBin) {
    throw @'
Strawberry Perl is required to build the Samsung OpenSSL bridge.
Install Strawberry Perl or pass -PerlBin <path-to-perl-bin>.
The supported portable location is %LOCALAPPDATA%\WindfullBuildTools\strawberry-perl-5.42.3.1\perl\bin.
'@
}
if (-not (Get-Command cargo.exe -ErrorAction SilentlyContinue)) { throw 'Rust/Cargo is required. Install the Rust MSVC toolchain and restart PowerShell.' }
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'Node.js/npm is required to build the Tauri interface.' }

New-Item -ItemType Directory -Path $output -Force | Out-Null
$toolManifest = Join-Path $root '.config\dotnet-tools.json'
$dotnetCommand = (Get-Command dotnet.exe -ErrorAction SilentlyContinue).Source
$localDotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
if ((-not $dotnetCommand -or -not (& $dotnetCommand --list-sdks)) -and (Test-Path -LiteralPath $localDotnet)) { $dotnetCommand = $localDotnet }
if (-not $dotnetCommand -or -not (& $dotnetCommand --list-sdks)) { throw 'The .NET SDK is required for the pinned Velopack packager.' }
& $dotnetCommand tool restore --tool-manifest $toolManifest
if ($LASTEXITCODE -ne 0) { throw 'Pinned Velopack CLI restore failed.' }

try {
    # Keep Strawberry Perl scoped to child processes launched for this build.
    $env:PATH = "$resolvedPerlBin;$processPath"
    & cargo build --release --locked --manifest-path $bridgeManifest
    if ($LASTEXITCODE -ne 0) { throw "Samsung bridge cargo build failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $bridgeExecutable -PathType Leaf)) { throw "Cargo completed without producing the Samsung bridge: $bridgeExecutable" }

    Push-Location $web
    try {
        & npm.cmd ci --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "Frontend npm ci failed ($LASTEXITCODE)." }
        & npx.cmd --no-install tauri --version
        if ($LASTEXITCODE -ne 0) { throw 'Pinned Tauri CLI is missing from server/web dependencies.' }
        $tauriCli = Join-Path $web 'node_modules\.bin\tauri.cmd'
        if (-not (Test-Path -LiteralPath $tauriCli -PathType Leaf)) { throw 'Pinned Tauri CLI executable is missing from server/web dependencies.' }
        # Tauri release version comes from Cargo; build the UI from the server project root.
        $buildConfig = @{ version = $version; build = @{ beforeBuildCommand = 'npm run build' } }
        [IO.File]::WriteAllText($tempTauriConfig, ($buildConfig | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
        Push-Location $server
        try { & $tauriCli build --config (Join-Path $tauri 'tauri.conf.json') --config $tempTauriConfig --no-bundle }
        finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "Tauri Windows build failed ($LASTEXITCODE)." }
    }
    finally { Pop-Location }

    foreach ($required in @($hostExecutable, $bridgeExecutable)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Windows build is missing required executable: $required" }
    }

    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath $hostExecutable -Destination (Join-Path $stage 'windfull_server.exe') -Force
    Copy-Item -LiteralPath $bridgeExecutable -Destination (Join-Path $stage 'windfull-samsung-ocf.exe') -Force
    Copy-Item -LiteralPath $velopackLicense -Destination (Join-Path $stage 'LICENSE.velopack') -Force
    if (-not (Test-Path -LiteralPath (Join-Path $stage 'windfull_server.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $stage 'windfull-samsung-ocf.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $stage 'LICENSE.velopack') -PathType Leaf)) {
        throw 'Tauri host staging is missing the host, OCF sidecar, or Velopack license.'
    }

    $packDirectory = Join-Path $tauri ("build\velopack\package-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $packDirectory | Out-Null
    $packArguments = @('tool', 'run', 'vpk', '--', 'pack',
        '--packId', $packageId, '--packVersion', $version, '--packDir', $stage,
        '--mainExe', 'windfull_server.exe', '--packTitle', 'WindFull', '--packAuthors', 'leobrqz',
        '--runtime', 'win-x64', '--channel', $channel, '--delta', 'None', '--noInst',
        '--exclude', '.*\.pdb$', '--icon', $iconPath,
        '--outputDir', $packDirectory)
    if ($ReleaseNotes) { $packArguments += @('--releaseNotes', (Resolve-Path -LiteralPath $ReleaseNotes).Path) }
    Push-Location $root
    try { & $dotnetCommand @packArguments }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Velopack packaging failed.' }

    $portable = Join-Path $packDirectory "$packageId-$channel-Portable.zip"
    $fullPackage = Join-Path $packDirectory "$packageId-$version-$channel-full.nupkg"
    $feed = Join-Path $packDirectory "releases.$channel.json"
    foreach ($artifact in @($portable, $fullPackage, $feed)) {
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) { throw "Velopack output is missing: $(Split-Path -Leaf $artifact)" }
    }

    # A release feed only describes the single full package attached to this release.
    $feedData = Get-Content -Raw -LiteralPath $feed | ConvertFrom-Json
    $feedData.Assets = @($feedData.Assets | Where-Object { $_.Version -eq $version -and $_.Type -eq 'Full' })
    if ($feedData.Assets.Count -ne 1) { throw 'Expected exactly one matching full update package in the feed.' }
    [IO.File]::WriteAllText($feed, ($feedData | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

    Copy-Item -LiteralPath $portable -Destination $archive -Force
    Copy-Item -LiteralPath $fullPackage, $feed -Destination $output -Force
    $readme = @'
# WindFull para Windows

Extraia o ZIP em uma pasta com permissao de escrita e abra o launcher WindFull.exe na raiz. Mantenha o launcher, `Update.exe`, `current/` e `packages/` juntos para habilitar as atualizacoes.

O host Tauri fica na bandeja do sistema e usa WebView2 do Windows. O pacote tambem inclui `windfull-samsung-ocf.exe`, usado pelo host para comunicacao com o aparelho. Pareamentos, identidade do servidor e ajustes ficam nos dados locais do usuario e sao preservados nas atualizacoes.

O aviso de licenca MIT do Velopack acompanha o aplicativo em `current/LICENSE.velopack`.

Esta e a primeira versao gerenciada para Windows. Se voce ja usa o ZIP anterior, feche o WindFull, extraia este pacote em uma pasta nova e inicie pelo launcher incluido. Nas proximas versoes, confira as notas e aprove o download e a reinicializacao na tela **Atualizacoes**.

No Android, instale a versao oficial assinada para estabelecer a chave permanente. O Android exige a mesma chave nas atualizacoes posteriores.

Os hashes SHA-256 dos artefatos Windows estao em `SHA256SUMS.txt`.
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
    Remove-Item -LiteralPath $tempTauriConfig -Force -ErrorAction SilentlyContinue
}
