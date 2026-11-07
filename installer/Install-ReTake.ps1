# ReTake installer. Run it through "Install ReTake.bat" (or: powershell -ExecutionPolicy Bypass -File Install-ReTake.ps1).
# It finds your skate. folder with ReSkate in it, backs up ReSkate.dll, puts ReTake's ReSkate.dll and Mods\ReTake in,
# and turns off the launcher's automatic updates (they would put the official ReSkate.dll back).
# Run again over an installed ReTake, it updates it: the same folder, no questions, your backup kept.
param(
    [string]$GameDir = "",
    [switch]$Yes,
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Version = "0.0.2"
# ReSkate.dll of every ReTake release (SHA-256): never backed up as "yours" over the one you had.
$ReTakeDlls = @(
    "9EE223813453BF9EC4730D0603CF436EB8F06ADDC6553F794FAF1A7CCE32F9AB"  # 0.0.1
)
$ReSkateVersion = "2.1.4-2"

function Say($text, $colour = "Gray") { Write-Host $text -ForegroundColor $colour }
function Fail($text) {
    Say ""
    Say $text "Red"
    Say ""
    if ($Elevated) { Read-Host "Press Enter to close" }
    exit 1
}
function Ask($question, $default = $true) {
    if ($Yes) { return $default }
    $hint = if ($default) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$question $hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim().ToLower().StartsWith("y")
}

# The files to install sit next to this script (release zip) or in the repo's build output.
function Find-Payload {
    $candidates = @(
        $Here,
        (Join-Path $Here "files"),
        (Join-Path (Split-Path -Parent $Here) "dist\ReTake-v$Version\files")
    )
    foreach ($c in $candidates) {
        if ((Test-Path (Join-Path $c "ReSkate.dll")) -and (Test-Path (Join-Path $c "Mods\ReTake\manifest.json"))) { return $c }
    }
    Fail "Can't find ReTake's files (files\ReSkate.dll and files\Mods\ReTake). Unzip the whole release first, then run Install ReTake.bat from inside it."
}

# The ReTake version installed in a game folder, or $null.
function Installed-Version($dir) {
    $manifest = Join-Path $dir "Mods\ReTake\manifest.json"
    if (-not (Test-Path $manifest)) { return $null }
    try {
        $v = (Get-Content $manifest -Raw | ConvertFrom-Json).version_number
        if ($v) { return [string]$v }
    } catch { }
    return "an older version"
}

function Is-GameDir($dir) {
    return $dir -and (Test-Path (Join-Path $dir "Skate.exe")) -and (Test-Path (Join-Path $dir "ReSkateLauncher.exe"))
}

# Steam libraries, the EA app's folder, and the usual places people keep games.
function Find-GameDirs {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
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
        $d = $drive.Root
        foreach ($sub in @("Program Files\EA Games", "Program Files (x86)\Steam\steamapps\common", "Program Files\Steam\steamapps\common",
                           "SteamLibrary\steamapps\common", "Steam\steamapps\common", "Games", "EA Games", "Games\EA Games")) {
            $roots.Add((Join-Path $d $sub))
        }
    }
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path $root)) { continue }
        if (Is-GameDir $root) { $found.Add((Resolve-Path $root).Path) }
        foreach ($child in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
            if (Is-GameDir $child.FullName) { $found.Add($child.FullName) }
        }
    }
    return @($found | Select-Object -Unique)
}

function Pick-Folder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Pick your skate. folder: the one with Skate.exe and ReSkateLauncher.exe in it"
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    } catch { }
    return (Read-Host "Paste the path of your skate. folder (the one with Skate.exe and ReSkateLauncher.exe)").Trim('" ')
}

function Can-Write($dir) {
    $probe = Join-Path $dir ".retake_write_test"
    try {
        [IO.File]::WriteAllText($probe, "x")
        Remove-Item $probe -Force
        return $true
    } catch { return $false }
}

Say ""
Say "  ReTake $Version installer" "Yellow"
Say "  Rewind and retake your lines in skate. (ReSkate mod, offline only)" "DarkGray"
Say ""

