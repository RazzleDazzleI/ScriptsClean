<# Enable-WU-PSWU.ps1
   For Splashtop 1-to-Many (Run as SYSTEM)
   - Unblocks Windows Update (clears WSUS/local blocks)
   - Ensures PSWindowsUpdate (TLS/NuGet/PSGallery)
   - Installs updates, skipping drivers
   - Fallback to native USO if module path fails
   - Logs to C:\Logs and returns 0 / 3010 / 1
#>

param(
  [switch]$AutoReboot = $true,             # set to $false to stage only
  [string]$LogDir     = 'C:\Logs'
)

Start-Transcript -Path ("$LogDir\WU_{0:yyyyMMdd_HHmm}.log" -f (Get-Date)) -ErrorAction SilentlyContinue | Out-Null
$ErrorActionPreference = 'Stop'
$exit = 0

function Allow-WU {
  $wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  New-Item $LogDir -ItemType Directory -Force | Out-Null
  New-Item $wuKey -Force | Out-Null

  # Clear WSUS + blocks
  Remove-Item "$wuKey\AU" -Recurse -Force -ErrorAction SilentlyContinue
  foreach($n in 'WUServer','WUStatusServer','DisableWindowsUpdateAccess','DoNotConnectToWindowsUpdateInternetLocations'){
    Remove-ItemProperty -Path $wuKey -Name $n -Force -ErrorAction SilentlyContinue
  }

  # Enforce "no drivers via WU" policy (works even if we fall back to USO)
  New-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -Type DWord -Value 1 -Force | Out-Null

  # Services + cache reset
  Set-Service wuauserv -StartupType Manual
  Set-Service bits     -StartupType Manual
  Set-Service cryptsvc -StartupType Automatic
  Stop-Service wuauserv,bits -Force -ErrorAction SilentlyContinue
  Rename-Item "$env:SystemRoot\SoftwareDistribution" 'SoftwareDistribution.old' -ErrorAction SilentlyContinue
  Start-Service wuauserv,bits,cryptsvc
}

function Reboot-Needed {
  $rk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
  return (Test-Path $rk)
}

try {
  Allow-WU

  # Try the PSWindowsUpdate path (preferred)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $nuget = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Where-Object Name -eq 'NuGet'
  if (-not $nuget) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force }
  if (-not (Get-PSRepository -ErrorAction SilentlyContinue)) { Register-PSRepository -Default }
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

  if (-not (Get-Module PSWindowsUpdate -ListAvailable)) {
    Install-Module PSWindowsUpdate -Scope CurrentUser -Force
  }
  Import-Module PSWindowsUpdate -ErrorAction Stop

  # Preview (goes to log) + Install (skip drivers), optional auto reboot
  Get-WindowsUpdate -MicrosoftUpdate -IgnoreUserInput -Verbose *>&1 | Tee-Object -FilePath "$LogDir\preview.log"
  $params = @{
    AcceptAll       = $true
    MicrosoftUpdate = $true
    NotCategory     = @('Drivers')
    Verbose         = $true
  }
  if ($AutoReboot) { $params['AutoReboot'] = $true }
  Install-WindowsUpdate @params *>&1 | Tee-Object -FilePath "$LogDir\install.log" -Append

  if ($AutoReboot -or (Reboot-Needed)) { $exit = 3010 }
}
catch {
  Write-Host "PSWindowsUpdate path failed: $($_.Exception.Message)"
  Write-Host "Falling back to native USO client (drivers are already excluded by policy)…"
  try {
    & UsoClient StartScan
    Start-Sleep -Seconds 25
    & UsoClient StartDownload
    Start-Sleep -Seconds 10
    & UsoClient StartInstall
    if ($AutoReboot) { & UsoClient RestartDevice }
    if ($AutoReboot -or (Reboot-Needed)) { $exit = 3010 }
  } catch {
    Write-Host "Native path failed: $($_.Exception.Message)"
    $exit = 1
  }
}
finally {
  Stop-Transcript | Out-Null
  exit $exit
}
