# Create-Consolidated-Rules.ps1
# Creates small, server-side friendly rules without deleting existing ones.
# You can run multiple times; same-named rules are replaced.

$OL_FOLDER_INBOX = 6
$OL_RULE_RECEIVE = 0

function Remove-RuleIfExists { param($Rules,[string]$Name)
  try { for($i=$Rules.Count;$i -ge 1;$i--){$r=$Rules.Item($i); if($r.Name -eq $Name){$r.Delete()}} } catch {}
}
function Get-OrCreateInboxSubfolder { param($Session,[int]$InboxId,[string]$Name)
  $inbox=$Session.GetDefaultFolder($InboxId)
  foreach($f in $inbox.Folders){ if($f.Name -eq $Name){return $f} }; $inbox.Folders.Add($Name)
}
function Set-SubjectText { param($Cond,[string[]]$Words)
  if($Cond.PSObject.Properties.Name -contains 'Text'){ $Cond.Text = $Words }
  elseif($Cond.PSObject.Properties.Name -contains 'Words'){ $Cond.Words = $Words }
  else{ throw "No Text/Words on Subject condition" }
}

$outlook = New-Object -ComObject Outlook.Application
$session = $outlook.Session
try { $store = $session.DefaultStore; $rules = $store.GetRules() }
catch { Write-Host "Outlook is offline. Disable Work Offline, close Outlook, rerun." -ForegroundColor Red; exit 1 }

# Folders (created if missing)
$folderImportant = Get-OrCreateInboxSubfolder $session $OL_FOLDER_INBOX "1_IMPORTANT"
$folderDMARC     = Get-OrCreateInboxSubfolder $session $OL_FOLDER_INBOX "DMARC Reports"
$folderMimecast  = Get-OrCreateInboxSubfolder $session $OL_FOLDER_INBOX "Mimecast Reports"

# 1) Accountability: single subject-OR rule to 1_IMPORTANT
$name1 = "To 1_IMPORTANT - EoD_Freshdesk_Mirus"
Remove-RuleIfExists $rules $name1
$r1 = $rules.Create($name1,$OL_RULE_RECEIVE)
$subj = $r1.Conditions.Subject; $subj.Enabled = $true
Set-SubjectText $subj @("EoD Filter - Action Required","[New Ticket]","Ticket Assigned","Summary Net Sales")
$r1.Actions.MoveToFolder.Enabled = $true
$r1.Actions.MoveToFolder.Folder  = $folderImportant
$r1.Enabled = $true

# 2) DMARC reports -> DMARC Reports (sender address contains strings)
$name2 = "DMARC Reports (merge)"
Remove-RuleIfExists $rules $name2
$r2 = $rules.Create($name2,$OL_RULE_RECEIVE)
$r2.Conditions.SenderAddress.Enabled = $true
$r2.Conditions.SenderAddress.Address = @("dmarcreport@microsoft.com","dmarc.yahoo.com")
$r2.Actions.MoveToFolder.Enabled = $true
$r2.Actions.MoveToFolder.Folder  = $folderDMARC
if ($r2.PSObject.Properties.Name -contains 'StopProcessingRule') { $r2.StopProcessingRule = $true }
$r2.Enabled = $true

# 3) Mimecast -> Mimecast Reports
$name3 = "Mimecast Reports (merge)"
Remove-RuleIfExists $rules $name3
$r3 = $rules.Create($name3,$OL_RULE_RECEIVE)
$r3.Conditions.SenderAddress.Enabled = $true
$r3.Conditions.SenderAddress.Address = @("mimecastreport.com","mimecast.com")
$r3.Actions.MoveToFolder.Enabled = $true
$r3.Actions.MoveToFolder.Folder  = $folderMimecast
$r3.Enabled = $true

$rules.Save()

# Try to move consolidated rules to the top
$rules = $store.GetRules()
$desired = @($name1,$name2,$name3)
[int]$ord = 1
for($i=1; $i -le $rules.Count; $i++){
  $r = $rules.Item($i)
  if($desired -contains $r.Name){ try{$r.ExecutionOrder=$ord}catch{}; $ord++ }
}
$rules.Save()

Write-Host "Created consolidated rules without deleting old ones. Review order in Rules & Alerts." -ForegroundColor Green
