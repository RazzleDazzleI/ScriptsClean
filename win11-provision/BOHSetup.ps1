<# 
  BOHSetup.ps1 — Steps 1–9 + Wallpaper Lock + Auto-Lock on Display-Off

  1: Debloat built-in Store apps (KEEP Snipping Tool)
  2: Remove “Teams Machine-Wide Installer” + old per-user Teams
  3: Install NEW Microsoft Teams (work or school) via winget
  4: Import final .reg after everything
  5: Ensure local admin user "drmadministrator"
  6: Deploy & (optionally) LOCK wallpaper to C:\Windows\Web\Wallpaper\drmBackground.jpg
  7: Timezone + power: display-off allowed; Sleep/Hibernate=Never; Auto-lock at N minutes
  8: ExecutionPolicy RemoteSigned (LM/CU) + Microsoft Defender exclusions
  9: App installs (winget preferred; local fallback from MediaRoot; interactive stop-points)

  - Auto-elevates
  - Logs to C:\ProgramData\DRM\Provision\Logs
  - Idempotent
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # NEW: where your installers / media live. You said you'll use C:\Temp.
  [string]$MediaRoot = 'C:\Temp',

  [switch]$NoPause,
  [string]$RegFilePath,
  [string]$AdminUser = 'drmadministrator',
  [string]$AdminPasswordEnv = 'DRM_ADMIN_PWD',

  # Wallpaper
  [string]$WallpaperSourcePath,
  [string]$WallpaperName = 'drmBackground.jpg',
  [ValidateSet('Fill','Fit','Stretch','Center','Tile','Span')]
  [string]$WallpaperMode = 'Fill',
  [bool]$LockWallpaper = $true,

  # Power/security knobs
  [string]$TimeZoneName      = 'Central Standard Time',
  [string]$PowerSchemeName   = 'DRM No Sleep',
  [int]   $DisplayOffMinutes = 10,
  [int]   $LockMinutes       = 10,
  [bool]  $DisableHibernate  = $true,
  [bool]  $RefreshPolicy     = $true
)

# ----------------------------- Elevation -----------------------------
function Confirm-AdminOrElevate {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[i] Relaunching with elevation..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`" " + (
      $PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) `"$($_.Value)`"" } -join ' '
    )
    $psi.Verb = "runas"
    try   { [Diagnostics.Process]::Start($psi) | Out-Null } 
    catch { throw "User canceled UAC prompt." }
    exit
  }
}
Confirm-AdminOrElevate

# ----------------------------- Logging ------------------------------
$LogDir = "C:\ProgramData\DRM\Provision\Logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("BOHSetup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Append | Out-Null

