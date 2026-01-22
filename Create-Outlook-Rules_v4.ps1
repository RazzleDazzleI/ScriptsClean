<# 
Create-Outlook-Rules_v6.ps1  (resilient, late-bound COM)
- Uses .Text for Subject condition (falls back to .Words if present)
- Checks for property existence before setting (avoids COM model variance)
- Moves actionable emails to Inbox\1_important (server-side)
- Adds client-only formatting for EoD if supported; otherwise applies a Category as fallback

Run:
  1) In Outlook, ensure you're ONLINE (Send/Receive -> Work Offline NOT selected).
  2) Close Outlook.
  3) powershell -ExecutionPolicy Bypass -File .\Create-Outlook-Rules_v6.ps1
#>

$OL_FOLDER_INBOX     = 6      # OlDefaultFolders.olFolderInbox
$OL_RULE_RECEIVE     = 0      # OlRuleType.olRuleReceive
$OL_IMPORTANCE_HIGH  = 2      # OlImportance.olImportanceHigh
$OL_MARK_TODAY       = 0      # OlMarkInterval.olMarkToday

function Remove-RuleIfExists {
  param($Rules, [string]$RuleName)
  try {
    for ($i = $Rules.Count; $i -ge 1; $i--) {
      $r = $Rules.Item($i)
      if ($r.Name -eq $RuleName) { $r.Delete() }
    }
  } catch {}
}

function Get-OrCreateInboxSubfolder {
  param($Session, [int]$InboxId, [string]$Name)
  $inbox = $Session.GetDefaultFolder($InboxId)
  foreach ($f in $inbox.Folders) { if ($f.Name -eq $Name) { return $f } }
  return $inbox.Folders.Add($Name)
}

function Set-SubjectText {
  param($SubjectCondition, [string[]]$Strings)
  if ($null -eq $SubjectCondition) { throw "Subject condition is null" }
  if ($SubjectCondition.PSObject.Properties.Name -contains 'Text') {
    $SubjectCondition.Text = $Strings
  } elseif ($SubjectCondition.PSObject.Properties.Name -contains 'Words') {
    $SubjectCondition.Words = $Strings
  } else {
    throw "Neither 'Text' nor 'Words' property exists on Subject condition."
  }
}

function New-SubjectMoveRule {
  param($Rules, [string]$RuleName, [string[]]$SubjectWords, $TargetFolder, [switch]$StopProcessing)
  Remove-RuleIfExists $Rules $RuleName
  $rule = $Rules.Create($RuleName, $OL_RULE_RECEIVE)
  $subj = $rule.Conditions.Subject
  $subj.Enabled = $true
  Set-SubjectText -SubjectCondition $subj -Strings $SubjectWords
  $rule.Actions.MoveToFolder.Enabled = $true
  $rule.Actions.MoveToFolder.Folder  = $TargetFolder
  if ($rule.PSObject.Properties.Name -contains 'StopProcessingRule') {
    $rule.StopProcessingRule = [bool]$StopProcessing
  }
  $rule.Enabled = $true
  return $rule
}

function New-FromMoveRule {
  param($Rules, [string]$RuleName, [string[]]$Senders, $TargetFolder, [switch]$StopProcessing)
  Remove-RuleIfExists $Rules $RuleName
  $rule = $Rules.Create($RuleName, $OL_RULE_RECEIVE)
  $rule.Conditions.From.Enabled = $true
  $recips = $rule.Conditions.From.Recipients
  foreach ($s in $Senders) { $null = $recips.Add($s) }
  $null = $recips.ResolveAll()
  $rule.Actions.MoveToFolder.Enabled = $true
  $rule.Actions.MoveToFolder.Folder  = $TargetFolder
  if ($rule.PSObject.Properties.Name -contains 'StopProcessingRule') {
    $rule.StopProcessingRule = [bool]$StopProcessing
  }
  $rule.Enabled = $true
  return $rule
}

function New-ClientFormattingRule {
  param($Rules, [string]$RuleName, [string[]]$SubjectWords)
  Remove-RuleIfExists $Rules $RuleName
  $rule = $Rules.Create($RuleName, $OL_RULE_RECEIVE)
  $subj = $rule.Conditions.Subject
  $subj.Enabled = $true
  Set-SubjectText -SubjectCondition $subj -Strings $SubjectWords

  $didAny = $false
  if ($rule.Actions.PSObject.Properties.Name -contains 'MarkImportance') {
    $rule.Actions.MarkImportance.Enabled    = $true
    $rule.Actions.MarkImportance.Importance = $OL_IMPORTANCE_HIGH
    $didAny = $true
  }
  if ($rule.Actions.PSObject.Properties.Name -contains 'MarkAsTask') {
    $rule.Actions.MarkAsTask.Enabled      = $true
    $rule.Actions.MarkAsTask.MarkInterval = $OL_MARK_TODAY
    $didAny = $true
  }
  # Fallback: apply Category "EoD" if above actions aren't available
  if (-not $didAny -and $rule.Actions.PSObject.Properties.Name -contains 'AssignToCategory') {
    $rule.Actions.AssignToCategory.Enabled = $true
    $rule.Actions.AssignToCategory.Categories = @("EoD")
    $didAny = $true
  }
  if (-not $didAny) {
    Write-Warning "No client-only formatting actions available; rule created but does not add flags/importance."
  }
  $rule.Enabled = $true
  return $rule
}