$payload = Find-Payload

# 1. Where the game is.
if (-not $GameDir) {
    $dirs = @(Find-GameDirs)  # @(): one result must stay a list, or [0] is its first letter
    $withReTake = @($dirs | Where-Object { Installed-Version $_ })
    if ($withReTake.Count -eq 1) {
        $GameDir = $withReTake[0]  # an update: where ReTake already is
    } elseif ($dirs.Count -eq 1) {
        $GameDir = $dirs[0]
        Say "Found skate. with ReSkate in: $GameDir"
        if (-not (Ask "Install ReTake there?")) { $GameDir = Pick-Folder }
    } elseif ($dirs.Count -gt 1) {
        Say "Found more than one skate. folder with ReSkate:"
        for ($i = 0; $i -lt $dirs.Count; $i++) { Say "  [$($i + 1)] $($dirs[$i])" }
        $n = Read-Host "Which one? (1-$($dirs.Count))"
        $GameDir = $dirs[[int]$n - 1]
    } else {
        Say "Couldn't find skate. with ReSkate in it on its own. Pick the folder, please."
        $GameDir = Pick-Folder
    }
}
$GameDir = $GameDir.Trim('" ')
if (-not (Test-Path (Join-Path $GameDir "Skate.exe"))) { Fail "There's no Skate.exe in $GameDir. Pick the folder skate. is installed in." }
if (-not (Test-Path (Join-Path $GameDir "ReSkateLauncher.exe"))) {
    Fail "skate. is in $GameDir, but ReSkate isn't. Install ReSkate first (https://github.com/Dingo-Shenanigans/ReSkate/releases), start the game with it once, then run this again."
}

$installed = Installed-Version $GameDir
if ($installed -eq $Version) {
    Say "ReTake $Version is already installed in $GameDir. Installing it again." "Green"
} elseif ($installed) {
    Say "ReTake $installed is installed in $GameDir. Updating it to $Version." "Green"
}

# Program Files needs admin rights: ask Windows for them and start over.
if (-not (Can-Write $GameDir)) {
    Say "That folder needs admin rights to change. Asking Windows for them..."
    $again = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$($MyInvocation.MyCommand.Path)`"", "-GameDir", "`"$GameDir`"", "-Elevated")
    if ($Yes) { $again += "-Yes" }
    Start-Process powershell -Verb RunAs -ArgumentList $again
    exit 0
}

# 2. The game and the launcher have to be closed, or Windows won't let us replace ReSkate.dll.
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

# 3. ReTake's ReSkate.dll is built from ReSkate $ReSkateVersion and only fits that version.
$launcher = (Get-Item (Join-Path $GameDir "ReSkateLauncher.exe")).VersionInfo.ProductVersion
if ($launcher -and $launcher -ne $ReSkateVersion) {
    Say "Your ReSkate launcher is $launcher, but ReTake $Version is built for ReSkate $ReSkateVersion." "Yellow"
    Say "It may not start, or may crash. Check the ReTake releases page for a version that matches." "Yellow"
    if (-not (Ask "Install anyway?" $false)) { exit 1 }
}

$backup = Join-Path $GameDir "ReTake-backup"
New-Item -ItemType Directory -Force $backup | Out-Null
$state = @{ installed = (Get-Date).ToString("s"); version = $Version }
$stateFile = Join-Path $backup "install.json"
$before = $null
if (Test-Path $stateFile) {
    # Installing again: keep what the first install found, so Uninstall can put it back.
    try {
        $before = Get-Content $stateFile -Raw | ConvertFrom-Json
        if ($before.previous_updates) { $state["previous_updates"] = $before.previous_updates }
        if ($before.installed) { $state["installed"] = $before.installed; $state["updated"] = (Get-Date).ToString("s") }
    } catch { }
}

