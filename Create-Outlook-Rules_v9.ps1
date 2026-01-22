$OL_FOLDER_INBOX = 6
$OL_RULE_RECEIVE = 0

function Remove-RuleIfExists { param($Rules, [string]$RuleName)
  try { for ($i = $Rules.Count; $i -ge 1; $i--) { $r = $Rules.Item($i); if ($r.Name -eq $RuleName) { $r.Delete() } } } catch {}
}

function Get-OrCreateInboxSubfolder { param($Session, [int]$InboxId, [string]$Name)
  $inbox = $Session.GetDefaultFolder($InboxId)
  foreach ($f in $inbox.Folders) { if ($f.Name -eq $Name) { return $f } }
  return $inbox.Folders.Add($Name)
}

function Set-SubjectText { param($SubjectCondition, [string[]]$Strings)
  if ($SubjectCondition.PSObject.Properties.Name -contains 'Text')    { $SubjectCondition.Text = $Strings }
  elseif ($SubjectCondition.PSObject.Properties.Name -contains 'Words'){ $SubjectCondition.Words = $Strings }
  else { throw "Neither Text nor Words exists on Subject condition." }
}

$outlook = New-Object -ComObject Outlook.Application
$session = $outlook.Session

try { $store = $session.DefaultStore; $rules = $store.GetRules() }
catch { Write-Host "ERROR: Outlook appears OFFLINE. Disable Work Offline, close Outlook, then rerun." -ForegroundColor Red; exit 1 }

$folderImportant = Get-OrCreateInboxSubfolder $session $OL_FOLDER_INBOX "1_important"

$ruleName = "To 1_important - EoD_Freshdesk_Mirus"
Remove-RuleIfExists $rules $ruleName

$rule = $rules.Create($ruleName, $OL_RULE_RECEIVE)
$subject = $rule.Conditions.Subject
$subject.Enabled = $true

# SUBJECT contains ANY of these -> move to 1_important
$words = @(
  "EoD Filter - Action Required",
  "EoD Filter - Action Required",  # keep a duplicate with normal hyphen for safety
  "[New Ticket]",
  "Ticket Assigned",
  "Summary Net Sales"
)
Set-SubjectText $subject $words

$rule.Actions.MoveToFolder.Enabled = $true
$rule.Actions.MoveToFolder.Folder  = $folderImportant
$rule.Enabled = $true

$rules.Save()
$rules = $store.GetRules()
try { $rules.Item($ruleName).ExecutionOrder = 1; $rules.Save() } catch {}
Write-Host "Done. Test by sending a mail with one of the trigger phrases in the subject." -ForegroundColor Green
