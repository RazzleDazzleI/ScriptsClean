[CmdletBinding()]
param(
  # Local admin creation
  [string]$AdminUser = "drmadministrator",
  [string]$AdminPassword,                 # if omitted, uses $env:DRM_ADMIN_PWD; if still blank, user creation is skipped

  # Optional online installs (Teams is always installed)
  [switch]$InstallChrome,
  [switch]$InstallReader,
  [switch]$Install7Zip,
  [switch]$InstallNotepadPP,

  # System tweaks
  [string]$TimeZone,                      # e.g. "Central Standard Time"

  # Behavior
  [switch]$DryRun
)

# -------------------- helpers & logging --------------------
$ErrorActionPreference = "Stop"
$LogDir = "C:\ProgramData\DRM\Provision\Logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("AllInOne_{0}.log" -f (Get-Date -Format yyyyMMdd_HHmmss))
function Write-Log([string]$m){ "{0} - {1}" -f (Get-Date), $m | Tee-Object -FilePath $Log }

function Ensure-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
              IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if(-not $isAdmin){
    Write-Log "Not elevated; re-launching elevated..."
    $args = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"") + $MyInvocation.BoundParameters.GetEnumerator() | ForEach-Object {
      "-$($_.Key) `"$($_.Value)`""
    }
    Start-Process -Verb RunAs powershell.exe -ArgumentList ($args -join ' ')
    exit
  }
}
Ensure-Admin
Write-Log ("Start  (DryRun={0})" -f $DryRun)

function Invoke-IfNotDry([scriptblock]$do, [string]$about){
  if($DryRun){ Write-Log "DRYRUN: $about"; return $null }
  try { & $do } catch { Write-Log "ERROR: $about -> $($_.Exception.Message)"; throw }
}

# -------------------- WinGet helpers --------------------
function Winget-Ready {
  try { winget --version | Out-Null; return $true } catch { return $false }
}
function Winget-Install([string]$Id){
  Write-Log "winget install: $Id"
  if($DryRun){ Write-Log "DRYRUN: winget install -e --id `"$Id`""; return }
  # warm sources once
  try { winget source update | Out-Null } catch {}
  $p = Start-Process winget.exe -ArgumentList @("install","-e","--id",$Id,"--silent","--accept-source-agreements","--accept-package-agreements") `
                               -Wait -PassThru -WindowStyle Hidden
  if($p.ExitCode -ne 0){ Write-Log "WARN: winget exit code $($p.ExitCode) for $Id" }
}

# -------------------- Teams cleanup (legacy/Classic) --------------------
function Cleanup-TeamsClassic {
  Write-Log "Teams cleanup: start"
  # Remove machine-wide MSI
  $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
  $mw = Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' }
  foreach($app in $mw){
    $cmd = $app.UninstallString
    if($cmd -match 'MsiExec\.exe.*?/I\{([0-9A-F\-]+)\}') { $guid=$matches[1]; $cmd="msiexec.exe /X{$guid} /qn /norestart" }
    elseif($cmd -match 'MsiExec\.exe.*?/X\{([0-9A-F\-]+)\}') { $guid=$matches[1]; $cmd="msiexec.exe /X{$guid} /qn /norestart" }
    else { $cmd = "$cmd /qn /norestart" }
    Invoke-IfNotDry { Start-Process cmd.exe "/c $cmd" -Wait -WindowStyle Hidden } "Remove Teams Machine-Wide Installer"
  }
  # Per-user uninstall & cache
  $profiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' }
  foreach($u in $profiles){
    $upd = Join-Path $u.LocalPath 'AppData\Local\Microsoft\Teams\Update.exe'
    if(Test-Path $upd){
      Invoke-IfNotDry { Start-Process $upd -ArgumentList '--uninstall -s' -Wait -WindowStyle Hidden } "Uninstall Classic Teams for $($u.LocalPath)"
    }
    foreach($d in @('AppData\Local\Microsoft\Teams','AppData\Roaming\Microsoft\Teams')){
      $path = Join-Path $u.LocalPath $d
      if(Test-Path $path){ Invoke-IfNotDry { Remove-Item -Recurse -Force $path } "Remove $path" }
    }
  }
  $cache = 'C:\Program Files (x86)\Teams Installer'
  if(Test-Path $cache){ Invoke-IfNotDry { Remove-Item -Recurse -Force $cache } "Remove $cache" }
  Write-Log "Teams cleanup: done"
}

# -------------------- Bloat removal (keeps Snipping Tool) --------------------
function Remove-Bloat {
  Write-Log "Bloat removal: start"
  $appsToRemove = @(
    'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes','Microsoft.People',
    # 'Microsoft.ScreenSketch',   # Snipping Tool (DO NOT remove)
    'Microsoft.WindowsAlarms','Microsoft.WindowsMaps',
    'Microsoft.XboxGamingOverlay','Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.Windows.Photos',
    'Microsoft.WindowsSoundRecorder','Microsoft.Whiteboard','Microsoft.MicrosoftJournal',
    'Microsoft.Windows.DevHome','Microsoft.OutlookForWindows',
    'Microsoft.OneNote','Microsoft.Office.OneNote','Microsoft.Office.Desktop.LanguagePack'
  )
  $nonRemovable = @('Microsoft.XboxGameCallableUI')

  $userSids = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' } | Select-Object -ExpandProperty SID

  foreach($app in $appsToRemove){
    if($nonRemovable -contains $app){ Write-Log "Skip non-removable: $app"; continue }
    # remove provisioned
    try{
      $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "$app*" }
      if($prov){
        foreach($pp in $prov){
          Write-Log "Removing provisioned: $($pp.DisplayName)"
          Invoke-IfNotDry { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName | Out-Null } "Remove provisioned $($pp.DisplayName)"
        }
      }
    } catch { Write-Log "WARN Get-AppxProvisionedPackage for ${app}: $($_.Exception.Message)" }

    # remove per SID
    try{
      $pkgs = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
      foreach($p in $pkgs){
        Write-Log "Found installed: $($p.PackageFullName)"
        foreach($sid in $userSids){
          Invoke-IfNotDry { Remove-AppxPackage -Package $p.PackageFullName -User $sid -ErrorAction Continue } "Remove $app for SID $sid"
        }
      }
    } catch { Write-Log "WARN Get-AppxPackage for ${app}: $($_.Exception.Message)" }
  }
  Write-Log "Bloat removal: done"
}

# -------------------- Windows features & policies --------------------
function Enable-NetFx3 {
  Write-Log "Enable NetFx3"
  Invoke-IfNotDry { DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart | Out-Null } "DISM enable NetFx3"
}
function Apply-Policies {
  Write-Log "Applying policies to reduce consumer content"
  $items = @(
    @{ hive='HKLM'; path='SOFTWARE\Policies\Microsoft\Windows\CloudContent'; name='DisableWindowsConsumerFeatures'; type='DWord'; value=1 },
    @{ hive='HKLM'; path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; name='SilentInstalledAppsEnabled'; type='DWord'; value=0 },
    @{ hive='HKLM'; path='SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; name='ContentDeliveryAllowed'; type='DWord'; value=0 },
    @{ hive='HKLM'; path='SOFTWARE\Policies\Microsoft\WindowsStore'; name='AutoDownload'; type='DWord'; value=2 }
  )
  foreach($i in $items){
    $root = if($i.hive -eq 'HKLM'){ 'HKLM:' } else { 'HKCU:' }
    Invoke-IfNotDry { New-Item -Path (Join-Path $root $i.path) -Force | Out-Null } "Create $(($i.hive)+':' + $i.path)"
    Invoke-IfNotDry { New-ItemProperty -Path (Join-Path $root $i.path) -Name $i.name -PropertyType $i.type -Value $i.value -Force | Out-Null } "Set $($i.name)"
  }
}

# -------------------- Local admin --------------------
function Ensure-LocalAdmin([string]$User,[string]$Password){
  if(-not $Password){ $Password = $env:DRM_ADMIN_PWD }
  if(-not $Password){ Write-Log "No admin password provided; skipping user creation."; return }
  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  $exists = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
  if($exists){
    Write-Log "Updating password for $User"
    Invoke-IfNotDry { Set-LocalUser -Name $User -Password $sec } "Set password for $User"
  } else {
    Write-Log "Creating $User"
    Invoke-IfNotDry { New-LocalUser -Name $User -Password $sec -NoPasswordExpiration -UserMayNotChangePassword:$true } "Create $User"
  }
  Invoke-IfNotDry { Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue } "Add $User to Administrators"
}

# -------------------- MAIN --------------------
try{
  if($TimeZone){ Invoke-IfNotDry { Set-TimeZone -Name $TimeZone } "Set timezone $TimeZone" }

  Cleanup-TeamsClassic
  Remove-Bloat
  Enable-NetFx3
  Apply-Policies

  # install Teams (work/school) + optional tools
  Winget-Install "Microsoft.Teams"
  if($InstallChrome){    Winget-Install "Google.Chrome" }
  if($InstallReader){    Winget-Install "Adobe.Acrobat.Reader.64-bit" }
  if($Install7Zip){      Winget-Install "7zip.7zip" }
  if($InstallNotepadPP){ Winget-Install "Notepad++.Notepad++" }

  Ensure-LocalAdmin -User $AdminUser -Password $AdminPassword

  Write-Log "All done."
} catch {
  Write-Log "FATAL: $($_.Exception.Message)"
  throw
}

