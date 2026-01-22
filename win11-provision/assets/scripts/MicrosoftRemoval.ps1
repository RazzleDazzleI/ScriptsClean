[CmdletBinding()]
param(
  [switch]$InstallOffice365,
  [switch]$UseSetupRemoval = $true,   # prefer ODT/Setup.exe removal
  [switch]$SuppressReboot,
  [switch]$DryRun,
  [string]$ODTPath      = $null,      # if omitted, resolved relative to this file
  [string]$UninstallXml = $null,      # if omitted, resolved relative to this file
  [string]$InstallXml   = $null,      # if omitted, resolved relative to this file
  [string]$LogDir       = "C:\ProgramData\DRM\Provision\Logs",
  [int]$RebootDelaySec  = 15
)

# --- resolve defaults relative to this script (…\assets\scripts\ -> …\assets\office\) ---
$ScriptDir   = Split-Path -Parent $PSCommandPath
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)         # up twice
$OfficeDir   = Join-Path $ProjectRoot "assets\office"
if (-not $ODTPath)      { $ODTPath      = Join-Path $OfficeDir "setup.exe" }
if (-not $UninstallXml) { $UninstallXml = Join-Path $OfficeDir "uninstall.xml" }
if (-not $InstallXml)   { $InstallXml   = Join-Path $OfficeDir "install.xml" }

# --- logging ---
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("MicrosoftRemoval_{0}.log" -f (Get-Date -Format yyyyMMdd_HHmmss))
function Write-Log([string]$m){ "{0} - {1}" -f (Get-Date), $m | Tee-Object -FilePath $Log }
Write-Log ("Start (elevated={0}; DryRun={1})" -f ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator), $DryRun)

# --- helpers ---
function Invoke-Cmd([string]$exe, [string]$args){
  Write-Log "RUN: `"$exe`" $args"
  if($DryRun){ return }
  $p = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
  if($p.ExitCode -ne 0){ Write-Log "WARN exit code: $($p.ExitCode)" }
}

function Stop-OfficeProcesses {
  $procs = "winword","excel","powerpnt","outlook","msaccess","mspub","onenote","visio","winproj","teams","lync","groove","graph"
  foreach($n in $procs){
    $running = Get-Process -Name $n -ErrorAction SilentlyContinue
    if($running){
      Write-Log "Stopping: $n"
      if(-not $DryRun){ Stop-Process -Id $running.Id -Force -ErrorAction SilentlyContinue }
    }
  }
}

function Remove-Office-WithSetup {
  if(-not (Test-Path $ODTPath))      { Write-Log "ERROR: ODT not found at $ODTPath"; return $false }
  if(-not (Test-Path $UninstallXml)) { Write-Log "ERROR: Uninstall XML not found at $UninstallXml"; return $false }
  Invoke-Cmd $ODTPath "/configure `"$UninstallXml`""
  return $true
}

function Install-Office365 {
  if(-not (Test-Path $ODTPath))    { Write-Log "ERROR: ODT not found at $ODTPath"; return $false }
  if(-not (Test-Path $InstallXml)) { Write-Log "ERROR: Install XML not found at $InstallXml"; return $false }
  Invoke-Cmd $ODTPath "/configure `"$InstallXml`""
  return $true
}

function Maybe-Reboot {
  if($SuppressReboot){ Write-Log "Reboot suppressed."; return }
  if($DryRun){ Write-Log "DryRun: would reboot in $RebootDelaySec seconds."; return }
  Write-Log "Rebooting in $RebootDelaySec seconds…"
  shutdown.exe /r /t $RebootDelaySec /c "MicrosoftRemoval.ps1"
}

# --- run sequence ---
Stop-OfficeProcesses

$removed = $false
if($UseSetupRemoval){ $removed = Remove-Office-WithSetup }
else { Write-Log "Setup removal preferred; SaRA mode not implemented in this minimal version." }

if(-not $removed){ Write-Log "WARN: Office removal step may not have run." }

if($InstallOffice365){
  Write-Log "Installing Microsoft 365 (per $InstallXml)…"
  [void](Install-Office365)
}

Write-Log "Done."
Maybe-Reboot
exit 0
