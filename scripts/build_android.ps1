param([switch]$AllowDebugSigning)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$app = Join-Path $root 'app'
$keyProperties = Join-Path $app 'android\key.properties'
$output = Join-Path $root 'output\android'
$source = Join-Path $app 'build\app\outputs\flutter-apk\app-release.apk'
$destination = Join-Path $output 'Windfull-Android-universal-release.apk'
$catalog = Join-Path $output 'android-update.json'

if (-not (Test-Path -LiteralPath $keyProperties) -and -not $AllowDebugSigning) {
    throw 'Configure app/android/key.properties for release signing, or use -AllowDebugSigning for local tests only.'
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
$oldDebugSigning = $env:WINDFULL_ALLOW_DEBUG_SIGNING
$env:WINDFULL_ALLOW_DEBUG_SIGNING = if ($AllowDebugSigning) { '1' } else { '0' }
Push-Location $app
try {
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "Flutter dependency resolution failed ($LASTEXITCODE)." }
    & flutter build apk --release --no-pub
    if ($LASTEXITCODE -ne 0) { throw "Android build failed ($LASTEXITCODE)." }
}
finally {
    Pop-Location
    $env:WINDFULL_ALLOW_DEBUG_SIGNING = $oldDebugSigning
}

if (-not (Test-Path -LiteralPath $source)) { throw "APK not found: $source" }
Copy-Item -LiteralPath $source -Destination $destination -Force
$metadataScript = Join-Path $PSScriptRoot 'android_update_metadata.ps1'
& $metadataScript -ApkPath $destination -CatalogPath $catalog
if ($LASTEXITCODE -ne 0) { throw 'Android update metadata generation failed.' }
$checksums = foreach ($artifact in @($destination, $catalog)) {
    "$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $(Split-Path -Leaf $artifact)"
}
Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Value $checksums -Encoding ascii
if (-not (Test-Path -LiteralPath $keyProperties)) {
    Write-Warning 'APK uses the local debug signing key and is for local testing only.'
}
Get-Item -LiteralPath $destination, (Join-Path $output 'SHA256SUMS.txt')
