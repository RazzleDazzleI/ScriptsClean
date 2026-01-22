# Define your base scripts directory
$basePath = "C:\Scripts"

# List of folders to update
$folders = @("networking", "automation", "logging", "web", "archive", "misc")

foreach ($folder in $folders) {
    $folderPath = Join-Path $basePath $folder
    $readmePath = Join-Path $folderPath "README.md"

    if (-Not (Test-Path $readmePath)) {
        Write-Host "Skipped: No README.md found in $folder"
        continue
    }

    # Get only files (excluding README.md itself)
    $scriptFiles = Get-ChildItem -Path $folderPath -File |
        Where-Object { $_.Name -ne "README.md" }

    # Build the script list markdown
    $scriptList = "## Scripts in this folder:`n"
    foreach ($file in $scriptFiles) {
        $scriptList += "- `$($file.Name)`n"
    }

    # Read the original first line of the README
    $originalContent = Get-Content $readmePath | Select-Object -First 1

    # Combine original description with new file list
    $finalContent = $originalContent + "`n`n" + $scriptList.Trim()

    # Write updated content
    Set-Content -Path $readmePath -Value $finalContent -Force

    Write-Host "Updated: $readmePath"
}
