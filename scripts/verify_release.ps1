param([string]$PreviousApk)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Read-Version([string]$Path) {
    $match = [regex]::Match([IO.File]::ReadAllText($Path), '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
    if (-not $match.Success) { throw "Invalid product version: $Path" }
    return @{
        Name = "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
        Major = [int]$match.Groups[1].Value
        Minor = [int]$match.Groups[2].Value
        Patch = [int]$match.Groups[3].Value
        Build = [int]$match.Groups[4].Value
    }
}

function Read-Cargo-Version([string]$Path) {
    $match = [regex]::Match([IO.File]::ReadAllText($Path), '(?m)^version\s*=\s*"(\d+)\.(\d+)\.(\d+)"\s*$')
    if (-not $match.Success) { throw "Invalid Tauri host package version: $Path" }
    return "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)"
}

function Read-Checksums([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Checksum file missing: $Path" }
    $entries = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -notmatch '^([A-Fa-f0-9]{64})  ([^/\\\r\n]+)$') { throw "Invalid checksum line: $Path" }
        $name = $Matches[2]
        if ($entries.ContainsKey($name)) { throw "Duplicate checksum for $name" }
        $entries[$name] = $Matches[1].ToLowerInvariant()
    }
    return $entries
}

function Assert-Checksum([string]$File, [hashtable]$Entries) {
    $name = Split-Path -Leaf $File
    if (-not $Entries.ContainsKey($name)) { throw "Checksum missing for $name" }
    $actual = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $Entries[$name]) { throw "Checksum mismatch: $name" }
}

function Get-ApkSigner([string]$Apk, [string]$SignerTool) {
    $output = & $SignerTool verify --print-certs $Apk
    if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed: $Apk" }
    $matches = [regex]::Matches(($output -join [Environment]::NewLine), 'certificate SHA-256 digest:\s*([A-Fa-f0-9]{64})')
    if ($matches.Count -ne 1) { throw "Expected one APK signing certificate: $Apk" }
    return $matches[0].Groups[1].Value.ToLowerInvariant()
}

function Get-ZipEntryText([IO.Compression.ZipArchive]$Archive, [string]$Name) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { throw "Missing archive entry: $Name" }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Export-ZipEntry([IO.Compression.ZipArchive]$Archive, [string]$Name, [string]$Destination) {
    $entry = $Archive.GetEntry($Name)
    if (-not $entry) { throw "Missing archive entry: $Name" }
    $input = $entry.Open()
    $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $input.CopyTo($output) } finally { $input.Dispose(); $output.Dispose() }
}

function Get-WindowsSubsystem([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = $null
    try {
        if ($stream.Length -lt 0x40) { throw "Invalid Windows executable: $Path" }
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $optionalHeaderOffset = $peOffset + 4 + 20
        if ($peOffset -lt 0 -or $optionalHeaderOffset + 70 -gt $stream.Length) {
            throw "Invalid PE header: $Path"
        }
        $stream.Position = $optionalHeaderOffset + 68
        return $reader.ReadUInt16()
    }
    finally {
        if ($reader) { $reader.Dispose() } else { $stream.Dispose() }
    }
}

$appVersion = Read-Version (Join-Path $root 'app\pubspec.yaml')
$serverVersion = Read-Cargo-Version (Join-Path $root 'server\src-tauri\Cargo.toml')
if ($appVersion.Name -cne $serverVersion) { throw 'Android release version and Tauri host version must match.' }
$tauriConfigPath = Join-Path $root 'server\src-tauri\tauri.conf.json'
if (-not (Test-Path -LiteralPath $tauriConfigPath -PathType Leaf)) { throw 'Tauri Windows configuration is missing.' }
$tauriConfig = Get-Content -Raw -LiteralPath $tauriConfigPath | ConvertFrom-Json
if ($tauriConfig.productName -cne 'WindFull' -or $tauriConfig.identifier -cne 'io.github.leobrqz.windfull.windows') {
    throw 'Tauri product identity does not match the Windows release package.'
}

$androidDirectory = Join-Path $root 'output\android'
$windowsDirectory = Join-Path $root 'output\windows'
$apk = Join-Path $androidDirectory 'Windfull-Android-universal-release.apk'
$catalog = Join-Path $androidDirectory 'android-update.json'
$portable = Join-Path $windowsDirectory 'Windfull-Windows-x64.zip'
$packageId = 'io.github.leobrqz.windfull.windows'
$fullPackage = Join-Path $windowsDirectory "$packageId-$serverVersion-win-x64-full.nupkg"
$feedPath = Join-Path $windowsDirectory 'releases.win-x64.json'

$androidChecksums = Read-Checksums (Join-Path $androidDirectory 'SHA256SUMS.txt')
$windowsChecksums = Read-Checksums (Join-Path $windowsDirectory 'SHA256SUMS.txt')
foreach ($file in @($apk, $catalog)) { Assert-Checksum $file $androidChecksums }
foreach ($file in @($portable, $fullPackage, $feedPath)) { Assert-Checksum $file $windowsChecksums }
if ($androidChecksums.Count -ne 2 -or $windowsChecksums.Count -ne 3) {
    throw 'Build checksum files contain unexpected artifacts.'
}

$localProperties = Join-Path $root 'app\android\local.properties'
$sdkLine = Get-Content -LiteralPath $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
if (-not $sdkLine) { throw 'Android SDK location is missing.' }
$sdk = (($sdkLine -replace '^sdk\.dir=', '') -replace '\\\\', '\') -replace '\\:', ':'
$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName 'aapt.exe')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'apksigner.bat')) } |
    Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -Descending | Select-Object -First 1
