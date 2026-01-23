<# Enable-WU-PSWU_v2.ps1
   For Splashtop 1-to-Many (Run as SYSTEM or Admin)

   Changes from v1:
   - Fixed module install scope (AllUsers for SYSTEM context)
   - Added retry loop for SoftwareDistribution rename
   - Added -NotTitle filter for firmware alongside -NotCategory Drivers
   - Better detection of running context (SYSTEM vs Admin)
   - Improved logging

   Features:
   - Unblocks Windows Update (clears WSUS/local blocks)
   - Ensures PSWindowsUpdate (TLS/NuGet/PSGallery)
   - Installs updates, skipping drivers and firmware
   - Fallback to native USO if module path fails
   - Logs to C:\Logs and returns 0 / 3010 / 1
#>

param(
  [switch]$AutoReboot = $true,             # set to $false to stage only
  [string]$LogDir     = 'C:\Logs',
  [switch]$IncludeDrivers = $false,        # set to $true to include driver updates
  [int]$MaxRetries    = 3                  # retry count for operations
)

# Ensure log directory exists
New-Item $LogDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

Start-Transcript -Path ("$LogDir\WU_{0:yyyyMMdd_HHmm}.log" -f (Get-Date)) -ErrorAction SilentlyContinue | Out-Null
$ErrorActionPreference = 'Stop'
$exit = 0

# Detect if running as SYSTEM
function Test-RunningAsSystem {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentUser.User.Value -eq 'S-1-5-18'
}

$isSystem = Test-RunningAsSystem
Write-Host "[i] Running as: $(if($isSystem){'SYSTEM'}else{'Administrator'})" -ForegroundColor Cyan

function Allow-WU {
    param([int]$RetryCount = 3)

    $wuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    New-Item $wuKey -Force -ErrorAction SilentlyContinue | Out-Null

    # Clear WSUS + blocks
    Remove-Item "$wuKey\AU" -Recurse -Force -ErrorAction SilentlyContinue
    foreach($n in 'WUServer','WUStatusServer','DisableWindowsUpdateAccess','DoNotConnectToWindowsUpdateInternetLocations'){
        Remove-ItemProperty -Path $wuKey -Name $n -Force -ErrorAction SilentlyContinue
    }

    # Enforce "no drivers via WU" policy (works even if we fall back to USO)
    New-ItemProperty -Path $wuKey -Name ExcludeWUDriversInQualityUpdate -Type DWord -Value 1 -Force | Out-Null

    # Services setup
    Set-Service wuauserv -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service bits     -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service cryptsvc -StartupType Automatic -ErrorAction SilentlyContinue

    # Stop services and rename SoftwareDistribution with retry
    $sdPath = "$env:SystemRoot\SoftwareDistribution"
    $sdOldPath = "$env:SystemRoot\SoftwareDistribution.old"

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            Stop-Service bits -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2

            # Remove old backup if exists
            if (Test-Path $sdOldPath) {
                Remove-Item $sdOldPath -Recurse -Force -ErrorAction SilentlyContinue
            }

            # Rename current folder
            if (Test-Path $sdPath) {
                Rename-Item $sdPath 'SoftwareDistribution.old' -ErrorAction Stop
                Write-Host "[i] SoftwareDistribution folder renamed on attempt $attempt" -ForegroundColor Green
            }
            break
        }
        catch {
            Write-Host "[!] Attempt $attempt to rename SoftwareDistribution failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds 5
            }
        }
    }

    # Start services
    Start-Service cryptsvc -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
}

function Reboot-Needed {
    $rk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    return (Test-Path $rk)
}

function Get-ModuleScope {
    # Use AllUsers scope when running as SYSTEM, CurrentUser otherwise
    if ($isSystem) {
        return 'AllUsers'
    }
    return 'CurrentUser'
}

try {
    Allow-WU -RetryCount $MaxRetries

    # Try the PSWindowsUpdate path (preferred)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $moduleScope = Get-ModuleScope
    Write-Host "[i] Module installation scope: $moduleScope" -ForegroundColor Cyan

    # Install NuGet provider
    $nuget = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue | Where-Object Name -eq 'NuGet'
    if (-not $nuget) {
        Write-Host "[i] Installing NuGet provider..." -ForegroundColor Cyan
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $moduleScope -Force
    }

    # Ensure PSGallery is registered and trusted
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $repo) {
        Register-PSRepository -Default -ErrorAction SilentlyContinue
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

    # Install PSWindowsUpdate module
    if (-not (Get-Module PSWindowsUpdate -ListAvailable)) {
        Write-Host "[i] Installing PSWindowsUpdate module (Scope: $moduleScope)..." -ForegroundColor Cyan
        Install-Module PSWindowsUpdate -Scope $moduleScope -Force -AllowClobber
    }
    Import-Module PSWindowsUpdate -ErrorAction Stop

    # Preview (goes to log)
    Write-Host "[i] Getting available updates..." -ForegroundColor Cyan
    Get-WindowsUpdate -MicrosoftUpdate -IgnoreUserInput -Verbose *>&1 | Tee-Object -FilePath "$LogDir\preview.log"

    # Build install parameters
    $params = @{
        AcceptAll       = $true
        MicrosoftUpdate = $true
        Verbose         = $true
    }

    # Exclude drivers and firmware unless explicitly included
    if (-not $IncludeDrivers) {
        $params['NotCategory'] = @('Drivers')
        $params['NotTitle'] = @('firmware', 'BIOS')
        Write-Host "[i] Excluding: Drivers, Firmware, BIOS updates" -ForegroundColor Yellow
    }

    if ($AutoReboot) { $params['AutoReboot'] = $true }

    # Install updates
    Write-Host "[i] Installing updates..." -ForegroundColor Cyan
    Install-WindowsUpdate @params *>&1 | Tee-Object -FilePath "$LogDir\install.log" -Append

    if ($AutoReboot -or (Reboot-Needed)) { $exit = 3010 }
}
catch {
    Write-Host "[!] PSWindowsUpdate path failed: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "[i] Falling back to native USO client (drivers are already excluded by policy)..." -ForegroundColor Cyan

    try {
        Write-Host "[i] Starting scan..." -ForegroundColor Cyan
        & UsoClient StartScan
        Start-Sleep -Seconds 25

        Write-Host "[i] Starting download..." -ForegroundColor Cyan
        & UsoClient StartDownload
        Start-Sleep -Seconds 10

        Write-Host "[i] Starting install..." -ForegroundColor Cyan
        & UsoClient StartInstall

        if ($AutoReboot) {
            Write-Host "[i] Requesting restart..." -ForegroundColor Cyan
            & UsoClient RestartDevice
        }

        if ($AutoReboot -or (Reboot-Needed)) { $exit = 3010 }
    }
    catch {
        Write-Host "[x] Native path failed: $($_.Exception.Message)" -ForegroundColor Red
        $exit = 1
    }
}
finally {
    Write-Host "[i] Script completed with exit code: $exit" -ForegroundColor Cyan
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    exit $exit
}
