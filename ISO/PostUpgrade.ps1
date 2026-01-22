# =====================================================================
# PostUpgrade.ps1
# - Re-baseline exactly 3 WU GPOs (Not Configured)
# - Suppress Privacy Experience
# - Patch to completion (no clicking) using COM + USO nudge
# - Reboot automatically when installs require it (and continue)
# - AFTER fully patched, install & activate MAK
# =====================================================================

param(
  [string]$MakKey = 'NMH77-98GCG-VH349-4FJC3-4GG8R'  # override if needed
)

$ErrorActionPreference = 'Stop'

# ---------- logging ----------
$LogRoot = 'C:\Upgrade\LTSC2021'
New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
$Log = Join-Path $LogRoot 'PostUpgrade.log'
try { Start-Transcript -Path $Log -Append } catch {}

function Log([string]$m,[ConsoleColor]$c='Gray'){
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  Write-Host "[$ts] $m" -ForegroundColor $c
}

# ---------- policy baseline ----------
function Clear-ThreeWUPolicies {
  Log 'Clearing 3 WU GPOs (baseline: Not Configured)...'
  $WU = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
  $AU = Join-Path $WU 'AU'

  if (Test-Path $WU) {
    foreach($n in 'WUServer','WUStatusServer','DisableWindowsUpdateAccess'){
      try{ Remove-ItemProperty -Path $WU -Name $n -ErrorAction SilentlyContinue }catch{}
    }
  }
  if (Test-Path $AU) {
    foreach($n in 'UseWUServer','AutoInstallMinorUpdates'){
      try{ Remove-ItemProperty -Path $AU -Name $n -ErrorAction SilentlyContinue }catch{}
    }
  }

  $bad=@()
  if (Test-Path $WU) {
    foreach($n in 'WUServer','WUStatusServer','DisableWindowsUpdateAccess'){
      if (Get-ItemProperty -Path $WU -Name $n -ErrorAction SilentlyContinue){ $bad += "$WU : $n" }
    }
  }
  if (Test-Path $AU) {
    foreach($n in 'UseWUServer','AutoInstallMinorUpdates'){
      if (Get-ItemProperty -Path $AU -Name $n -ErrorAction SilentlyContinue){ $bad += "$AU : $n" }
    }
  }
  if ($bad.Count){ throw "Policy cleanup verification failed: $($bad -join '; ')" }
  Log '3 policies are Not Configured.' 'Green'
}

# ---------- privacy suppression ----------
function Suppress-PrivacyExperience {
  $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
  New-Item -Path $k -Force | Out-Null
  New-ItemProperty -Path $k -Name DisablePrivacyExperience -PropertyType DWord -Value 1 -Force | Out-Null
  Log 'Privacy Experience suppressed.' 'Green'
}

# ---------- USO nudge ----------
function Kick-USO {
  try{
    foreach($s in 'wuauserv','bits','UsoSvc','WaaSMedicSvc'){
      try{ sc.exe config $s start= delayed-auto | Out-Null }catch{}
      try{ Start-Service $s -ErrorAction SilentlyContinue }catch{}
    }
    UsoClient StartScan     2>$null
    UsoClient StartDownload 2>$null
    UsoClient StartInstall  2>$null
  }catch{}
}

# ---------- pending reboot detector ----------
function Get-PendingReboot {
  $pending = $false
  try{
    if (Test-Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'){ $pending = $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'){ $pending = $true }
    $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
    if ($pf){ $pending = $true }
  }catch{}
  return $pending
}

