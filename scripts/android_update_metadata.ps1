param(
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$CatalogPath,
    [switch]$Validate
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$apk = (Resolve-Path -LiteralPath $ApkPath).Path
$app = Join-Path $root 'app'
$versionMatch = [regex]::Match([IO.File]::ReadAllText((Join-Path $app 'pubspec.yaml')), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
if (-not $versionMatch.Success) { throw 'Android application version is invalid.' }
$version = $versionMatch.Groups[1].Value
$build = [int]$versionMatch.Groups[2].Value
$localProperties = Join-Path $app 'android\local.properties'
$sdkLine = Get-Content -LiteralPath $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
if (-not $sdkLine) { throw 'Android SDK location is missing.' }
$sdk = (($sdkLine -replace '^sdk\.dir=', '') -replace '\\\\', '\') -replace '\\:', ':'
$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'aapt.exe')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner.bat')) } |
    Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending |
    Select-Object -First 1
if (-not $buildTools) { throw 'Android build-tools with aapt and apksigner are required.' }

$badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apk
if ($LASTEXITCODE -ne 0) { throw 'Could not read Android package metadata.' }
$packageLine = @($badging | Where-Object { $_ -like 'package:*' }) -join ''
$package = [regex]::Match($packageLine, "name='([^']+)' versionCode='(\d+)' versionName='([^']+)'")
$minimum = [regex]::Match(($badging -join "`n"), "(?m)^sdkVersion:'(\d+)'")
$target = [regex]::Match(($badging -join "`n"), "(?m)^targetSdkVersion:'(\d+)'")
$native = [regex]::Match(($badging -join "`n"), "(?m)^native-code:(.*)$")
if (-not $package.Success -or -not $minimum.Success -or -not $target.Success -or
    $package.Groups[1].Value -ne 'io.github.leobrqz.windfull_app' -or
    $package.Groups[2].Value -ne "$build" -or $package.Groups[3].Value -ne $version) {
    throw 'APK package ID or version does not match the project manifests.'
}
$abis = @()
if ($native.Success) {
    $abis = @([regex]::Matches($native.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
}
if ($abis.Count -eq 0) { throw 'APK does not declare any supported Android ABI.' }

$signerOutput = & (Join-Path $buildTools.FullName 'apksigner.bat') verify --print-certs $apk
if ($LASTEXITCODE -ne 0) { throw 'APK signing verification failed.' }
$signerMatch = [regex]::Match(($signerOutput -join "`n"), 'certificate SHA-256 digest:\s*([A-Fa-f0-9]{64})')
if (-not $signerMatch.Success) { throw 'APK signing certificate digest is missing.' }
$apkName = 'Windfull-Android-universal-release.apk'
$file = Get-Item -LiteralPath $apk
$catalog = [ordered]@{
    packageName = $package.Groups[1].Value
    versionName = $version
    versionCode = $build
    minSdk = [int]$minimum.Groups[1].Value
    targetSdk = [int]$target.Groups[1].Value
    abis = $abis
    assetName = $apkName
    size = $file.Length
    sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    signerSha256 = $signerMatch.Groups[1].Value.ToLowerInvariant()
    downloadUrl = "https://github.com/leobrqz/Windfull/releases/download/v$version/$apkName"
    releaseUrl = "https://github.com/leobrqz/Windfull/releases/tag/v$version"
}

if ($Validate) {
    $existing = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
    foreach ($key in $catalog.Keys) {
        if ($key -eq 'abis') {
            if (($existing.abis -join ',') -cne ($catalog.abis -join ',')) { throw 'Android update catalog ABI list is stale.' }
        } elseif ($existing.$key -cne $catalog[$key]) {
            throw "Android update catalog field '$key' is stale."
        }
    }
} else {
    $destination = [IO.Path]::GetFullPath($CatalogPath)
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [IO.File]::WriteAllText($destination, ($catalog | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}

Get-Item -LiteralPath $CatalogPath
