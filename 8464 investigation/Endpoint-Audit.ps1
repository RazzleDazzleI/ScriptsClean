<#
.SYNOPSIS
  Endpoint audit for recurring "Computer Offline" alerts (e.g. Splashtop).

.DESCRIPTION
  Collects system, service, power, network, and event log info into a single
  text file for root-cause analysis.
#>

param(
    # How many days back to look in Event Logs
    [int]$DaysBack = 3,

    # Output folder for the report
    [string]$OutputFolder = "C:\Temp"
)

# Ensure output folder exists
if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$timeStamp   = Get-Date -Format "yyyyMMdd_HHmmss"
$computer    = $env:COMPUTERNAME
$reportFile  = Join-Path $OutputFolder "$computer-EndpointAudit-$timeStamp.txt"
$since       = (Get-Date).AddDays(-$DaysBack)

Write-Host "Writing report to: $reportFile"

function Write-Section {
    param(
        [Parameter(Mandatory = $true)][string]$Title
    )
    "============================================================" | Out-File -FilePath $reportFile -Append
    "=== $Title" | Out-File -FilePath $reportFile -Append
    "============================================================" | Out-File -FilePath $reportFile -Append
}

# 1. Basic system info / uptime
Write-Section "System Info & Uptime"

$os = Get-CimInstance Win32_OperatingSystem
$lastBoot = $os.LastBootUpTime
$uptime = (Get-Date) - [datetime]$lastBoot

@(
    "Computer Name : $computer"
    "User          : $env:USERNAME"
    "OS            : $($os.Caption) ($($os.Version))"
    "Last Boot     : $lastBoot"
    "Uptime (d:hh:mm) : {0:dd}:{0:hh}:{0:mm}" -f $uptime
) | Out-File -FilePath $reportFile -Append

"" | Out-File -FilePath $reportFile -Append

# 2. Splashtop services status
Write-Section "Splashtop Services Status"

try {
    $splashtopServices = Get-Service | Where-Object { $_.DisplayName -like "*Splashtop*" -or $_.Name -like "*Splashtop*" }
    if ($splashtopServices) {
        $splashtopServices |
            Select-Object Name, DisplayName, Status, StartType |
            Format-Table -AutoSize | Out-String |
            Out-File -FilePath $reportFile -Append
    } else {
        "No services matching '*Splashtop*' were found." | Out-File -FilePath $reportFile -Append
    }
} catch {
    "Error getting Splashtop services: $_" | Out-File -FilePath $reportFile -Append
}

"" | Out-File -FilePath $reportFile -Append

# 3. Power configuration (sleep / hibernate / etc.)
Write-Section "Power Configuration"

"powercfg /a" | Out-File -FilePath $reportFile -Append
powercfg /a 2>&1 | Out-File -FilePath $reportFile -Append

"`n----- powercfg /Q (truncated to most common settings) -----" | Out-File -FilePath $reportFile -Append
# This can get huge; we filter to sleep / hibernate related GUIDs
powercfg /Q 2>&1 |
    Select-String -Pattern "SLEEP", "HIBERNATE", "LID", "IDLE", "TURN OFF" |
    Out-File -FilePath $reportFile -Append

"" | Out-File -FilePath $reportFile -Append

# 4. Event Logs: shutdowns, reboots, crashes, Splashtop issues
Write-Section "Event Logs (System) - Shutdown / Reboot / Power Issues"

# Common IDs:
# 41   - Kernel-Power (unexpected shutdown)
# 1074 - Planned shutdown/restart (user or process)
# 6005 - Event log service started
# 6006 - Event log service stopped
# 6008 - Unexpected shutdown
$systemEventsFilter = @{
    LogName      = 'System'
    Id           = 41, 1074, 6005, 6006, 6008
    StartTime    = $since
}

try {
    $systemEvents = Get-WinEvent -FilterHashtable $systemEventsFilter -ErrorAction Stop |
                    Sort-Object TimeCreated

    if ($systemEvents) {
        $systemEvents |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Format-List |
            Out-File -FilePath $reportFile -Append
    } else {
        "No matching System events since $since." | Out-File -FilePath $reportFile -Append
    }
} catch {
    "Error querying System events: $_" | Out-File -FilePath $reportFile -Append
}

"" | Out-File -FilePath $reportFile -Append

