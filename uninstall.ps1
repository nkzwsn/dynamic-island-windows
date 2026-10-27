# Mini Island for Windows - uninstaller
# Stops the island, removes the Startup shortcut and deletes the install folder.
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'MiniIsland'),
    [string]$StartupFolder = [Environment]::GetFolderPath('Startup')
)
# Also cleans up an install from when the app was called "Dynamic Island"
$targets = @($Target, (Join-Path (Split-Path -Parent $Target) 'DynamicIsland'))
# The launcher (wscript) restarts the island if it crashes; stop it first, then the island itself
$appFiles = foreach ($t in $targets) { (Join-Path $t 'Start Island.vbs'); (Join-Path $t 'island.ps1') }
foreach ($name in 'wscript.exe', 'powershell.exe') {
    Get-CimInstance Win32_Process -Filter "Name='$name'" |
        Where-Object { $cl = $_.CommandLine; $cl -and $_.ProcessId -ne $PID -and @($appFiles | Where-Object { $cl.Contains($_) }).Count } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

foreach ($n in 'Mini Island.lnk', 'Dynamic Island.lnk') {
    $lnk = Join-Path $StartupFolder $n
    if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "Removed $lnk" }
}
Start-Sleep -Milliseconds 500
foreach ($t in $targets) {
    if (Test-Path $t) {
        Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed $t"
    }
}
Write-Host 'Mini Island has been uninstalled.'