# ----------------------------- UX helpers --------------------------
function Write-Info       ($m){ Write-Host "[i] $m" -ForegroundColor Cyan }
function Write-WarningMsg ($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-ErrorMsg   ($m){ Write-Host "[x] $m" -ForegroundColor Red }
function Write-Success    ($m){ Write-Host "[✓] $m" -ForegroundColor Green }

function Invoke-Task {
  param([Parameter(Mandatory)] [string]$StepName, [Parameter(Mandatory)] [scriptblock]$Action)
  Write-Host "`n==== $StepName ====" -ForegroundColor White
  try   { & $Action; Write-Success "$StepName complete." }
  catch { Write-ErrorMsg "$StepName failed: $($_.Exception.Message)"; throw }
  if (-not $NoPause) { Read-Host -Prompt "Press Enter to continue..." | Out-Null }
}

# ----------------------------- Shared helpers -----------------------
# Look for a file in: explicit path -> MediaRoot -> MediaRoot\assets -> script folder -> script\assets -> recursive under MediaRoot/script
function Resolve-MediaPath {
  param([Parameter(Mandatory)][string]$NameOrPath)
  if (Test-Path $NameOrPath) { return (Resolve-Path $NameOrPath).Path }

  $candidates = @(
    (Join-Path $MediaRoot              $NameOrPath),
    (Join-Path $MediaRoot ("assets\" + $NameOrPath)),
    (Join-Path $PSScriptRoot           $NameOrPath),
    (Join-Path $PSScriptRoot ("assets\" + $NameOrPath))
  )
  foreach($c in $candidates){ if(Test-Path $c){ return (Resolve-Path $c).Path } }

  $found = Get-ChildItem -Path @($MediaRoot,$PSScriptRoot) -Filter $NameOrPath -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($found) { return $found.FullName }
  return $null
}

function Get-NonSpecialUserSids {
  Get-CimInstance Win32_UserProfile |
    Where-Object { -not $_.Special -and $_.LocalPath -like 'C:\Users\*' } |
    Select-Object SID, LocalPath, Loaded
}

# Used in Steps 2 & 3
function Stop-TeamsProcesses {
  Write-Info "Stopping Teams-related processes (if any)..."
  foreach($n in @("Teams","Update","Squirrel","SquirrelTemp")){
    try { Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# ----------------------------- STEP 1 -------------------------------
$AppsToRemove = @(
  "Microsoft.BingNews","Microsoft.BingWeather","Microsoft.Getstarted",
  "Microsoft.MicrosoftOfficeHub","Microsoft.MicrosoftSolitaireCollection",
  "Microsoft.MicrosoftStickyNotes","Microsoft.People",
  # "Microsoft.ScreenSketch",   # KEEP: Snipping Tool
  "Microsoft.WindowsAlarms","Microsoft.WindowsMaps","Microsoft.XboxGamingOverlay",
  "Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay",
  "Microsoft.ZuneMusic","Microsoft.ZuneVideo","Microsoft.Windows.Photos",
  "Microsoft.WindowsSoundRecorder","Microsoft.Whiteboard","Microsoft.MicrosoftJournal",
  "Microsoft.Windows.DevHome","Microsoft.OutlookForWindows","Microsoft.OneNote",
  "Microsoft.Office.OneNote","Microsoft.Office.Desktop.LanguagePack"
)
$NonRemovable = @("Microsoft.XboxGameCallableUI")  # OS-bound; skip

Invoke-Task -StepName "STEP1_RemoveBloat_KeepSnip" -Action {
  Write-Info "Collecting user SIDs..."
  $profiles = Get-NonSpecialUserSids
  foreach ($app in $AppsToRemove) {
    if ($NonRemovable -contains $app) { Write-Info "Skipping non-removable: $app"; continue }

    # future users
    try {
      $prov = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "$app*" }
      if ($prov) {
        foreach ($pp in $prov) {
          Write-Info "Deprovision: $($pp.DisplayName)"
          try { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName | Out-Null }
          catch { Write-WarningMsg "WARN deprovision ${app}: $($_.Exception.Message)" }
        }
      } else { Write-Info "Not provisioned: $app" }
    } catch { Write-WarningMsg "WARN querying provisioned for ${app}: $($_.Exception.Message)" }

    # existing users
    try {
      $pkgs = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
      if ($pkgs) {
        foreach ($p in $pkgs) {
          foreach ($prof in $profiles) {
            try { Remove-AppxPackage -Package $p.PackageFullName -User $prof.SID -ErrorAction Continue }
            catch { Write-WarningMsg "WARN remove ${app} for $($prof.SID): $($_.Exception.Message)" }
          }
        }
      } else { Write-Info "Not installed for any user: $app" }
    } catch { Write-WarningMsg "WARN Get-AppxPackage for ${app}: $($_.Exception.Message)" }
  }
  Write-Success "Bloat removal pass completed."
}

# ----------------------------- STEP 2 -------------------------------
function Uninstall-TeamsMachineWide {
  Write-Info "Checking for 'Teams Machine-Wide Installer'..."
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $mw = Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' }
  if($mw){
    foreach($app in $mw){
      $cmd = $app.UninstallString
      if($cmd -match 'MsiExec\.exe.*?/I\{([0-9A-F\-]+)\}'){ $guid=$matches[1]; $cmd="msiexec.exe /X{$guid} /qn /norestart" }
      elseif($cmd -match 'MsiExec\.exe.*?/X\{([0-9A-F\-]+)\}'){ $guid=$matches[1]; $cmd="msiexec.exe /X{$guid} /qn /norestart" }
      else { $cmd = "$cmd /qn /norestart" }
      Write-Info "Uninstalling: $cmd"
      try { Start-Process cmd.exe "/c $cmd" -Wait -WindowStyle Hidden | Out-Null }
      catch { Write-WarningMsg "Uninstall MSI warn: $($_.Exception.Message)" }
    }
  } else { Write-Info "Teams Machine-Wide Installer not found." }
}
function Uninstall-TeamsPerUserAndClean {
  Write-Info "Removing per-user Teams installs and caches..."
  foreach($u in Get-NonSpecialUserSids){
    $userRoot = $u.LocalPath
    $upd = Join-Path $userRoot 'AppData\Local\Microsoft\Teams\Update.exe'
    if(Test-Path $upd){
      Write-Info "Uninstall per-user Teams: $userRoot"
      try { Start-Process $upd -ArgumentList '--uninstall -s' -Wait -WindowStyle Hidden | Out-Null }
      catch { Write-WarningMsg "Uninstall warn (${userRoot}): $($_.Exception.Message)" }
    }
    foreach($d in 'AppData\Local\Microsoft\Teams','AppData\Roaming\Microsoft\Teams'){
      $p = Join-Path $userRoot $d
      if(Test-Path $p){ try { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue } catch {} }
    }
    foreach($lnk in @(
      (Join-Path $userRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Teams.lnk'),
      (Join-Path $userRoot 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Corporation\Microsoft Teams (work or school).lnk')
    )){ if(Test-Path $lnk){ try { Remove-Item -Force $lnk -ErrorAction SilentlyContinue } catch {} } }
  }
  $cache = 'C:\Program Files (x86)\Teams Installer'
  if(Test-Path $cache){ try { Remove-Item -Recurse -Force $cache -ErrorAction SilentlyContinue } catch {} }
}
Invoke-Task -StepName "STEP2_TeamsCleanup" -Action {
  Stop-TeamsProcesses
  Uninstall-TeamsMachineWide
  Uninstall-TeamsPerUserAndClean
  Write-Success "Classic Teams cleanup completed."
}

# ----------------------------- STEP 3 -------------------------------
function Test-NewTeamsInstalled { try { [bool](Get-AppxPackage -AllUsers -Name "MSTeams" -ErrorAction SilentlyContinue) } catch { $false } }
function Install-NewTeams {
  param([switch]$ForceReinstall)
  Stop-TeamsProcesses
  try { & winget source update | Out-Null } catch {}
  if (-not $ForceReinstall -and (Test-NewTeamsInstalled)) { Write-Info "New Microsoft Teams already installed; skipping."; return }
  Write-Info "Installing Microsoft Teams via winget..."
  $p1 = Start-Process winget -ArgumentList "install -e --id Microsoft.Teams --silent --accept-source-agreements --accept-package-agreements" -Wait -PassThru -WindowStyle Hidden
  if ($p1.ExitCode -ne 0) {
    Write-WarningMsg "winget exit $($p1.ExitCode). Trying msstore source..."
    $p2 = Start-Process winget -ArgumentList "install -e --id Microsoft.Teams -s msstore --accept-source-agreements --accept-package-agreements" -Wait -PassThru -WindowStyle Hidden
    if ($p2.ExitCode -ne 0) { throw "Teams install failed (winget exit $($p1.ExitCode), msstore exit $($p2.ExitCode))." }
  }
  Start-Sleep 3
  if (Test-NewTeamsInstalled) { Write-Success "Microsoft Teams (work or school) installed." }
  else { Write-WarningMsg "Teams not confirmed via Appx query; verify manually." }
}
Invoke-Task -StepName "STEP3_InstallNewTeams" -Action { Install-NewTeams }

# ----------------------------- STEP 4 -------------------------------
function Find-RegFile {
  if ($RegFilePath -and (Test-Path $RegFilePath)) { return (Resolve-Path $RegFilePath).Path }
  $n = 'enroll_in_03ph8a2z1pvebabStores.reg'
  $p = Resolve-MediaPath $n
  if ($p) { return $p }
  return $null
}
function Import-RegistryFile { param([string]$PathToReg)
  if (-not $PathToReg -or -not (Test-Path $PathToReg)) { Write-WarningMsg "REG file not found; skipping."; return }
  Write-Info "Importing REG: ${PathToReg}"
  try {
    $p = Start-Process reg.exe -ArgumentList @("import","$PathToReg") -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 0) { Write-Success "REG import completed." } else { Write-WarningMsg "REG import exit $($p.ExitCode)." }
  } catch { Write-WarningMsg "REG import error: $($_.Exception.Message)" }
}
Invoke-Task -StepName "STEP4_FinalRegImport" -Action {
  $targetReg = Find-RegFile
  if ($targetReg) { Import-RegistryFile -PathToReg $targetReg }
  else { Write-WarningMsg "Could not locate the enroll REG under MediaRoot/script paths." }
}

# ----------------------------- STEP 5 -------------------------------
function ConvertTo-Plaintext { param([Security.SecureString]$Secure)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { if($bstr -ne [IntPtr]::Zero){ [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
}
function Get-PasswordFromEnvOrPrompt { param([string]$EnvName,[switch]$AllowPrompt)
  $val = (Get-Item -Path ("Env:{0}" -f $EnvName) -ErrorAction SilentlyContinue).Value
  if ($val) { return (ConvertTo-SecureString $val -AsPlainText -Force) }
  if ($AllowPrompt) { return Read-Host -AsSecureString -Prompt "Enter password for $AdminUser" }
  return $null
}
function Ensure-LocalAdmin {
  param([string]$Name,[Security.SecureString]$PasswordSecure)
  $hasLocalAccounts = [bool](Get-Command Get-LocalUser -ErrorAction SilentlyContinue)
  $exists = if($hasLocalAccounts){ [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) } else { [bool](Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount=True AND Name='$Name'" -ErrorAction SilentlyContinue) }
  if (-not $exists) {
    Write-Info "Creating local user '${Name}'..."
    if ($hasLocalAccounts) {
      New-LocalUser -Name $Name -Password $PasswordSecure -PasswordNeverExpires:$true -UserMayNotChangePassword:$true -AccountNeverExpires:$true -FullName "DRM Local Administrator" -Description "Managed by BOHSetup" | Out-Null
    } else {
      $plain = ConvertTo-Plaintext $PasswordSecure
      $adsi = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
      $nu = $adsi.Create("user", $Name); $nu.SetPassword($plain); $nu.SetInfo()
      $user = [ADSI]"WinNT://$env:COMPUTERNAME/$Name,user"
      $user.UserFlags = ($user.UserFlags.Value -bor 0x40 -bor 0x10000); $user.SetInfo()
    }
  } else {
    Write-Info "User exists; ensuring settings..."
    $plain = ConvertTo-Plaintext $PasswordSecure
    try { $user = [ADSI]"WinNT://$env:COMPUTERNAME/$Name,user"; $user.SetPassword($plain); $user.SetInfo() } catch {}
    if ($hasLocalAccounts) { try { Set-LocalUser -Name $Name -PasswordNeverExpires $true -UserMayNotChangePassword $true -AccountNeverExpires $true } catch {} } else { cmd /c "net user $Name /passwordchg:no /expires:never /active:yes" | Out-Null }
  }
  Write-Info "Adding to Administrators..."
  if ($hasLocalAccounts) { try { Add-LocalGroupMember -Group 'Administrators' -Member $Name -ErrorAction SilentlyContinue } catch {} } else { cmd /c "net localgroup Administrators $Name /add" | Out-Null }
  Write-Success "Local admin '${Name}' ensured."
}
Invoke-Task -StepName "STEP5_EnsureLocalAdmin" -Action {
  $sec = Get-PasswordFromEnvOrPrompt -EnvName $AdminPasswordEnv -AllowPrompt:(!$NoPause)
  if (-not $sec) { Write-WarningMsg "No password available for ${AdminUser}. Set Env:$AdminPasswordEnv or run interactively. Skipping Step 5."; return }
  Ensure-LocalAdmin -Name $AdminUser -PasswordSecure $sec
}

# ----------------------------- STEP 6 -------------------------------
function Find-WallpaperSource {
  if ($WallpaperSourcePath -and (Test-Path $WallpaperSourcePath)) { return (Resolve-Path $WallpaperSourcePath).Path }
  $p = Resolve-MediaPath $WallpaperName
  if ($p) { return $p }
  return $null
}
function Install-WallpaperFile {
  param([string]$Source,[string]$DestPath)
  $destDir = Split-Path $DestPath -Parent
  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  if (Test-Path $DestPath) {
    $src = Get-Item $Source; $dst = Get-Item $DestPath
    if ($src.Length -eq $dst.Length -and $src.LastWriteTimeUtc -eq $dst.LastWriteTimeUtc) { Write-Info "Wallpaper already present."; return }
  }
  Copy-Item $Source $DestPath -Force
  Write-Success "Wallpaper staged at $DestPath"
}
function Get-StyleValues {
  switch ($WallpaperMode) {
    'Fill'    { @{ WallpaperStyle='10'; TileWallpaper='0' } }
    'Fit'     { @{ WallpaperStyle='6' ; TileWallpaper='0' } }
    'Stretch' { @{ WallpaperStyle='2' ; TileWallpaper='0' } }
    'Center'  { @{ WallpaperStyle='0' ; TileWallpaper='0' } }
    'Tile'    { @{ WallpaperStyle='0' ; TileWallpaper='1' } }
    'Span'    { @{ WallpaperStyle='22'; TileWallpaper='0' } }
  }
}
function Set-WallpaperInHive { param([string]$HiveRoot,[string]$ImagePath)
  $desk = Join-Path $HiveRoot 'Control Panel\Desktop'
  if (-not (Test-Path "Registry::$desk")) { New-Item -Path "Registry::$desk" -Force | Out-Null }
  Set-ItemProperty -Path "Registry::$desk" -Name Wallpaper -Value $ImagePath -Type String
  $v = Get-StyleValues
  Set-ItemProperty -Path "Registry::$desk" -Name WallpaperStyle -Value $v.WallpaperStyle -Type String
  Set-ItemProperty -Path "Registry::$desk" -Name TileWallpaper    -Value $v.TileWallpaper    -Type String
}
function Set-WallpaperPolicyInHive { param([string]$HiveRoot,[string]$ImagePath,[bool]$Enabled)
  $sys = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
  $act = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'
  if ($Enabled) {
    if (-not (Test-Path "Registry::$sys")) { New-Item -Path "Registry::$sys" -Force | Out-Null }
    if (-not (Test-Path "Registry::$act")) { New-Item -Path "Registry::$act" -Force | Out-Null }
    $v = Get-StyleValues
    Set-ItemProperty -Path "Registry::$sys" -Name Wallpaper      -Value $ImagePath -Type String
    Set-ItemProperty -Path "Registry::$sys" -Name WallpaperStyle -Value $v.WallpaperStyle -Type String
    New-ItemProperty -Path "Registry::$act" -Name 'NoChangingWallPaper' -PropertyType DWord -Value 1 -Force | Out-Null
  } else {
    if (Test-Path "Registry::$sys") { Remove-ItemProperty -Path "Registry::$sys" -Name Wallpaper -ErrorAction SilentlyContinue; Remove-ItemProperty -Path "Registry::$sys" -Name WallpaperStyle -ErrorAction SilentlyContinue }
    if (Test-Path "Registry::$act") { Remove-ItemProperty -Path "Registry::$act" -Name 'NoChangingWallPaper' -ErrorAction SilentlyContinue }
  }
}
function Apply-CurrentSessionWallpaper { param([string]$ImagePath)
  Add-Type @"
using System.Runtime.InteropServices;
public class NativeMethods {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
  [void][NativeMethods]::SystemParametersInfo(0x0014, 0, $ImagePath, 0x1 -bor 0x2)
}
function Set-WallpaperForExistingUsers { param([string]$ImagePath,[bool]$Lock)
  foreach($p in Get-NonSpecialUserSids){
    if ($p.Loaded) {
      $hive = "HKEY_USERS\$($p.SID)"
      try { Set-WallpaperInHive -HiveRoot $hive -ImagePath $ImagePath; Set-WallpaperPolicyInHive -HiveRoot $hive -ImagePath $ImagePath -Enabled:$Lock } catch {}
    } else {
      $mount = "HKU\TMP_$($p.SID)"; $nt = Join-Path $p.LocalPath 'NTUSER.DAT'
      if (Test-Path $nt) {
        try { & reg.exe load $mount "$nt" | Out-Null; Set-WallpaperInHive -HiveRoot "HKEY_USERS\TMP_$($p.SID)" -ImagePath $ImagePath; Set-WallpaperPolicyInHive -HiveRoot "HKEY_USERS\TMP_$($p.SID)" -ImagePath $ImagePath -Enabled:$Lock } catch {} finally { try { & reg.exe unload $mount | Out-Null } catch {} }
      }
    }
  }
}
function Set-WallpaperForDefaultProfile { param([string]$ImagePath,[bool]$Lock)
  $nt = 'C:\Users\Default\NTUSER.DAT'
  if (Test-Path $nt) {
    $mount = "HKU\TMP_DEFAULT"
    try { & reg.exe load $mount "$nt" | Out-Null; Set-WallpaperInHive -HiveRoot "HKEY_USERS\TMP_DEFAULT" -ImagePath $ImagePath; Set-WallpaperPolicyInHive -HiveRoot "HKEY_USERS\TMP_DEFAULT" -ImagePath $ImagePath -Enabled:$Lock } catch {} finally { try { & reg.exe unload $mount | Out-Null } catch {} }
  }
}
function Set-MachineActiveDesktopBlock { param([bool]$Enabled)
  $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'
  if ($Enabled) { if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }; New-ItemProperty -Path $path -Name 'NoChangingWallPaper' -PropertyType DWord -Value 1 -Force | Out-Null }
  else { if (Test-Path $path) { Remove-ItemProperty -Path $path -Name 'NoChangingWallPaper' -ErrorAction SilentlyContinue } }
}
Invoke-Task -StepName "STEP6_SetWallpaper" -Action {
  $src = if ($WallpaperSourcePath) { Resolve-MediaPath $WallpaperSourcePath } else { Find-WallpaperSource }
  if (-not $src) { throw "Cannot find source image '$WallpaperName'. Place it in $MediaRoot (or assets) or pass -WallpaperSourcePath." }
  $dest = Join-Path 'C:\Windows\Web\Wallpaper' $WallpaperName
  Install-WallpaperFile -Source $src -DestPath $dest
  Set-WallpaperForExistingUsers -ImagePath $dest -Lock:$LockWallpaper
  Set-WallpaperForDefaultProfile -ImagePath $dest -Lock:$LockWallpaper
  Set-MachineActiveDesktopBlock -Enabled:$LockWallpaper
  try { Apply-CurrentSessionWallpaper -ImagePath $dest } catch {}
  Write-Success "Wallpaper applied. ($([bool]$LockWallpaper ? 'LOCKED' : 'UNLOCKED'))"
}

# ----------------------------- STEP 7 -------------------------------
function Set-TimezoneSafe { param([string]$TzName)
  try {
    $current = (Get-TimeZone).Id
    if ($current -ne $TzName) { try { Set-TimeZone -Name $TzName } catch { & tzutil.exe /s "$TzName" } }
  } catch { & tzutil.exe /s "$TzName" }
}
function Get-OrCreate-NoSleepScheme { param([string]$Name)
  $list = & powercfg -list 2>$null
  if ($LASTEXITCODE -eq 0) {
    $match = ($list | Select-String -Pattern [regex]::Escape($Name) | Select-Object -First 1)
    if ($match) { if ($match.Line -match '([0-9a-fA-F\-]{36})') { return $matches[1] } }
  }
  $dup = & powercfg -duplicatescheme SCHEME_BALANCED 2>&1
  if ($dup -match '([0-9a-fA-F\-]{36})') { $guid = $matches[1] } else { throw "Could not parse GUID: $dup" }
  & powercfg -changename $guid "$Name" | Out-Null
  return $guid
}
function Configure-NoSleep { param([string]$SchemeGuid,[int]$DisplayMinutes,[bool]$HibernateOff)
  $sec = [Math]::Max(1, $DisplayMinutes) * 60
  & powercfg -setacvalueindex $SchemeGuid SUB_VIDEO VIDEOIDLE     $sec | Out-Null
  & powercfg -setdcvalueindex $SchemeGuid SUB_VIDEO VIDEOIDLE     $sec | Out-Null
  & powercfg -setacvalueindex $SchemeGuid SUB_SLEEP STANDBYIDLE   0    | Out-Null
  & powercfg -setdcvalueindex $SchemeGuid SUB_SLEEP STANDBYIDLE   0    | Out-Null
  & powercfg -setacvalueindex $SchemeGuid SUB_SLEEP HIBERNATEIDLE 0    | Out-Null
  & powercfg -setdcvalueindex $SchemeGuid SUB_SLEEP HIBERNATEIDLE 0    | Out-Null
  & powercfg -setactive $SchemeGuid | Out-Null
  if ($HibernateOff) { & powercfg -hibernate off | Out-Null }
}
function Set-MachineInactivityLock { param([int]$IdleMinutes,[bool]$DoRefreshPolicy)
  $seconds = [Math]::Max(1, $IdleMinutes) * 60
  $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  if (-not (Test-Path $path)) { New-Item $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name 'InactivityTimeoutSecs' -PropertyType DWord -Value $seconds -Force | Out-Null
  if ($DoRefreshPolicy) {
    try { Start-Process secedit.exe -ArgumentList '/refreshpolicy machine_policy /enforce' -Wait -WindowStyle Hidden | Out-Null } catch {}
    try { Start-Process gpupdate.exe -ArgumentList '/target:computer /force' -Wait -WindowStyle Hidden | Out-Null } catch {}
  }
}
Invoke-Task -StepName "STEP7_Timezone_And_NoSleepPower" -Action {
  Set-TimezoneSafe -TzName $TimeZoneName
  $eff = ($LockMinutes -gt 0) ? $LockMinutes : $DisplayOffMinutes
  $guid = Get-OrCreate-NoSleepScheme -Name $PowerSchemeName
  Configure-NoSleep -SchemeGuid $guid -DisplayMinutes $DisplayOffMinutes -HibernateOff:$DisableHibernate
  Set-MachineInactivityLock -IdleMinutes $eff -DoRefreshPolicy:$RefreshPolicy
  Write-Success "DisplayOff=$DisplayOffMinutes min, Lock=$eff min, Sleep/Hibernate=Never"
}

# ----------------------------- STEP 8 -------------------------------
function Set-ExecutionPolicySafe { param([string]$Policy = 'RemoteSigned')
  foreach($scope in 'LocalMachine','CurrentUser'){
    try {
      $curr = (Get-ExecutionPolicy -Scope $scope -ErrorAction SilentlyContinue)
      if ($curr -ne $Policy) { Set-ExecutionPolicy -Scope $scope -ExecutionPolicy $Policy -Force }
    } catch { Write-WarningMsg "Could not set ExecutionPolicy ($scope): $($_.Exception.Message)" }
  }
}
function Ensure-DefenderExclusions {
  $paths = @('C:\ProgramData\DRM\Provision',$MediaRoot,'C:\Tools') | Sort-Object -Unique
  if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { Write-Info "Defender cmdlets not available; skipping exclusions."; return }
  try { $pref = Get-MpPreference } catch { Write-WarningMsg "Get-MpPreference failed: $($_.Exception.Message)"; return }
  $existing = @(); if ($pref.ExclusionPath) { $existing = @($pref.ExclusionPath) }
  foreach($p in $paths){
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    if ($existing -contains $p) { Write-Info "Exclusion already present: $p" }
    else { try { Add-MpPreference -ExclusionPath $p; Write-Success "Added Defender exclusion: $p" } catch { Write-WarningMsg "Failed to add exclusion '$p': $($_.Exception.Message)" } }
  }
}
Invoke-Task -StepName "STEP8_ExecPolicy_And_Defender" -Action {
  Set-ExecutionPolicySafe -Policy 'RemoteSigned'
  Ensure-DefenderExclusions
}

# ----------------------------- STEP 9 -------------------------------
function Test-AppInstalled {
  param([string]$KeyWord)
  $roots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  [bool](Get-ItemProperty $roots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.DisplayName -like "*$KeyWord*" } | Select-Object -First 1)
}
function Invoke-InstallerItem {
  param(
    [Parameter(Mandatory)] [string]$Name,
    [string]$WingetId,
    [string]$LocalName,      # just the filename; resolved via Resolve-MediaPath
    [string]$SilentArgs,
    [switch]$Interactive,
    [string]$DetectKeyword
  )
  if ($DetectKeyword) { try { if (Test-AppInstalled -KeyWord $DetectKeyword) { Write-Info "$Name appears installed; skipping."; return } } catch {} }

  # Try winget first
  if ($WingetId) {
    try { & winget source update | Out-Null } catch {}
    Write-Info "Installing $Name via winget ($WingetId)..."
    $p = Start-Process winget -ArgumentList "install -e --id $WingetId --accept-source-agreements --accept-package-agreements --silent" -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -eq 0) { Write-Success "$Name installed via winget."; return }
    Write-WarningMsg "$Name winget install returned $($p.ExitCode); falling back to local installer."
  }

  # Local fallback
  $LocalPath = Resolve-MediaPath $LocalName
  if (-not $LocalPath) { Write-WarningMsg "$Name local file not found: $LocalName"; return }

  $ext = [IO.Path]::GetExtension($LocalPath).ToLowerInvariant()
  if (-not $Interactive) {
    if (-not $SilentArgs) {
      if ($ext -eq '.msi') { $SilentArgs = '/qn /norestart REBOOT=ReallySuppress' }
      else { $SilentArgs = '/S' }
    }
  }

  if ($ext -eq '.msi') {
    $cmd = "msiexec.exe /i `"$LocalPath`" $SilentArgs"
    Write-Info "Installing $Name from MSI: $cmd"
    $pr = Start-Process cmd.exe -ArgumentList "/c $cmd" -Wait -PassThru
  } else {
    Write-Info "Installing $Name from EXE: `"$LocalPath`" $SilentArgs"
    if ($Interactive) {
      $pr = Start-Process $LocalPath -ArgumentList $SilentArgs -PassThru
      Write-WarningMsg "$Name is running interactively. Finish the wizard, then return here."
      try { Wait-Process -Id $pr.Id } catch {}
      [void](Read-Host "Type Y to continue after finishing $Name installer")
    } else {
      $pr = Start-Process $LocalPath -ArgumentList $SilentArgs -Wait -PassThru
    }
  }
  if ($pr.ExitCode -eq 0) { Write-Success "$Name installer exited with code 0." } else { Write-WarningMsg "$Name installer exit code: $($pr.ExitCode)." }
}

Invoke-Task -StepName "STEP9_InstallAppsAndDrivers" -Action {
  # 9.1 Google Chrome
  Invoke-InstallerItem -Name "Google Chrome" `
    -WingetId "Google.Chrome" `
    -LocalName "ChromeSetup.exe" `
    -SilentArgs "/silent /install" `
    -DetectKeyword "Google Chrome"

  # 9.2 UltraVNC
  Invoke-InstallerItem -Name "UltraVNC" `
    -WingetId "UltraVNC.UltraVNC" `
    -LocalName "UltraVNC_1.0.8.2_Setup.exe" `
    -SilentArgs "/S" `
    -DetectKeyword "UltraVNC"

  # 9.3 Splashtop Streamer — interactive
  Invoke-InstallerItem -Name "Splashtop Streamer (interactive)" `
    -LocalName "Splashtop_Streamer_BOH.exe" `
    -Interactive `
    -DetectKeyword "Splashtop Streamer"

  # 9.4 FMAudit — interactive
  Invoke-InstallerItem -Name "FMAudit (interactive)" `
    -LocalName "FMAudit.Installer_1869_1806031300.exe" `
    -Interactive `
    -DetectKeyword "FMAudit"

  # 9.5 RTIconnect MSI — silent
  Invoke-InstallerItem -Name "RTIconnect" `
    -LocalName "RTIconnect_Installer (2022).msi" `
    -SilentArgs "/qn /norestart REBOOT=ReallySuppress" `
    -DetectKeyword "RTIconnect"

  # 9.6 Printer driver pack — interactive (name pattern)
  $drv = Get-ChildItem -Path $MediaRoot -Filter "V4_DriveronlyWebpack*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($drv) {
    Invoke-InstallerItem -Name "Printer Driver Pack (interactive)" -LocalName $drv.Name -Interactive -DetectKeyword "Driver"
  } else {
    Write-Info "Printer driver pack EXE not found in $MediaRoot; skipping."
  }

  # 9.7 Optional: printer setup BAT
  $bat = Resolve-MediaPath "Printer set up.bat"
  if ($bat) { Write-Info "Running printer setup batch..."; Start-Process cmd.exe -ArgumentList "/c `"$bat`"" -Wait | Out-Null; Write-Success "Printer setup batch finished." }

  # 9.8 Any extra settings*.reg beside media
  Get-ChildItem -Path $MediaRoot -Filter "settings*.reg" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Info "Importing settings REG: $($_.Name)"
    try { Start-Process reg.exe -ArgumentList @("import","$($_.FullName)") -Wait -WindowStyle Hidden | Out-Null; Write-Success "Imported $($_.Name)" }
    catch { Write-WarningMsg "Import failed for $($_.Name): $($_.Exception.Message)" }
  }
}

# ----------------------------- Summary ------------------------------
Write-Host "`n---- SUMMARY ----" -ForegroundColor White
if (Get-AppxPackage -AllUsers -Name Microsoft.ScreenSketch -ErrorAction SilentlyContinue) { Write-Success "Snipping Tool is PRESENT." } else { Write-WarningMsg "Snipping Tool appears missing." }
$mwLeft = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Teams Machine-Wide Installer*' }
if($mwLeft){ Write-WarningMsg "Teams Machine-Wide Installer still detected; consider reboot." } else { Write-Success "Teams Machine-Wide Installer not detected." }
if (Test-NewTeamsInstalled) { Write-Success "Verified: new Microsoft Teams is installed." } else { Write-WarningMsg "New Teams not detected by Appx query; verify manually." }
try { $ok = [bool](Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue) } catch { $ok = [bool](Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount=True AND Name='$AdminUser'" -ErrorAction SilentlyContinue) }
if ($ok) { Write-Success "Local admin '${AdminUser}' exists." } else { Write-WarningMsg "Local admin '${AdminUser}' not present." }
$wallDest = Join-Path 'C:\Windows\Web\Wallpaper' $WallpaperName
Write-Host ("Wallpaper: {0} ({1})" -f ($wallDest), ($(if($LockWallpaper){"LOCKED"}else{"UNLOCKED"})))
try { $tzNow = (Get-TimeZone).Id; Write-Success "Timezone: $tzNow" } catch {}
$active = & powercfg -getactivescheme 2>$null
if ($active -match 'GUID:\s*([0-9a-fA-F\-]{36})\s+\((.+)\)') { Write-Success ("Active power plan: {0} ({1})" -f $matches[2], $matches[1]) }
try { $polLM = Get-ExecutionPolicy -Scope LocalMachine -ErrorAction SilentlyContinue; $polCU = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue; Write-Success "ExecutionPolicy LM/CU: $polLM / $polCU" } catch {}
if (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) { $pref = Get-MpPreference; $paths = ($pref.ExclusionPath | Sort-Object) -join '; '; Write-Info "Defender Exclusions: $paths" }
Write-Info "MediaRoot used: $MediaRoot"
Write-Info "Log file: $LogFile"
try { Stop-Transcript | Out-Null } catch {}