Write-Section "Event Logs (System) - Network Adapter / TCPIP Issues"

# Network-related System events (e.g., adapter disconnects)
$netEventsFilter = @{
    LogName   = 'System'
    ProviderName = 'Tcpip', 'NetBT', 'Netlogon', 'NDIS', 'e1cexpress', 'e1iexpress', 'Netwtw06'
    StartTime = $since
}

try {
    $netEvents = Get-WinEvent -FilterHashtable $netEventsFilter -ErrorAction Stop |
                 Sort-Object TimeCreated

    if ($netEvents) {
        $netEvents |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Format-List |
            Out-File -FilePath $reportFile -Append
    } else {
        "No matching network-related System events since $since." | Out-File -FilePath $reportFile -Append
    }
} catch {
    "Error querying network-related System events: $_" | Out-File -FilePath $reportFile -Append
}

"" | Out-File -FilePath $reportFile -Append

Write-Section "Event Logs (Application) - Splashtop / Service Failures"

# Look for Splashtop and generic service failures in Application log
$appEventsFilter = @{
    LogName   = 'Application'
    StartTime = $since
}

try {
    $appEvents = Get-WinEvent -FilterHashtable $appEventsFilter -ErrorAction Stop |
                 Where-Object {
                    $_.ProviderName -like "*Splashtop*" -or
                    $_.Message -match "Splashtop" -or
                    $_.Id -in 1000, 1001, 7031, 7034
                 } |
                 Sort-Object TimeCreated

    if ($appEvents) {
        $appEvents |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message |
            Format-List |
            Out-File -FilePath $reportFile -Append
    } else {
        "No Splashtop / service failure events since $since." | Out-File -FilePath $reportFile -Append
    }
} catch {
    "Error querying Application events: $_" | Out-File -FilePath $reportFile -Append
}

"" | Out-File -FilePath $reportFile -Append

# 5. Network adapter configuration
Write-Section "Network Adapters"

try {
    Get-NetAdapter |
        Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress |
        Format-Table -AutoSize |
        Out-String |
        Out-File -FilePath $reportFile -Append
} catch {
    "Error getting NetAdapter info: $_" | Out-File -FilePath $reportFile -Append
}

"`n----- ipconfig /all -----" | Out-File -FilePath $reportFile -Append
ipconfig /all 2>&1 | Out-File -FilePath $reportFile -Append

"" | Out-File -FilePath $reportFile -Append

# 6. Scheduled tasks that might restart/shutdown the computer
Write-Section "Scheduled Tasks (potential shutdown/restart/power tasks)"

try {
    $tasks = Get-ScheduledTask | Where-Object {
        $_.TaskName -match "shutdown|restart|reboot|power|hibernate|sleep" -or
        $_.Description -match "shutdown|restart|reboot|power|hibernate|sleep"
    }

    if ($tasks) {
        $tasks |
            Select-Object TaskName, TaskPath, State, @{Name="Triggers";Expression={($_.Triggers | ForEach-Object { $_.ToString() }) -join "; "}} |
            Format-List |
            Out-File -FilePath $reportFile -Append
    } else {
        "No obvious shutdown/restart-related scheduled tasks found." | Out-File -FilePath $reportFile -Append
    }
} catch {
    "Error getting scheduled tasks: $_" | Out-File -FilePath $reportFile -Append
}

"" | Out-File -FilePath $reportFile -Append

# 7. Running processes related to Splashtop
Write-Section "Running Splashtop Processes"

try {
    $splashtopProcs = Get-Process | Where-Object { $_.ProcessName -like "*splashtop*" -or $_.ProcessName -like "*SRServer*" }
    if ($splashtopProcs) {
        $splashtopProcs |
            Select-Object ProcessName, Id, CPU, StartTime |
            Format-Table -AutoSize |
            Out-String |
            Out-File -FilePath $reportFile -Append
    } else {
        "No Splashtop-related processes currently running." | Out-File -FilePath $reportFile -Append
    }
} catch {
    "Error getting Splashtop processes: $_" | Out-File -FilePath $reportFile -Append
}

"" | Out-File -FilePath $reportFile -Append

Write-Section "End of Report"

"Report generated: $(Get-Date)" | Out-File -FilePath $reportFile -Append

Write-Host "Finished. Report saved to: $reportFile"
