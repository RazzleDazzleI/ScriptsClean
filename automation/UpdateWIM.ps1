# Define paths
$wimFile = "C:\Image\Register.wim"
$mountDir = "C:\Mount"
$backgroundSourcePath = "C:\Update\Background\DRM_Support_background.jpg"
$backgroundDestPath = "$mountDir\Windows\Web\Wallpaper\DRM_Support_background.jpg"
$softwareHivePath = "$mountDir\Windows\System32\config\SOFTWARE"

# Mount the WIM image
Write-Output "Mounting the WIM image..."
$dismMountCommand = "dism /Mount-WIM /WimFile:`"$wimFile`" /Index:1 /MountDir:`"$mountDir`""
Invoke-Expression $dismMountCommand

# Check if the mount was successful
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to mount WIM image. Exiting script."
    exit 1
}

# Set the time zone to CST
Write-Output "Setting the time zone to CST..."
Set-TimeZone -Name 'Central Standard Time' -PassThru

# Create temp folder in the mount directory
$tempFolderPath = "$mountDir\temp"
New-Item -Path $tempFolderPath -ItemType Directory -Force | Out-Null
Write-Output "$tempFolderPath folder created..."

# Copy the new background image
Write-Output "Copying background image..."
New-Item -Path "$mountDir\Windows\Web\Wallpaper" -ItemType Directory -Force | Out-Null
Copy-Item -Path $backgroundSourcePath -Destination $backgroundDestPath -Force
Write-Output "Background image copied to $backgroundDestPath..."

# Load the SOFTWARE registry hive from the mounted WIM image
Write-Output "Loading SOFTWARE registry hive..."
$regLoadCommand = "reg load HKLM\MountedSoftware `"$softwareHivePath`""
Invoke-Expression $regLoadCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to load SOFTWARE registry hive. Exiting script."
    exit 1
}

# Add registry keys for wallpaper settings
Write-Output "Setting background registry keys..."
$wallpaperPath = "C:\Windows\Web\Wallpaper\DRM_Support_background.jpg"

# Set Wallpaper path if it does not already exist
$regCheckCommand1 = "reg query \"HKLM\MountedSoftware\Microsoft\Windows\CurrentVersion\Policies\System\" /v Wallpaper"
Invoke-Expression $regCheckCommand1
if ($LASTEXITCODE -ne 0) {
    $regAddCommand1 = "reg add \"HKLM\MountedSoftware\Microsoft\Windows\CurrentVersion\Policies\System\" /v Wallpaper /t REG_SZ /d \"$wallpaperPath\" /f"
    Invoke-Expression $regAddCommand1
}

# Set WallpaperStyle setting to 'Fit' if it does not already exist
$regCheckCommand2 = "reg query \"HKLM\MountedSoftware\Microsoft\Windows\CurrentVersion\Policies\System\" /v WallpaperStyle"
Invoke-Expression $regCheckCommand2
if ($LASTEXITCODE -ne 0) {
    $regAddCommand2 = "reg add \"HKLM\MountedSoftware\Microsoft\Windows\CurrentVersion\Policies\System\" /v WallpaperStyle /t REG_SZ /d \"6\" /f"
    Invoke-Expression $regAddCommand2
}

# Prevent users from changing the wallpaper if the setting does not already exist
$regCheckCommand3 = "reg query \"HKLM\MountedSoftware\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop\" /v NoChangingWallPaper"
Invoke-Expression $regCheckCommand3
if ($LASTEXITCODE -ne 0) {
    $regAddCommand3 = "reg add \"HKLM\MountedSoftware\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop\" /v NoChangingWallPaper /t REG_DWORD /d 1 /f"
    Invoke-Expression $regAddCommand3
}

# Unload the SOFTWARE registry hive
Write-Output "Unloading SOFTWARE registry hive..."
$regUnloadCommand = "reg unload HKLM\MountedSoftware"
Invoke-Expression $regUnloadCommand

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to unload SOFTWARE registry hive. Exiting script."
    exit 1
}

# Install new certificate
Write-Output "Installing new certificate..."
$certFilePath = "$mountDir\temp\B7AB3308D1EA4477BA1480125A6FBDA936490CBB.crt"
if (Test-Path $certFilePath) {
    Import-Certificate -FilePath $certFilePath -CertStoreLocation Cert:\LocalMachine\Root
    Write-Output "Certificate has been installed..."
} else {
    Write-Error "Certificate file not found at $certFilePath. Skipping certificate installation."
}

# FreedomPay Install - Check if ZIP file exists
$freedomPayZip = "$mountDir\Brink\FCC_5.0.11.2.zip"
if (Test-Path $freedomPayZip) {
    Write-Output "Starting FreedomPay install..."
    Expand-Archive -Force $freedomPayZip -DestinationPath "$mountDir\Brink"

    $freedomPayCommand = "$mountDir\Brink\Disk1\FreewayCommerceConnect.exe"
    $freedomPayParams = "/quiet DMP_ACTIVATION_KEY=9388a639-95d1-44dc-887c-85d4e69390ee ADDLOCAL=\"FCCClient,FCCServer,DiagnosticUtility\" /L*v fccinstall.log"
    & $freedomPayCommand $freedomPayParams.Split(" ")

    Expand-Archive -LiteralPath "$mountDir\Brink\Arbys_UPP_042021_slim.zip" -DestinationPath "$mountDir\ProgramData\FreedomPay\Freeway Commerce Connect\pal" -Force
    Move-Item -Path "$mountDir\ProgramData\FreedomPay\Freeway Commerce Connect\pal\Arbys_UPP_042021\*" -Destination "$mountDir\ProgramData\FreedomPay\Freeway Commerce Connect\pal" -Force
    Remove-Item -Path "$mountDir\ProgramData\FreedomPay\Freeway Commerce Connect\pal\Arbys_UPP_042021\" -Force

    Write-Output "FreedomPay has been installed..."
} else {
    Write-Error "FreedomPay ZIP file not found at $freedomPayZip. Skipping FreedomPay installation."
}

# Unmount the WIM image and commit changes
Write-Output "Committing changes and unmounting the image..."
$dismCommitCommand = "dism /Unmount-WIM /MountDir:`"$mountDir`" /Commit"
Invoke-Expression $dismCommitCommand

# Check if unmount was successful
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to unmount and commit changes to WIM image. Exiting script."
    exit 1
}

Write-Output "WIM image updated successfully."
