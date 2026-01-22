param(
  [switch]$AutoLogoff,
  [switch]$AutoReboot,
  [switch]$Force
)

# Windows Privacy Toggle (Hardened <-> Default) + optional sign-out/reboot
# Safe posture: keeps Windows Update/Store intact
$ErrorActionPreference='Stop'
$stateFile='C:\PrivacyToggle.state'

function Set-Reg($p,$n,$v,$t='DWord'){ if(!(Test-Path $p)){ New-Item -Path $p -Force|Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }
function Del-Reg($p,$n){ if(Test-Path $p){ Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue } }
function Task-Disable($f){ try{ $tp=$f.Substring(0,$f.LastIndexOf('\')+1); $tn=$f.Substring($f.LastIndexOf('\')+1); Disable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop|Out-Null }catch{} }
function Task-Enable($f){ try{ $tp=$f.Substring(0,$f.LastIndexOf('\')+1); $tn=$f.Substring($f.LastIndexOf('\')+1); Enable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop|Out-Null }catch{} }

$tasks=@(
  '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
  '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
  '\Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
  '\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
  '\Microsoft\Windows\Autochk\Proxy'
)

$harden = -not (Test-Path $stateFile) -or ((Get-Content $stateFile -ErrorAction SilentlyContinue) -ne 'Hardened')

if($harden){
  Write-Host 'Applying HARDENED privacy posture...' -ForegroundColor Cyan

  # Telemetry + feedback + tailored experiences
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1

  # Advertising & consumer content
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0

  # Speech / Inking / Location
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessLocation' 2  # Force Deny

  # Services (leave WU/Store alone)
  foreach($svc in 'DiagTrack','RetailDemo'){
    $s=Get-Service -Name $svc -ErrorAction SilentlyContinue
    if($s){ Stop-Service $svc -ErrorAction SilentlyContinue; Set-Service $svc -StartupType Disabled }
  }

  # Telemetry tasks
  $tasks | ForEach-Object { Task-Disable $_ }

  # Delivery Optimization
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0

  # Cloud-optimized content
  Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1

  'Hardened' | Set-Content $stateFile -Encoding ASCII
  Write-Host 'Done. State = HARDENED.' -ForegroundColor Green

}else{
  Write-Host 'Restoring DEFAULT posture...' -ForegroundColor Yellow

  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures'
  Set-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSyncProviderNotifications' -Value 1 -ErrorAction SilentlyContinue
  Del-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled'
  Del-Reg 'HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted'
  Del-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection'
  Del-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessLocation'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode'
  Del-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent'

  foreach($svc in 'DiagTrack','RetailDemo'){
    $s=Get-Service -Name $svc -ErrorAction SilentlyContinue
    if($s){ Set-Service $svc -StartupType Manual; Start-Service $svc -ErrorAction SilentlyContinue }
  }

  $tasks | ForEach-Object { Task-Enable $_ }

  'Default' | Set-Content $stateFile -Encoding ASCII
  Write-Host 'Done. State = DEFAULT.' -ForegroundColor Green
}

# --- Optional sign-out / reboot control ---
if($AutoLogoff -and $AutoReboot){
  Write-Warning "Choose either -AutoLogoff or -AutoReboot, not both."
  exit 1
}

if($AutoLogoff){
  if($Force -or (Read-Host 'Sign out now? ALL unsaved work will be lost. Type YES to continue') -eq 'YES'){
    shutdown.exe /l
  }else{
    Write-Host 'Canceled sign-out.'
  }
}elseif($AutoReboot){
  if($Force -or (Read-Host 'Reboot now? ALL unsaved work will be lost. Type YES to continue') -eq 'YES'){
    shutdown.exe /r /t 5
  }else{
    Write-Host 'Canceled reboot.'
  }
}else{
  Write-Host 'Tip: add -AutoLogoff or -AutoReboot to apply changes immediately.'
}
