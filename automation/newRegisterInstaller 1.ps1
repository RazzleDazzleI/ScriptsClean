# Set the time to CST
Set-TimeZone -Name 'Central Standard Time' -PassThru
Write-Output "Timezone set to CST..."

# Create temp folder in C drive
#New-Item -Path "C:\" -name "temp" -ItemType Directory
#Write-Output "C:\temp folder created..."

# Get letter of drive associated with USB
#$usbDrive = gwmi win32_diskdrive | ?{$_.interfacetype -eq "USB"} | %{gwmi -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($_.DeviceID.replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition"} |  %{gwmi -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($_.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition"} | %{$_.deviceid}

# Create paths
#$brinkFolder = $usbDrive + "\Register_Setup\BrinkFolderItems\*"
#$tempFolder = $usbDrive + "\Register_Setup\tempFolderItems\*"

# Move items from USB to Brink folder
#Copy-Item -Path $brinkFolder -Destination "C:\Brink" -Recurse
#Write-Output "Copying items to C:\Brink folder..."

# Move items from USB to temp folder
#Copy-Item -Path $tempFolder -Destination "C:\temp" -Recurse
#Write-Output "Copying items to C:\temp folder..."


#----------------------------------------Background Change-----------------------------------
Write-Output "Setting new background..."

# Change Background to DRM Support
# Clear old background info
Get-Item -Path 'HKCU:\Control Panel\Desktop' | Remove-ItemProperty -Name Wallpaper -Force
Get-Item -Path 'HKCU:\Control Panel\Desktop' | Remove-ItemProperty -Name WallpaperStyle -Force

# Set variables to indicate value and key to set
$Desktop = 'HKCU:\Control Panel\Desktop'
$Wallpaper = 'Wallpaper'
$Background = 'C:\temp\DRM_Support_background.jpg'

# Create the key if it does not exist
If (-NOT (Test-Path $Desktop)) {
  New-Item -Path $Desktop -Force | Out-Null
  Write-Output "Wallpaper key did not exist in Control Panel\Desktop"
}  

# Now set the value
New-ItemProperty -Path $Desktop -Name $Wallpaper -Value $Background -PropertyType String -Force

# Set variables to indicate value and key to set
$Style = 'WallpaperStyle'
$Fit = '3'

# Now set the value
New-ItemProperty -Path $Desktop -Name $Style -Value $Fit -Force 

$System = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
# Create the key if it does not exist
If (-NOT (Test-Path $System)) {
  New-Item -Path $System -Force | Out-Null
  Write-Output "System key does not exist, creating key..."
} 

Start-Sleep -s 5

# Set variables to indicate value and key to set
$Name = 'Picture'

# Now set the value
New-ItemProperty -Path $System -Name $Name -Value $Background -PropertyType String -Force 

# Set variables to indicate value and key to set
$Style = 'Style'

# Now set the value
New-ItemProperty -Path $System -Name $Style -Value $Fit -Force 

Start-Sleep -s 5

# Restart Windows Explorer
stop-process -name explorer -force

# Display keys
Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop'

Write-Output "Background keys changed/created..."


#----------------------------------------New Cert Install------------------------------------

# Install new cert
Write-Output "Adding new cert..."
# Full path of the file
$file = "C:\temp\B7AB3308D1EA4477BA1480125A6FBDA936490CBB.crt"

# Import new cert
Import-Certificate -FilePath $file -CertStoreLocation Cert:\LocalMachine\Root

# Test filepath
Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object {$_.Thumbprint -eq "FF95E7706B770B38AD8D8EABE014061F69A86800"}

Start-Sleep -s 10

Write-Output "New cert has been added..."

#----------------------------------------IT Folder---------------------------------------

# Move items to the IT folder
#Move-Item -Path "C:\Users\RDS\Desktop\Brink_TermCFG.exe" -Destination "C:\Users\RDS\Desktop\IT Folder"
Move-Item -Path "C:\Users\RDS\Desktop\Brink POS Register.exe" -Destination "C:\Users\RDS\Desktop\IT Folder"
Move-Item -Path "C:\Users\RDS\Desktop\UareUSample*.lnk" -Destination "C:\Users\RDS\Desktop\IT Folder"

# Create new Brink IP config shortcut to desktop
$ShortcutPath = "C:\users\RDS\desktop\reg_Reconfig.lnk"
$IconLocation = "C:\windows\System32\SHELL32.dll"
$IconArrayIndex = 27
$Shell = New-Object -ComObject ("WScript.Shell")
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = "C:\temp\reconfigReg.cmd"
$Shortcut.IconLocation = "$IconLocation, $IconArrayIndex"
$Shortcut.Save()

$bytes = [System.IO.File]::ReadAllBytes("C:\users\RDS\desktop\reg_Reconfig.lnk")
$bytes[0x15] = $bytes[0x15] -bor 0x20 #set byte 21 (0x15) bit 6 (0x20) ON
[System.IO.File]::WriteAllBytes("C:\users\RDS\desktop\reg_Reconfig.lnk", $bytes)


#-----------------------------------------FreedomPay Install--------------------------------

# Install FreedomPay
Write-Output "Starting FreedomPay install..."

# Unzip the FCC zip folder into Brink folder
Expand-Archive -Force "C:\Brink\FCC_5.0.11.2.zip" "C:\Brink"

$Command = "C:\Brink\Disk1\FreewayCommerceConnect.exe"
$Parms = "/quiet DMP_ACTIVATION_KEY=9388a639-95d1-44dc-887c-85d4e69390ee ADDLOCAL=""FCCClient,FCCServer,DiagnosticUtility"" /L*v fccinstall.log"

# Quiet install FreedomPay
$Prms = $Parms.Split(" ")
& "$Command" $Prms

# Unzip the UPP zip folder into the Freedompay pal folder
Expand-Archive -LiteralPath "C:\Brink\Arbys_UPP_042021_slim.zip" -DestinationPath "C:\ProgramData\FreedomPay\Freeway Commerce Connect\pal" -Force

# Move zip files to normal folder
Move-Item -Path "C:\ProgramData\FreedomPay\Freeway Commerce Connect\pal\Arbys_UPP_042021\*" -Destination "C:\ProgramData\FreedomPay\Freeway Commerce Connect\pal"

Start-Sleep -s 45

# Remove the empty folder
Remove-Item -Path "C:\ProgramData\FreedomPay\Freeway Commerce Connect\pal\Arbys_UPP_042021\" -Force


Write-Output "FreedomPay has been installed..."

Start-Sleep -s 10

# Start Freedompay services
sc.exe config "FCCClientSvc" start= auto
sc.exe config "FCCServerSvc" start= auto

# Check if services were added successfully
$success = $false
$counter = 0
do
{
	$service = Get-Service -Name "FCC*"
	if (($service.Length -lt 1) -and ($counter -lt 5))
	{
		Write-Output "No service found. Trying again..."
		sc.exe config "FCCClientSvc" start= auto
		sc.exe config "FCCServerSvc" start= auto
		Start-Sleep -s 10
		$counter++
	}
	else
	{
		$success = $true
	}
} while (!($success))

# Let user know the services did not start
if ($counter -eq 5)
{
	Write-Output "Service not started ... Try starting the services manually!"
	Start-Sleep -s 15
}

#-----------------------------------------Restart----------------------------------------
Write-Output "Restarting register in 10 seconds..."
Start-Sleep -s 10

# Restart computer
Restart-Computer