# ---------- patch-to-completion ----------
function Invoke-WindowsUpdateToCompletion {
  Log 'Scanning for updates...'
  foreach($svc in 'wuauserv','bits'){ try{ Start-Service $svc -ErrorAction SilentlyContinue }catch{} }

  $session    = New-Object -ComObject Microsoft.Update.Session
  $downloader = $session.CreateUpdateDownloader()
  $installer  = $session.CreateUpdateInstaller()

  $reboot = $false
  $remaining = $null

  for($round=1; $round -le 10; $round++){
    Kick-USO
    $searcher = $session.CreateUpdateSearcher()
    $result   = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    $count    = $result.Updates.Count
    Log "Round ${round}: found ${count} updates not installed."

    $toGet = New-Object -ComObject Microsoft.Update.UpdateColl
    for($i=0; $i -lt $count; $i++){
      $u = $result.Updates.Item($i)
      if ($u.Categories | Where-Object { $_.Type -eq 1 -and $_.Name -like '*Driver*' }) { continue }
      [void]$toGet.Add($u)
    }

    if ($toGet.Count -eq 0){ $remaining = 0; break }

    $downloader.Updates = $toGet
    $dres = $downloader.Download()
    Log "  Download result: $($dres.ResultCode)"

    Kick-USO

    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    for($i=0; $i -lt $toGet.Count; $i++){
      $u = $toGet.Item($i)
      if ($u.IsDownloaded){ [void]$toInstall.Add($u) }
    }
    if ($toInstall.Count -eq 0){ Start-Sleep 10; continue }

    $installer.Updates = $toInstall
    $ires = $installer.Install()
    Log "  Install result: $($ires.ResultCode); RebootRequired=$($ires.RebootRequired)"

    if ($ires.RebootRequired -or (Get-PendingReboot)){
      $reboot = $true
      break
    }
    Start-Sleep 5
  }

  if (-not $reboot){
    $remaining = ($session.CreateUpdateSearcher()).Search("IsInstalled=0 and IsHidden=0 and Type='Software'").Updates.Count
  }
  [pscustomobject]@{Remaining=$remaining; RebootRequired=$reboot}
}

# ---------- activation ----------
function Invoke-Activation([string]$Key){
  if ([string]::IsNullOrWhiteSpace($Key)){ Log 'No MAK provided; skipping activation.'; return }
  Log 'Installing MAK...'
  try{ cscript.exe //nologo $env:windir\system32\slmgr.vbs /ckms | Out-Null }catch{}
  cscript.exe //nologo $env:windir\system32\slmgr.vbs /ipk $Key | Out-Null
  Start-Sleep 2
  Log 'Attempting activation...'
  cscript.exe //nologo $env:windir\system32\slmgr.vbs /ato | Out-Null
  Log 'Activation attempted.'
}

# ---------- MAIN ----------
$delay = [int]([Environment]::GetEnvironmentVariable('POST_DELAY_SECONDS','Machine'))
if ($delay -gt 0){ Log "Delaying start by ${delay} seconds..."; Start-Sleep -Seconds $delay }

try{
  $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ReleaseId
  if (-not $build){ $build = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion }
  Log "Post sequence starting on build ${build}"

  Clear-ThreeWUPolicies
  Suppress-PrivacyExperience

  for($pass=1; $pass -le 6; $pass++){
    $res = Invoke-WindowsUpdateToCompletion
    Log ("Round {0} summary: Remaining={1}; RebootRequired={2}" -f $pass,$res.Remaining,$res.RebootRequired)

    if ($res.RebootRequired){
      $tn = 'PostUpgrade-ContinueUntilPatched'
      try{ schtasks /Delete /TN $tn /F 2>$null | Out-Null }catch{}
      $ps1 = 'C:\Windows\Setup\Scripts\PostUpgrade.ps1'
      schtasks /Create /TN $tn /SC ONSTART /RU SYSTEM /RL HIGHEST `
        /TR "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$ps1`"" /F | Out-Null
      Log 'Registered one-time startup task: PostUpgrade-ContinueUntilPatched' 'Yellow'
      Log 'Rebooting automatically in 30 seconds to continue patching...' 'Yellow'
      Start-Sleep 30
      shutdown.exe /r /t 5 /c "Continuing Windows Update patch cycle" /f
      break
    }

    if ($res.Remaining -le 0){
      Log 'Windows Update reports no pending software updates.' 'Green'
      Invoke-Activation $MakKey
      try{ schtasks /Delete /TN 'PostUpgrade-ContinueUntilPatched' /F 2>$null | Out-Null }catch{}
      break
    }

    Kick-USO
    Start-Sleep 15
  }
}
catch{
  Log ("ERROR: " + $_.Exception.Message) 'Red'
}
finally{
  try{ Stop-Transcript | Out-Null }catch{}
}
