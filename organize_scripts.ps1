# Set root folder
$root = "C:\Scripts"

# Define categories and matching patterns
$rules = @{
    "networking"  = @("BrinkTerm*", "get_icon_path.py")
    "automation"  = @("backup_scripts.ps1", "UpdateWIM.ps1", "newRegisterInstaller*.ps1", "upgrade_aks.sh")
    "logging"     = @("import_requests.py", "youtube_transcript_collector.py", "transcripts*", "school.txt", "channel_transcripts*")
    "archive"     = @("*.zip", "*.spec", "*.ico", "CONFIG*", "brinkterm.ico", "brinkterm_transparent.ico")
    "web"         = @("*.html", "*.css")
    "misc"        = @("*.txt", "Portalcost", "import.py", "import requests.py", "BrinkTerm.cs", "BrinkTerm", "Untitled-1.css")
}

# Create folders if they don't exist
foreach ($folder in $rules.Keys) {
    $path = Join-Path $root $folder
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory | Out-Null
    }
}

# Move files into folders
foreach ($category in $rules.Keys) {
    foreach ($pattern in $rules[$category]) {
        Get-ChildItem -Path $root -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
            $target = Join-Path $root $category
            Move-Item -Path $_.FullName -Destination $target -Force
        }
    }
}

Write-Host "📁 Files have been organized into folders under C:\Scripts"
