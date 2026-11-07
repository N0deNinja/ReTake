# Builds dist\ReTake-v<version>.zip: the installer, the mod, and ReTake's ReSkate.dll.
#   powershell -ExecutionPolicy Bypass -File tools\make-release.ps1 [-Dll path\to\ReSkate.dll]
# Build the DLL first (see README, "Building"): it defaults to native\build\vs2022-x64\Release\ReSkate.dll.
param([string]$Dll = "")

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Version = (Get-Content (Join-Path $Root "mod\ReTake\manifest.json") -Raw | ConvertFrom-Json).version_number
if (-not $Dll) { $Dll = Join-Path $Root "native\build\vs2022-x64\Release\ReSkate.dll" }
if (-not (Test-Path $Dll)) { throw "No ReSkate.dll at $Dll. Build it first, or pass -Dll." }

$name = "ReTake-v$Version"
$dist = Join-Path $Root "dist"
$out = Join-Path $dist $name
# Empty it rather than delete it: an open installer window keeps the folder itself in use.
if (Test-Path $out) { Get-ChildItem $out -Force | Remove-Item -Recurse -Force }
$files = Join-Path $out "files"
New-Item -ItemType Directory -Force (Join-Path $files "Mods") | Out-Null

Copy-Item (Join-Path $Root "installer\Install ReTake.bat") $out
Copy-Item (Join-Path $Root "installer\Uninstall ReTake.bat") $out
Copy-Item (Join-Path $Root "installer\README.txt") $out
Copy-Item (Join-Path $Root "LICENSE") (Join-Path $out "LICENSE.txt")
Copy-Item (Join-Path $Root "installer\Install-ReTake.ps1") $files
Copy-Item (Join-Path $Root "installer\Uninstall-ReTake.ps1") $files
Copy-Item $Dll (Join-Path $files "ReSkate.dll")
Copy-Item (Join-Path $Root "mod\ReTake") (Join-Path $files "Mods\ReTake") -Recurse

$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
# Not Compress-Archive: on Windows PowerShell it writes backslashes into the zip, which other unzippers get wrong.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in (Get-ChildItem $out -Recurse -File)) {
        $entry = "$name/" + $f.FullName.Substring($out.Length + 1).Replace("\", "/")
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $archive.Dispose() }
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip" | Set-Content (Join-Path $dist "$name.zip.sha256") -Encoding ASCII
Write-Host "Built $zip"
Write-Host "SHA-256 $hash"