# 4. ReSkate.dll: keep the one you have, then put ReTake's in.
$dll = Join-Path $GameDir "ReSkate.dll"
$ours = Join-Path $payload "ReSkate.dll"
$oursHash = (Get-FileHash $ours).Hash
$kept = Join-Path $backup "ReSkate.dll"
if (Test-Path $dll) {
    $current = (Get-FileHash $dll).Hash
    # Ours: this release's, an earlier ReTake's, or the one the last install put in.
    $isReTake = ($current -eq $oursHash) -or ($ReTakeDlls -contains $current) -or ($before -and $before.dll_hash -eq $current)
    if (-not $isReTake) {
        if (-not (Test-Path $kept)) {
            Copy-Item $dll $kept
            Say "Backed up your ReSkate.dll to ReTake-backup\ReSkate.dll"
        } elseif ($before -and $before.dll_hash -and (Get-FileHash $kept).Hash -ne $current) {
            # The launcher put a newer official one in since ReTake was installed: that is now the one to go back to.
            Copy-Item $dll $kept -Force
            Say "Backed up your current ReSkate.dll to ReTake-backup\ReSkate.dll"
        }
    }
}
Copy-Item $ours $dll -Force
$state["dll_hash"] = $oursHash
Say "Installed ReTake's ReSkate.dll" "Green"

# 5. The mod itself. An old test version (tas_probe) uses the same keys, so it goes into the backup folder.
$mods = Join-Path $GameDir "Mods"
New-Item -ItemType Directory -Force $mods | Out-Null
$old = Join-Path $mods "tas_probe"
if (Test-Path $old) {
    $to = Join-Path $backup ("tas_probe_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    Move-Item $old $to
    Say "Moved the old tas_probe mod to $to"
}
$mod = Join-Path $mods "ReTake"
if (Test-Path $mod) { Remove-Item $mod -Recurse -Force }
Copy-Item (Join-Path $payload "Mods\ReTake") $mod -Recurse
Say "Installed Mods\ReTake" "Green"

# 6. With updates on, the launcher swaps ReSkate.dll back to the official one on every start.
$settings = Join-Path $GameDir "ReSkateLauncher.settings.json"
if (Test-Path $settings) {
    $text = [IO.File]::ReadAllText($settings)
    $m = [regex]::Match($text, '"updates"\s*:\s*(true|false)')
    if ($m.Success -and $m.Groups[1].Value -eq "false") {
        Say "The launcher's automatic updates are already off."
    } else {
        Say ""
        Say "The ReSkate launcher replaces ReSkate.dll with the official one when it updates, which would remove ReTake." "Yellow"
        if (Ask "Turn the launcher's automatic updates off? (You can turn them back on in the launcher, or with Uninstall ReTake.bat.)") {
            if (-not $state.ContainsKey("previous_updates")) { $state["previous_updates"] = if ($m.Success) { $m.Groups[1].Value } else { "missing" } }
            if ($m.Success) {
                $text = $text.Substring(0, $m.Index) + '"updates": false' + $text.Substring($m.Index + $m.Length)
            } else {
                $text = [regex]::Replace($text, '^\s*\{', "{`r`n  `"updates`": false,", 1)
            }
            [IO.File]::WriteAllText($settings, $text, (New-Object Text.UTF8Encoding($false)))
            Say "Launcher updates are off." "Green"
        } else {
            Say "Left them on. If ReTake disappears after a launcher update, run Install ReTake.bat again." "Yellow"
        }
    }
} else {
    Say "No launcher settings yet. Start the ReSkate launcher once, turn off automatic updates in its settings, and run this again." "Yellow"
}

$state | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8

Say ""
if ($installed -and $installed -ne $Version) {
    Say "ReTake is updated from $installed to $Version." "Yellow"
    Say "  Start skate. with the ReSkate launcher as usual. ReSkate asks you to allow ReTake again, because its files changed: allow it."
} else {
    Say "ReTake $Version is installed." "Yellow"
    Say "  1. Start skate. with the ReSkate launcher as usual, and go offline (single player)."
    Say "  2. ReSkate asks you to allow ReTake's permissions the first time: allow them."
    Say "  3. Press F11 and pick New line. Then skate, mess up, go back, and retake."
}
Say ""
Say "Uninstall ReTake.bat puts everything back." "DarkGray"
Say ""
if ($Elevated) { Read-Host "Press Enter to close" }
