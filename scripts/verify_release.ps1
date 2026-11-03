param(
    [switch]$AllowDebugSigning,
    [string]$PreviousApk
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-ProductVersion([string]$Path) {
    $content = [IO.File]::ReadAllText($Path)
    $match = [regex]::Match($content, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
    if (-not $match.Success) { throw "Invalid product version in $Path" }
    return @{
        Name = "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
        Major = [int]$match.Groups[1].Value
        Minor = [int]$match.Groups[2].Value
        Patch = [int]$match.Groups[3].Value
        Build = [int]$match.Groups[4].Value
    }
}

function Assert-Checksum([string]$Artifact, [string]$ChecksumFile) {
    $line = [IO.File]::ReadAllText($ChecksumFile).Trim()
    $match = [regex]::Match($line, '^([A-Fa-f0-9]{64})  ([^/\\\r\n]+)$')
    if (-not $match.Success -or $match.Groups[2].Value -cne (Split-Path -Leaf $Artifact)) {
        throw "Invalid checksum file: $ChecksumFile"
    }
    if ((Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash -ne $match.Groups[1].Value) {
        throw "Checksum mismatch: $Artifact"
    }
}

function Get-ApkSigner([string]$Apk, [string]$SignerTool) {
    $output = & $SignerTool verify --print-certs $Apk
    if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed: $Apk" }
    $matches = [regex]::Matches(($output -join [Environment]::NewLine), 'certificate SHA-256 digest:\s*([A-Fa-f0-9]{64})')
    if ($matches.Count -ne 1) { throw "Expected exactly one APK signing certificate: $Apk" }
    return $matches[0].Groups[1].Value.ToLowerInvariant()
}

$appVersion = Read-ProductVersion (Join-Path $root 'app\pubspec.yaml')
$serverVersion = Read-ProductVersion (Join-Path $root 'server\pubspec.yaml')
if ($appVersion.Name -ne $serverVersion.Name -or $appVersion.Build -ne $serverVersion.Build) {
    throw 'Android and Windows product versions and build numbers must match.'
}
if (-not $AllowDebugSigning -and -not (Test-Path -LiteralPath (Join-Path $root 'app\android\key.properties'))) {
    throw 'Release signing configuration is missing. Use -AllowDebugSigning only for local tests.'
}

$apk = Join-Path $root 'output\android\Windfull-Android-universal-release.apk'
$archive = Join-Path $root 'output\windows\Windfull-Windows-x64.zip'
Assert-Checksum $apk (Join-Path $root 'output\android\SHA256SUMS.txt')
Assert-Checksum $archive (Join-Path $root 'output\windows\SHA256SUMS.txt')

$properties = Join-Path $root 'app\android\local.properties'
$sdkLine = Get-Content -LiteralPath $properties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
if (-not $sdkLine) { throw 'Android SDK location is missing from app/android/local.properties.' }
$sdk = (($sdkLine -replace '^sdk\.dir=', '') -replace '\\\\', '\') -replace '\\:', ':'
$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'aapt.exe')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner.bat')) } |
    Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending |
    Select-Object -First 1
if (-not $buildTools) { throw 'Android build-tools with aapt and apksigner were not found.' }

$badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apk
if ($LASTEXITCODE -ne 0) { throw 'Cannot read APK metadata.' }
$packageLine = @($badging | Where-Object { $_ -like 'package:*' }) -join ''
if ($packageLine -notmatch "name='io.github.leobrqz.windfull_app'" -or
    $packageLine -notmatch "versionName='$([regex]::Escape($appVersion.Name))'" -or
    $packageLine -notmatch "versionCode='$($appVersion.Build)'") {
    throw 'APK package, version name or build number does not match the project.'
}
$signerTool = Join-Path $buildTools.FullName 'apksigner.bat'
$signer = Get-ApkSigner $apk $signerTool
if ($PreviousApk) {
    $previousSigner = Get-ApkSigner (Resolve-Path -LiteralPath $PreviousApk).Path $signerTool
    if ($previousSigner -cne $signer) { throw 'APK signing certificate differs from the previous release.' }
}

$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entries = @{}
    foreach ($entry in $zip.Entries) { $entries[$entry.FullName.Replace('\', '/')] = $entry }
    foreach ($name in @('windfull_server.exe', 'windfull-samsung-ocf.exe', 'flutter_windows.dll', 'data/icudtl.dat', 'data/app.so')) {
        if (-not $entries.ContainsKey($name)) { throw "Missing Windows bundle file: $name" }
    }
    $temporary = [IO.Path]::GetTempFileName()
    try {
        $inputStream = $entries['windfull_server.exe'].Open()
        $outputStream = [IO.File]::Open($temporary, [IO.FileMode]::Create)
        try { $inputStream.CopyTo($outputStream) }
        finally { $inputStream.Dispose(); $outputStream.Dispose() }
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($temporary)
        if ($version.FileMajorPart -ne $serverVersion.Major -or
            $version.FileMinorPart -ne $serverVersion.Minor -or
            $version.FileBuildPart -ne $serverVersion.Patch -or
            $version.FilePrivatePart -ne $serverVersion.Build) {
            throw 'Windows executable version or build number does not match the project.'
        }
    }
    finally { Remove-Item -LiteralPath $temporary -Force }
}
finally { $zip.Dispose() }

$releaseOutput = Join-Path $root 'output\release'
New-Item -ItemType Directory -Path $releaseOutput -Force | Out-Null
$checksums = foreach ($artifact in @($apk, $archive)) {
    "$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $(Split-Path -Leaf $artifact)"
}
Set-Content -LiteralPath (Join-Path $releaseOutput 'SHA256SUMS.txt') -Value $checksums -Encoding ascii
Write-Output "Verified v$($appVersion.Name)+$($appVersion.Build); Android signer SHA-256: $signer"
Write-Output "Combined checksums: $(Join-Path $releaseOutput 'SHA256SUMS.txt')"
