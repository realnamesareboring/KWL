# Convert-EvtxToSecurityEvents.ps1
# Converts Windows Security Event Logs (EVTX) to CSV format compatible with Kusto SecurityEvents table

param(
    [Parameter(Mandatory=$true)]
    [string]$EvtxPath,
    
    [string]$OutputCsv = ".\SecurityEvents_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    
    [string]$ComputerName = $env:COMPUTERNAME,
    
    [int]$MaxEvents = 10000,
    
    [string[]]$EventIDFilter = @(),  # Empty = all events, or specify like @(4624, 4625, 4688)
    
    [switch]$IncludeAllFields
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "EVTX to SecurityEvents Converter" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Validate input file
if (-not (Test-Path $EvtxPath)) {
    Write-Error "EVTX file not found: $EvtxPath"
    exit 1
}

Write-Host "Source EVTX: $EvtxPath" -ForegroundColor Yellow
Write-Host "Output CSV:  $OutputCsv" -ForegroundColor Yellow
Write-Host "Computer:    $ComputerName" -ForegroundColor Yellow
Write-Host ""

# Function to safely extract event data
function Get-EventProperty {
    param(
        [System.Diagnostics.Eventing.Reader.EventLogRecord]$Event,
        [string]$PropertyName
    )
    
    try {
        $value = $Event.Properties | Where-Object { $_.Name -eq $PropertyName } | Select-Object -First 1 -ExpandProperty Value
        if ($null -eq $value) { return "" }
        return $value.ToString()
    }
    catch {
        return ""
    }
}

# Read events from EVTX
Write-Host "Reading events from EVTX file..." -ForegroundColor Cyan

try {
    $events = Get-WinEvent -Path $EvtxPath -MaxEvents $MaxEvents -ErrorAction Stop
    
    # Filter by EventID if specified
    if ($EventIDFilter.Count -gt 0) {
        $events = $events | Where-Object { $EventIDFilter -contains $_.Id }
        Write-Host "  Filtered to EventIDs: $($EventIDFilter -join ', ')" -ForegroundColor Gray
    }
    
    Write-Host "  Found $($events.Count) events to process" -ForegroundColor Green
}
catch {
    Write-Error "Failed to read EVTX: $($_.Exception.Message)"
    exit 1
}

if ($events.Count -eq 0) {
    Write-Warning "No events found in EVTX file"
    exit 0
}

# Convert to SecurityEvents schema
Write-Host ""
Write-Host "Converting to SecurityEvents schema..." -ForegroundColor Cyan

$securityEvents = @()
$processedCount = 0

foreach ($event in $events) {
    $processedCount++
    
    if ($processedCount % 500 -eq 0) {
        Write-Host "  Processed $processedCount / $($events.Count) events..." -ForegroundColor Gray
    }
    
    # Parse event XML for detailed properties
    $eventXml = [xml]$event.ToXml()
    $eventData = @{}
    
    # Extract EventData fields
    if ($eventXml.Event.EventData.Data) {
        foreach ($data in $eventXml.Event.EventData.Data) {
            if ($data.Name) {
                $eventData[$data.Name] = $data.'#text'
            }
        }
    }
    
    # Map to SecurityEvents schema (Azure Monitor / Sentinel format)
    $secEvent = [PSCustomObject]@{
        TimeGenerated = $event.TimeCreated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Computer = $ComputerName
        EventID = $event.Id
        Activity = $event.TaskDisplayName
        Level = $event.Level
        SourceName = $event.ProviderName
        EventData = ($eventXml.Event.EventData.InnerXml -replace '\s+', ' ').Trim()
        
        # Common fields based on EventID
        Account = if ($eventData.ContainsKey('TargetUserName')) { $eventData['TargetUserName'] } else { "" }
        AccountType = if ($eventData.ContainsKey('AccountType')) { $eventData['AccountType'] } else { "" }
        LogonType = if ($eventData.ContainsKey('LogonType')) { $eventData['LogonType'] } else { "" }
        LogonTypeName = switch ($eventData['LogonType']) {
            "2" { "Interactive" }
            "3" { "Network" }
            "4" { "Batch" }
            "5" { "Service" }
            "7" { "Unlock" }
            "8" { "NetworkCleartext" }
            "9" { "NewCredentials" }
            "10" { "RemoteInteractive" }
            "11" { "CachedInteractive" }
            default { "" }
        }
        
        Status = if ($eventData.ContainsKey('Status')) { $eventData['Status'] } else { "" }
        SubStatus = if ($eventData.ContainsKey('SubStatus')) { $eventData['SubStatus'] } else { "" }
        
        SubjectUserSid = if ($eventData.ContainsKey('SubjectUserSid')) { $eventData['SubjectUserSid'] } else { "" }
        SubjectUserName = if ($eventData.ContainsKey('SubjectUserName')) { $eventData['SubjectUserName'] } else { "" }
        SubjectDomainName = if ($eventData.ContainsKey('SubjectDomainName')) { $eventData['SubjectDomainName'] } else { "" }
        SubjectLogonId = if ($eventData.ContainsKey('SubjectLogonId')) { $eventData['SubjectLogonId'] } else { "" }
        
        TargetUserSid = if ($eventData.ContainsKey('TargetUserSid')) { $eventData['TargetUserSid'] } else { "" }
        TargetUserName = if ($eventData.ContainsKey('TargetUserName')) { $eventData['TargetUserName'] } else { "" }
        TargetDomainName = if ($eventData.ContainsKey('TargetDomainName')) { $eventData['TargetDomainName'] } else { "" }
        TargetLogonId = if ($eventData.ContainsKey('TargetLogonId')) { $eventData['TargetLogonId'] } else { "" }
        
        IpAddress = if ($eventData.ContainsKey('IpAddress')) { $eventData['IpAddress'] } else { "" }
        IpPort = if ($eventData.ContainsKey('IpPort')) { $eventData['IpPort'] } else { "" }
        WorkstationName = if ($eventData.ContainsKey('WorkstationName')) { $eventData['WorkstationName'] } else { "" }
        
        Process = if ($eventData.ContainsKey('ProcessName')) { $eventData['ProcessName'] } else { "" }
        ProcessId = if ($eventData.ContainsKey('ProcessId')) { $eventData['ProcessId'] } else { "" }
        
        AuthenticationPackageName = if ($eventData.ContainsKey('AuthenticationPackageName')) { $eventData['AuthenticationPackageName'] } else { "" }
        LogonProcessName = if ($eventData.ContainsKey('LogonProcessName')) { $eventData['LogonProcessName'] } else { "" }
        
        # Additional fields for process creation (4688)
        NewProcessName = if ($eventData.ContainsKey('NewProcessName')) { $eventData['NewProcessName'] } else { "" }
        CommandLine = if ($eventData.ContainsKey('CommandLine')) { $eventData['CommandLine'] } else { "" }
        ParentProcessName = if ($eventData.ContainsKey('ParentProcessName')) { $eventData['ParentProcessName'] } else { "" }
        
        # Metadata
        EventRecordID = $event.RecordId
        Channel = $event.LogName
        Keywords = $event.KeywordsDisplayNames -join ';'
        Opcode = $event.OpcodeDisplayName
        Task = $event.TaskDisplayName
    }
    
    $securityEvents += $secEvent
}

Write-Host "  Conversion complete!" -ForegroundColor Green
Write-Host ""

# Export to CSV
Write-Host "Exporting to CSV..." -ForegroundColor Cyan

try {
    $securityEvents | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "  SUCCESS: Exported $($securityEvents.Count) events" -ForegroundColor Green
    Write-Host "  Output file: $OutputCsv" -ForegroundColor Cyan
}
catch {
    Write-Error "Failed to export CSV: $($_.Exception.Message)"
    exit 1
}

# Show summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total events processed: $($events.Count)" -ForegroundColor White
Write-Host "Output file: $OutputCsv" -ForegroundColor White
Write-Host "File size: $([math]::Round((Get-Item $OutputCsv).Length / 1MB, 2)) MB" -ForegroundColor White

# Show event distribution
Write-Host ""
Write-Host "Event ID Distribution:" -ForegroundColor Yellow
$events | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Host "  EventID $($_.Name): $($_.Count) events" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Ready for ingestion into Kusto!" -ForegroundColor Green
Write-Host ""