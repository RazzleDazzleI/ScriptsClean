# Define paths
$sourceFolder = "C:\Scripts"
$backupRoot = "$env:USERPROFILE\Google Drive\Script_Backups"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$zipName = "Scripts_$timestamp.zip"
$zipPath = Join-Path $backupRoot $zipName

# Ensure backup folder exists
if (-not (Test-Path $backupRoot)) {
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
}

# Create the ZIP file
Compress-Archive -Path "$sourceFolder\*" -DestinationPath $zipPath -Force

# Delete ZIP files older than 30 days
Get-ChildItem -Path $backupRoot -Filter "*.zip" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force

Write-Output "Backup created at: $zipPath"