if (-not $buildTools) { throw 'Android build-tools were not found.' }

$badging = & (Join-Path $buildTools.FullName 'aapt.exe') dump badging $apk
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Android package metadata.' }
$packageLine = @($badging | Where-Object { $_ -like 'package:*' }) -join ''
if ($packageLine -notmatch "name='io.github.leobrqz.windfull_app'" -or
    $packageLine -notmatch "versionName='$([regex]::Escape($appVersion.Name))'" -or
    $packageLine -notmatch "versionCode='$($appVersion.Build)'") {
    throw 'APK package identity/version does not match the manifests.'
}

$signerTool = Join-Path $buildTools.FullName 'apksigner.bat'
$signer = Get-ApkSigner $apk $signerTool
if ($PreviousApk) {
    $previous = (Resolve-Path -LiteralPath $PreviousApk).Path
    if ((Get-ApkSigner $previous $signerTool) -cne $signer) {
        throw 'Android signing certificate differs from the previous release.'
    }
}

$catalogScript = Join-Path $PSScriptRoot 'android_update_metadata.ps1'
& $catalogScript -ApkPath $apk -CatalogPath $catalog -Validate | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Android update catalog does not match the APK.' }

$propertyPath = Join-Path $root 'app\android\key.properties'
if (-not (Test-Path -LiteralPath $propertyPath -PathType Leaf)) { throw 'Persistent Android release signing is not configured.' }
$properties = @{}
foreach ($line in Get-Content -LiteralPath $propertyPath) {
    if ($line -match '^([^#!][^=]*)=(.*)$') { $properties[$Matches[1].Trim()] = $Matches[2].Trim() }
}
if (-not $properties.storeFile -or -not $properties.storePassword -or -not $properties.keyAlias) {
    throw 'Android release signing properties are incomplete.'
}
$keystore = [IO.Path]::GetFullPath($properties.storeFile)
if (-not (Test-Path -LiteralPath $keystore -PathType Leaf)) { throw 'Persistent Android keystore is missing.' }
$keytool = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr\bin\keytool.exe'
if (-not (Test-Path -LiteralPath $keytool)) { throw 'Android Studio keytool was not found.' }
$certificateFile = [IO.Path]::GetTempFileName()
$env:WINDFULL_VERIFY_STORE_PASSWORD = $properties.storePassword
try {
    & $keytool -exportcert -keystore $keystore -alias $properties.keyAlias `
        -storepass:env WINDFULL_VERIFY_STORE_PASSWORD -file $certificateFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not verify the persistent Android signing certificate.' }
    $keystoreSigner = (Get-FileHash -LiteralPath $certificateFile -Algorithm SHA256).Hash.ToLowerInvariant()
}
finally {
    Remove-Item Env:WINDFULL_VERIFY_STORE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $certificateFile -Force -ErrorAction SilentlyContinue
}
if ($signer -cne $keystoreSigner) { throw 'APK was not signed with the configured persistent release key.' }

$feed = Get-Content -Raw -LiteralPath $feedPath | ConvertFrom-Json
$fullAssets = @($feed.Assets | Where-Object { $_.Type -eq 'Full' })
if ($fullAssets.Count -ne 1) { throw 'Windows feed must contain exactly one full package.' }
$asset = $fullAssets[0]
if ($asset.PackageId -cne $packageId -or $asset.Version -cne $serverVersion -or
    $asset.FileName -cne (Split-Path -Leaf $fullPackage) -or
    [long]$asset.Size -ne (Get-Item -LiteralPath $fullPackage).Length -or
    $asset.SHA256 -cne (Get-FileHash -LiteralPath $fullPackage -Algorithm SHA256).Hash -or
    $asset.SHA1 -cne (Get-FileHash -LiteralPath $fullPackage -Algorithm SHA1).Hash) {
    throw 'Windows update feed does not match the full package.'
}

$portableZip = [IO.Compression.ZipFile]::OpenRead($portable)
$packageZip = [IO.Compression.ZipFile]::OpenRead($fullPackage)
try {
    $manifest = [xml](Get-ZipEntryText $portableZip 'current/sq.version')
    $packageManifest = [xml](Get-ZipEntryText $packageZip "$packageId.nuspec")
    foreach ($metadata in @($manifest.package.metadata, $packageManifest.package.metadata)) {
        if ($metadata.id -cne $packageId -or $metadata.version -cne $serverVersion -or $metadata.channel -cne 'win-x64') {
            throw 'Portable/full package metadata does not match this release.'
        }
    }
    foreach ($entry in @('Update.exe', 'current/windfull_server.exe', 'current/windfull-samsung-ocf.exe', 'current/LICENSE.velopack')) {
        if (-not $portableZip.GetEntry($entry)) { throw "Managed Windows package is missing: $entry" }
    }
    if (-not $packageZip.GetEntry('lib/app/LICENSE.velopack')) { throw 'Full Windows update package is missing the Velopack MIT license notice.' }
    $launcher = @($portableZip.Entries | Where-Object { $_.FullName -match '^[^/\\]+\.exe$' -and $_.Name -ne 'Update.exe' })
    if ($launcher.Count -ne 1) { throw 'Managed portable ZIP must contain exactly one root application launcher.' }
    $temporaryExe = [IO.Path]::GetTempFileName()
    try {
        Export-ZipEntry $portableZip 'current/windfull_server.exe' $temporaryExe
        $binaryVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($temporaryExe)
        $hostParts = $serverVersion.Split('.') | ForEach-Object { [int]$_ }
        if ($binaryVersion.FileMajorPart -ne $hostParts[0] -or
            $binaryVersion.FileMinorPart -ne $hostParts[1] -or
            $binaryVersion.FileBuildPart -ne $hostParts[2]) {
            throw 'Tauri Windows executable version does not match server/src-tauri/Cargo.toml.'
        }
        if ((Get-WindowsSubsystem $temporaryExe) -ne 2) {
            throw 'Tauri host must use the Windows GUI subsystem so launching it does not open a console window.'
        }
    }
    finally { Remove-Item -LiteralPath $temporaryExe -Force }

    $temporarySidecar = [IO.Path]::GetTempFileName()
    try {
        Export-ZipEntry $portableZip 'current/windfull-samsung-ocf.exe' $temporarySidecar
        if ((Get-WindowsSubsystem $temporarySidecar) -ne 2) {
            throw 'Samsung OCF sidecar must use the Windows GUI subsystem so it does not open a console window.'
        }
    }
    finally { Remove-Item -LiteralPath $temporarySidecar -Force }

    $temporaryLauncher = [IO.Path]::GetTempFileName()
    try {
        Export-ZipEntry $portableZip $launcher[0].FullName $temporaryLauncher
        if ((Get-WindowsSubsystem $temporaryLauncher) -ne 2) {
            throw 'WindFull launcher must use the Windows GUI subsystem so it does not open a console window.'
        }
    }
    finally { Remove-Item -LiteralPath $temporaryLauncher -Force }
}
finally {
    $portableZip.Dispose()
    $packageZip.Dispose()
}

$releaseDirectory = Join-Path $root 'output\release'
New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
$releaseFiles = @($apk, $catalog, $portable, $fullPackage, $feedPath)
$releaseChecksums = foreach ($file in $releaseFiles) {
    "$((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)  $(Split-Path -Leaf $file)"
}
Set-Content -LiteralPath (Join-Path $releaseDirectory 'SHA256SUMS.txt') -Value $releaseChecksums -Encoding ascii
Write-Output "Verified v$serverVersion (Android build $($appVersion.Build)); Android signer SHA-256: $signer"
Write-Output "Release manifest: $(Join-Path $releaseDirectory 'SHA256SUMS.txt')"
