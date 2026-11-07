# ReTake uninstaller: puts your ReSkate.dll back, removes Mods\ReTake, and turns the launcher's updates back on
# if the installer turned them off. Run it through "Uninstall ReTake.bat".
param(
    [string]$GameDir = "",
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say($text, $colour = "Gray") { Write-Host $text -ForegroundColor $colour }
function Fail($text) {
    Say $text "Red"
    Done 1
}
function Done($code) {
    if ($Elevated) { Read-Host "Press Enter to close" }
    exit $code
}

function Is-Installed($dir) {
    return $dir -and (Test-Path (Join-Path $dir "Skate.exe")) -and ((Test-Path (Join-Path $dir "Mods\ReTake")) -or (Test-Path (Join-Path $dir "ReTake-backup")))
}

# The same search as the installer, kept short: Steam libraries, then the usual folders.
function Find-GameDirs {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam")) {
        try {
            $item = Get-ItemProperty $key -ErrorAction Stop
            foreach ($p in @($item.SteamPath, $item.InstallPath)) {
                if (-not $p) { continue }
                $steam = $p -replace "/", "\"
                $roots.Add((Join-Path $steam "steamapps\common"))
                $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
                if (Test-Path $vdf) {
                    foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                        $roots.Add((Join-Path ($m.Groups[1].Value -replace "\\\\", "\") "steamapps\common"))
                    }
                }
            }
        } catch { }
    }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match "^[A-Z]:\\$" })) {
        foreach ($sub in @("Program Files\EA Games", "Program Files (x86)\Steam\steamapps\common", "SteamLibrary\steamapps\common", "Games", "EA Games")) {
            $roots.Add((Join-Path $drive.Root $sub))
        }
    }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path $root)) { continue }
        if (Is-Installed $root) { $found.Add((Resolve-Path $root).Path) }
        foreach ($child in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
            if (Is-Installed $child.FullName) { $found.Add($child.FullName) }
        }
    }
    return @($found | Select-Object -Unique)
}

Say ""
Say "  ReTake uninstaller" "Yellow"
Say ""

if (-not $GameDir) {
    $dirs = Find-GameDirs
    if ($dirs.Count -eq 1) {
        $GameDir = $dirs[0]
    } elseif ($dirs.Count -gt 1) {
        for ($i = 0; $i -lt $dirs.Count; $i++) { Say "  [$($i + 1)] $($dirs[$i])" }
        $GameDir = $dirs[[int](Read-Host "Which one? (1-$($dirs.Count))") - 1]
    } else {
        $GameDir = (Read-Host "Paste the path of your skate. folder").Trim('" ')
    }
}
$GameDir = $GameDir.Trim('" ')
if (-not (Is-Installed $GameDir)) {
    Say "ReTake isn't installed in $GameDir." "Yellow"
    Done 1
}
Say "Removing ReTake from: $GameDir"

try {
    [IO.File]::WriteAllText((Join-Path $GameDir ".retake_write_test"), "x")
    Remove-Item (Join-Path $GameDir ".retake_write_test") -Force
} catch {
    Say "That folder needs admin rights to change. Asking Windows for them..."
    Start-Process powershell -Verb RunAs -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($MyInvocation.MyCommand.Path)`"", "-GameDir", "`"$GameDir`"", "-Elevated")
    exit 0
}

# Only copies running from this folder matter.
function Running-Here {
    $full = [IO.Path]::GetFullPath($GameDir).TrimEnd("\")
    return @(Get-Process -Name "Skate", "ReSkateLauncher" -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and ([IO.Path]::GetDirectoryName($_.Path).TrimEnd("\") -ieq $full)
    })
}
$waited = 0
while ((Running-Here).Count -gt 0) {
    if ($waited -ge 3) { Fail "skate. or the ReSkate launcher is still running. Close them both, then run this again." }
    Say "skate. or the ReSkate launcher is still running. Close them both." "Yellow"
    Read-Host "Then press Enter"
    Start-Sleep -Seconds 1
    $waited++
}

$backup = Join-Path $GameDir "ReTake-backup"
$state = $null
try { $state = Get-Content (Join-Path $backup "install.json") -Raw | ConvertFrom-Json } catch { }

# The mod.
$mod = Join-Path $GameDir "Mods\ReTake"
if (Test-Path $mod) {
    Remove-Item $mod -Recurse -Force
    Say "Removed Mods\ReTake" "Green"
}

# ReSkate.dll: the one you had before, if the installer kept it.
$kept = Join-Path $backup "ReSkate.dll"
if (Test-Path $kept) {
    Copy-Item $kept (Join-Path $GameDir "ReSkate.dll") -Force
    Remove-Item $kept -Force
    Say "Put your old ReSkate.dll back" "Green"
} else {
    Say "No backed-up ReSkate.dll. With updates on, the launcher fetches the official one when it starts." "Yellow"
}

# Launcher updates: back to how they were, or on if we don't know.
$settings = Join-Path $GameDir "ReSkateLauncher.settings.json"
if (Test-Path $settings) {
    $previous = if ($state -and $state.previous_updates) { $state.previous_updates } else { "true" }
    $text = [IO.File]::ReadAllText($settings)
    $m = [regex]::Match($text, '"updates"\s*:\s*(true|false)')
    if ($m.Success -and $previous -ne "false" -and $m.Groups[1].Value -eq "false") {
        $text = $text.Substring(0, $m.Index) + '"updates": true' + $text.Substring($m.Index + $m.Length)
        [IO.File]::WriteAllText($settings, $text, (New-Object Text.UTF8Encoding($false)))
        Say "Turned the launcher's automatic updates back on" "Green"
    }
}

Remove-Item (Join-Path $backup "install.json") -Force -ErrorAction SilentlyContinue
if ((Test-Path $backup) -and -not (Get-ChildItem $backup -Force)) { Remove-Item $backup -Force }
elseif (Test-Path $backup) { Say "Left ReTake-backup in place: it still holds an old tas_probe folder you may want." "DarkGray" }

Say ""
Say "ReTake is uninstalled. Your lines' logs stay in Mods\.reskate_plugin_data\ReTake if you want them; delete that folder if not." "Yellow"
Say ""
Done 0
