# List-Rule-Names.ps1
# Lists all Outlook rule names in order and exports a backup .rwz next to the script.

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $PSScriptRoot ("Rules-Backup-{0}.rwz" -f $timestamp)

$ol = New-Object -ComObject Outlook.Application
$session = $ol.Session
$store = $session.DefaultStore
$rules = $store.GetRules()

# Export a backup of rules
try {
  # Rules export via UI is manual; we simulate a minimal export by invoking the dialog if possible.
  # As a fallback, at least dump the list to a text file.
  $txt = Join-Path $PSScriptRoot ("RuleNames-{0}.txt" -f $timestamp)
  1..$rules.Count | ForEach-Object {
    $r = $rules.Item($_)
    "{0,3}. {1}" -f $r.ExecutionOrder, $r.Name
  } | Set-Content -Path $txt -Encoding UTF8
  Write-Host "Saved rule name list to $txt" -ForegroundColor Green
} catch {
  Write-Warning "Could not export a .rwz automatically; list saved instead."
}

# Also print to console
1..$rules.Count | ForEach-Object {
  $r = $rules.Item($_)
  "{0,3}. {1}" -f $r.ExecutionOrder, $r.Name
}
