# Mini Island for Windows - installer
# Copies the app to %LOCALAPPDATA%\MiniIsland, adds it to Startup (runs automatically at login)
# and starts it. Nothing outside your user profile is changed and no admin rights are needed.
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'MiniIsland'),
    [string]$StartupFolder = [Environment]::GetFolderPath('Startup'),
    [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
# Earlier versions were called "Dynamic Island" and installed here
$oldTarget = Join-Path (Split-Path -Parent $Target) 'DynamicIsland'

# Stops a running copy (launcher first, it would restart the island) so its files can be replaced
function Stop-Island($dir) {
    $appFiles = @((Join-Path $dir 'island.ps1'), (Join-Path $dir 'Start Island.vbs'))
    Get-CimInstance Win32_Process -Filter "Name='wscript.exe' OR Name='powershell.exe'" |
        Where-Object { $cl = $_.CommandLine; $cl -and $_.ProcessId -ne $PID -and @($appFiles | Where-Object { $cl.Contains($_) }).Count } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Write-Host "Installing Mini Island to $Target"
Stop-Island $Target
New-Item -ItemType Directory -Force -Path $Target | Out-Null

# Moving from the old "Dynamic Island" install: keep settings and saved lyrics, remove the old copy
$oldLnk = Join-Path $StartupFolder 'Dynamic Island.lnk'
if (Test-Path $oldTarget) {
    Write-Host "Moving settings from $oldTarget"
    Stop-Island $oldTarget
    Start-Sleep -Milliseconds 500
    foreach ($item in 'settings.json', 'lyrics') {
        $from = Join-Path $oldTarget $item
        if ((Test-Path $from) -and -not (Test-Path (Join-Path $Target $item))) { Copy-Item $from $Target -Recurse -Force }
    }
    Remove-Item $oldTarget -Recurse -Force -ErrorAction SilentlyContinue
}
if (Test-Path $oldLnk) { Remove-Item $oldLnk -Force }

foreach ($f in 'island.ps1', 'Start Island.vbs', 'uninstall.ps1', 'Uninstall.cmd') {
    Copy-Item -Path (Join-Path $src $f) -Destination (Join-Path $Target $f) -Force
}
# Files downloaded from the internet are marked as blocked by Windows; unblock our own files
Get-ChildItem $Target -File | Unblock-File -ErrorAction SilentlyContinue

# Startup shortcut: runs the launcher at every login
$lnk = Join-Path $StartupFolder 'Mini Island.lnk'
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
$s.Arguments = '"' + (Join-Path $Target 'Start Island.vbs') + '"'
$s.WorkingDirectory = $Target
$s.Description = 'Mini Island for Windows'
$s.Save()
Write-Host "Added to Startup: $lnk"

if (-not $NoLaunch) {
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $Target 'Start Island.vbs') + '"')
    Write-Host 'Mini Island is starting. If Windows asks for notification access, allow it.'
}
Write-Host 'Done.'