Write-Host "Launching Outlook COM..." -ForegroundColor Cyan
$outlook = New-Object -ComObject Outlook.Application
$session = $outlook.Session

try {
  $store = $session.DefaultStore
  $rules = $store.GetRules()
} catch {
  Write-Host "`nERROR: Outlook appears OFFLINE. In Outlook: disable 'Work Offline' so it says 'Connected', then close Outlook and rerun." -ForegroundColor Red
  exit 1
}

# Ensure folders
$folderImportant   = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "1_important"
$folderTrend       = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "Trend Reports"
$folderAcrelec     = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "Acrelec Reports"
$folderMirus       = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "Mirus Reports"
$folderDMARC       = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "DMARC Reports"
$folderMimecast    = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "Mimecast Reports"
$folderMiscNoReply = Get-OrCreateInboxSubfolder -Session $session -InboxId $OL_FOLDER_INBOX -Name "Misc NoReply"

Write-Host "Creating rules..." -ForegroundColor Cyan

$eodSubjects = @("EoD Filter - Action Required","EoD Filter – Action Required")
$r1  = New-SubjectMoveRule     -Rules $rules -RuleName "EoD Filter – Action Required (MOVE)" -SubjectWords $eodSubjects -TargetFolder $folderImportant
$r1b = New-ClientFormattingRule -Rules $rules -RuleName "EoD – Client Formatting (Flag + High Importance)" -SubjectWords $eodSubjects

$rFD_From = New-FromMoveRule    -Rules $rules -RuleName "Freshdesk Tickets FROM (MOVE to 1_important)" `
             -Senders @("support@drm-help.freshdesk.com","noreply@freshdesk.com","support@freshdesk.com","helpdesk@freshdesk.com","support@drmhelpdesk.com") `
             -TargetFolder $folderImportant
$rFD_Subj = New-SubjectMoveRule -Rules $rules -RuleName "Freshdesk Tickets SUBJECT (MOVE to 1_important)" `
             -SubjectWords @("[New Ticket]","Ticket Assigned","Ticket Reopened","Ticket Updated","Overdue","Due Today","Escalated") `
             -TargetFolder $folderImportant

$rMirus_From = New-FromMoveRule    -Rules $rules -RuleName "Mirus Alerts (MOVE to 1_important)" `
                 -Senders @("alerts@mirus.com","no-reply@mirus.com") `
                 -TargetFolder $folderImportant
$rMirus_Subj = New-SubjectMoveRule -Rules $rules -RuleName "Mirus Summary Net Sales (MOVE to 1_important)" `
                 -SubjectWords @("Summary Net Sales","Net Sales Summary") `
                 -TargetFolder $folderImportant

$r2 = New-SubjectMoveRule -Rules $rules -RuleName "Timers Not Reporting Trend (MOVE)" `
        -SubjectWords @("Timers Not Reporting","Not Reporting Trend") -TargetFolder $folderTrend -StopProcessing
$r3 = New-SubjectMoveRule -Rules $rules -RuleName "Acrelec Reports (MOVE)" `
        -SubjectWords @("Acrelec","Acrelec Report","Acrelec Reports") -TargetFolder $folderAcrelec -StopProcessing
$r4 = New-SubjectMoveRule -Rules $rules -RuleName "Mirus Reports (MOVE)" `
        -SubjectWords @("Mirus","Mirus Report","Mirus Reports") -TargetFolder $folderMirus -StopProcessing
$r5 = New-SubjectMoveRule -Rules $rules -RuleName "DMARC Aggregate Report (MOVE)" `
        -SubjectWords @("DMARC Aggregate Report","Aggregate report for") -TargetFolder $folderDMARC -StopProcessing
$r6 = New-FromMoveRule    -Rules $rules -RuleName "Mimecast Reports (MOVE)" `
        -Senders @("NO-REPLY@US-4.MIMECASTREPORT.COM","no-reply@mimecast.com") -TargetFolder $folderMimecast
$r7 = New-FromMoveRule    -Rules $rules -RuleName "NoReply senders to Misc (MOVE) [Disabled]" `
        -Senders @("noreply@","no-reply@","donotreply@") -TargetFolder $folderMiscNoReply
# attempt to disable if property exists
try { $r7.Enabled = $false } catch { }

$rules.Save()
$rules = $store.GetRules()

$desiredOrder = @(
  "EoD Filter – Action Required (MOVE)",
  "EoD – Client Formatting (Flag + High Importance)",
  "Freshdesk Tickets FROM (MOVE to 1_important)",
  "Freshdesk Tickets SUBJECT (MOVE to 1_important)",
  "Mirus Alerts (MOVE to 1_important)",
  "Mirus Summary Net Sales (MOVE to 1_important)",
  "Timers Not Reporting Trend (MOVE)",
  "Acrelec Reports (MOVE)",
  "Mirus Reports (MOVE)",
  "DMARC Aggregate Report (MOVE)",
  "Mimecast Reports (MOVE)",
  "NoReply senders to Misc (MOVE) [Disabled]"
)

[int]$order = 1
for ($i = 1; $i -le $rules.Count; $i++) {
  $r = $rules.Item($i)
  if ($desiredOrder -contains $r.Name) {
    try { $r.ExecutionOrder = $order } catch {}
    $order++
  }
}
$rules.Save()

Write-Host "`nDone. Actionable mail should land in '1_important'. Test by sending yourself a sample with 'EoD Filter - Action Required' in the subject." -ForegroundColor Green
