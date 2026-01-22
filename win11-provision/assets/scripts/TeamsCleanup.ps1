[CmdletBinding()]
param([string]$LogDir = "C:\ProgramData\DRM\Provision\Logs", [switch]$DryRun)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("TeamsCleanup_{0}.log" -f (Get-Date -Format yyyyMMdd_HHmmss))
function Write-Log([string]$m){ "{0} - {1}" -f (Get-Date), $m | Tee-Object -FilePath $Log }

Write-Log "Start Teams cleanup (DryRun=$DryRun)"

# 1) Remove Teams Machine-Wide Installer (MSI)
$uninstRoots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$mw = Get-ItemProperty $uninstRoots -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' }
foreach($app in $mw){
  $cmd = $app.UninstallString
  if($cmd -match 'MsiExec\.exe.*?/I\{([0-9A-F\-]+)\}'){$guid=$matches[1]; $cmd = "msiexec.exe /X{$guid} /qn /norestart"}
  elseif($cmd -match 'MsiExec\.exe.*?/X\{([0-9A-F\-]+)\}'){$guid=$matches[1]; $cmd = "msiexec.exe /X{$guid} /qn /norestart"}
  else { $cmd = "$cmd /qn /norestart" }
  Write-Log "Removing Teams Machine-Wide Installer: $cmd"
  if(-not $DryRun){ Start-Process cmd.exe "/c $cmd" -Wait -WindowStyle Hidden }
}

# 2) Per-user Classic Teams uninstall & folder cleanup
$userProfiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' }
foreach($u in $userProfiles){
  $upd = Join-Path $u.LocalPath 'AppData\Local\Microsoft\Teams\Update.exe'
  if(Test-Path $upd){
    Write-Log "Uninstall Classic Teams for $($u.LocalPath)"
    if(-not $DryRun){ Start-Process $upd -ArgumentList '--uninstall -s' -Wait -WindowStyle Hidden }
  }
  $dirs = @(
    'AppData\Local\Microsoft\Teams',
    'AppData\Roaming\Microsoft\Teams'
  ) | ForEach-Object { Join-Path $u.LocalPath $_ }
  foreach($d in $dirs){
    if(Test-Path $d){ Write-Log "Removing $d"; if(-not $DryRun){ Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue } }
  }
}

# 3) Remove the legacy installer cache
$cache = 'C:\Program Files (x86)\Teams Installer'
if(Test-Path $cache){ Write-Log "Removing $cache"; if(-not $DryRun){ Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue } }

Write-Log "Teams cleanup complete."
exit 0
