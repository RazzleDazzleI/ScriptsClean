[CmdletBinding()]
param([string]$LogDir = "C:\ProgramData\DRM\Provision\Logs")

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir ("AppRemoval_{0}.log" -f (Get-Date -Format yyyyMMdd_HHmmss))
"{0} - Starting app removal (elevated={1})" -f (Get-Date), ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) | Tee-Object -FilePath $Log

# TARGET APPS
$appsToRemove = @(
  'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.Getstarted',
  'Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection',
  'Microsoft.MicrosoftStickyNotes','Microsoft.People','Microsoft.ScreenSketch',
  'Microsoft.WindowsAlarms','Microsoft.WindowsMaps','Microsoft.XboxGamingOverlay',
  'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay',
  'Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.Windows.Photos',
  'Microsoft.WindowsSoundRecorder','Microsoft.Whiteboard','Microsoft.MicrosoftJournal',
  'Microsoft.Windows.DevHome','Microsoft.OutlookForWindows','Microsoft.OneNote',
  'Microsoft.Office.OneNote','Microsoft.Office.Desktop.LanguagePack'
)

# Some packages are core/system and cannot be removed
$nonRemovable = @(
  'Microsoft.XboxGameCallableUI'   # Returns 0x80070032 (not supported)
)

function Write-Log([string]$m){ "{0} - {1}" -f (Get-Date), $m | Tee-Object -FilePath $Log }

# Enumerate local user SIDs (non-special)
$userSids = Get-CimInstance Win32_UserProfile |
  Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' } |
  Select-Object -ExpandProperty SID

Write-Log ("User SIDs: {0}" -f ($userSids -join ', '))

foreach($app in $appsToRemove){
  Write-Log "=== $app ==="
  if($nonRemovable -contains $app){
    Write-Log "Skipping $app (non-removable system component)."
    continue
  }

  # 1) Remove from provisioned image (so new users don't get it)
  try{
    $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "$app*" }
    if($prov){
      foreach($pp in $prov){
        Write-Log "Removing provisioned: $($pp.DisplayName) ($($pp.PackageName))"
        try{ Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName | Out-Null } catch { Write-Log "WARN remove provisioned: $($_.Exception.Message)" }
      }
    } else { Write-Log "Not provisioned." }
  } catch { Write-Log "WARN Get-AppxProvisionedPackage: $($_.Exception.Message)" }

  # 2) Remove for all existing users by SID (more reliable than -AllUsers)
  try{
    $pkgs = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
    if($pkgs){
      foreach($p in $pkgs){
        Write-Log "Found installed: $($p.Name) ($($p.PackageFullName))"
        foreach($sid in $userSids){
          try{
            Write-Log "Removing for SID $sid ..."
            Remove-AppxPackage -Package $p.PackageFullName -User $sid -ErrorAction Continue
          } catch {
            Write-Log "WARN remove for $sid: $($_.Exception.Message)"
          }
        }
      }
    } else { Write-Log "Not installed for any user." }
  } catch { Write-Log "WARN Get-AppxPackage: $($_.Exception.Message)" }
}

Write-Log "Completed app removal."
exit 0
