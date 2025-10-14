# Manage-KustoRetention.ps1
# Manages data retention and purging in Kusto Emulator

param(
    [string]$KustoEndpoint = "http://localhost:8080",
    
    [string]$DatabaseName = "NetDefaultDB",
    
    [string]$TableName = "SecurityEvents",
    
    [ValidateSet("SetPolicy", "PurgeOldData", "ShowStats", "RemovePolicy")]
    [string]$Action = "ShowStats",
    
    [int]$RetentionDays = 0,
    
    [int]$RetentionHours = 0,
    
    [int]$RetentionMinutes = 0,
    
    [switch]$Force
)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Kusto Data Retention Management" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Calculate total retention timespan
function Get-RetentionTimespan {
    $totalDays = $RetentionDays
    $totalHours = $RetentionHours
    $totalMinutes = $RetentionMinutes
    
    # If nothing specified, default to 1 day
    if ($totalDays -eq 0 -and $totalHours -eq 0 -and $totalMinutes -eq 0) {
        $totalDays = 1
    }
    
    # Create timespan string in format: days.hours:minutes:seconds
    $timespanString = "$totalDays.$($totalHours.ToString('00')):$($totalMinutes.ToString('00')):00"
    
    return @{
        Timespan = $timespanString
        TotalMinutes = ($totalDays * 24 * 60) + ($totalHours * 60) + $totalMinutes
        DisplayString = if ($totalDays -gt 0) { "$totalDays day(s)" } 
                        elseif ($totalHours -gt 0) { "$totalHours hour(s)" }
                        else { "$totalMinutes minute(s)" }
    }
}

# Test connection
function Test-KustoConnection {
    $testBody = @{
        db = $DatabaseName
        csl = ".show databases"
    } | ConvertTo-Json
    
    try {
        $result = Invoke-RestMethod -Uri ($KustoEndpoint + '/v1/rest/query') -Method Post -Body $testBody -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Error ("Failed to connect to Kusto: " + $_.Exception.Message)
        return $false
    }
}

# Execute Kusto command
function Invoke-KustoCommand {
    param(
        [string]$Command,
        [switch]$Query
    )
    
    $endpoint = if ($Query) { $KustoEndpoint + '/v1/rest/query' } else { $KustoEndpoint + '/v1/rest/mgmt' }
    
    $body = @{
        db = $DatabaseName
        csl = $Command
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        return $response
    }
    catch {
        Write-Error ("Command failed: " + $_.Exception.Message)
        return $null
    }
}

# Check connection
if (-not (Test-KustoConnection)) {
    Write-Host "  Ensure Docker container is running: docker ps | findstr kusto-emulator" -ForegroundColor Yellow
    exit 1
}

Write-Host "Connected to Kusto Emulator" -ForegroundColor Green
Write-Host ("Database: " + $DatabaseName) -ForegroundColor Yellow
Write-Host ("Table: " + $TableName) -ForegroundColor Yellow
Write-Host ("Action: " + $Action) -ForegroundColor Yellow

if ($Action -ne "ShowStats") {
    $retention = Get-RetentionTimespan
    Write-Host ("Retention: " + $retention.DisplayString) -ForegroundColor Yellow
}

Write-Host ""

# Execute action
switch ($Action) {
    "ShowStats" {
        Write-Host "Retrieving table statistics..." -ForegroundColor Cyan
        Write-Host ""
        
        # Total records
        $countQuery = $TableName + ' | count'
        $countResult = Invoke-KustoCommand -Command $countQuery -Query
        if ($countResult -and $countResult.Tables[0].Rows.Count -gt 0) {
            $totalRecords = $countResult.Tables[0].Rows[0][0]
            Write-Host ("Total records: " + $totalRecords) -ForegroundColor White
        }
        
        # Date range
        $rangeQuery = $TableName + ' | summarize MinTime = min(TimeGenerated), MaxTime = max(TimeGenerated)'
        $rangeResult = Invoke-KustoCommand -Command $rangeQuery -Query
        if ($rangeResult -and $rangeResult.Tables[0].Rows.Count -gt 0) {
            $minTime = $rangeResult.Tables[0].Rows[0][0]
            $maxTime = $rangeResult.Tables[0].Rows[0][1]
            Write-Host ("Oldest event: " + $minTime) -ForegroundColor White
            Write-Host ("Newest event: " + $maxTime) -ForegroundColor White
        }
        
        # Records by day
        Write-Host ""
        Write-Host "Records by day:" -ForegroundColor Cyan
        $dailyQuery = $TableName + ' | summarize Count = count() by Day = bin(TimeGenerated, 1d) | order by Day desc | take 10'
        $dailyResult = Invoke-KustoCommand -Command $dailyQuery -Query
        
        if ($dailyResult -and $dailyResult.Tables[0].Rows.Count -gt 0) {
            foreach ($row in $dailyResult.Tables[0].Rows) {
                $day = $row[0]
                $count = $row[1]
                Write-Host ("  " + $day + " : " + $count + " events") -ForegroundColor Gray
            }
        }
        
        # Current retention policy
        Write-Host ""
        Write-Host "Current retention policy:" -ForegroundColor Cyan
        $policyQuery = '.show table ' + $TableName + ' policy retention'
        $policyResult = Invoke-KustoCommand -Command $policyQuery
        
        if ($policyResult -and $policyResult.Tables[0].Rows.Count -gt 0) {
            $policy = $policyResult.Tables[0].Rows[0][1] | ConvertFrom-Json
            if ($policy.SoftDeletePeriod) {
                Write-Host ("  Soft delete period: " + $policy.SoftDeletePeriod) -ForegroundColor White
            } else {
                Write-Host "  No retention policy set" -ForegroundColor Yellow
            }
        }
    }
    
    "SetPolicy" {
        $retention = Get-RetentionTimespan
        
        Write-Host "Setting retention policy..." -ForegroundColor Cyan
        Write-Host ("  Retention period: " + $retention.DisplayString) -ForegroundColor Yellow
        Write-Host ""
        
        if (-not $Force) {
            $confirm = Read-Host ("This will automatically delete data older than " + $retention.DisplayString + ". Continue? (Y/N)")
            if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                Write-Host "Cancelled" -ForegroundColor Yellow
                exit 0
            }
        }
        
        # Set retention policy - using literal strings to avoid parsing issues
        $retentionTimespan = $retention.Timespan
        $policyCommand = '.alter table ' + $TableName + ' policy retention ```{ "SoftDeletePeriod": "' + $retentionTimespan + '", "Recoverability": "Disabled" }```'
        
        $result = Invoke-KustoCommand -Command $policyCommand
        
        if ($result) {
            Write-Host "Retention policy set successfully!" -ForegroundColor Green
            Write-Host ("  Data older than " + $retention.DisplayString + " will be automatically purged") -ForegroundColor Cyan
        }
    }
    
    "PurgeOldData" {
        $retention = Get-RetentionTimespan
        
        Write-Host ("Purging data older than " + $retention.DisplayString + "...") -ForegroundColor Cyan
        
        $cutoffDate = (Get-Date).AddMinutes(-$retention.TotalMinutes).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Write-Host ("  Cutoff date: " + $cutoffDate) -ForegroundColor Yellow
        Write-Host ""
        
        # Check how many records will be deleted - use literal string concatenation
        $checkQuery = $TableName + ' | where TimeGenerated < datetime(' + $cutoffDate + ') | count'
        $checkResult = Invoke-KustoCommand -Command $checkQuery -Query
        
        if ($checkResult -and $checkResult.Tables[0].Rows.Count -gt 0) {
            $recordsToDelete = $checkResult.Tables[0].Rows[0][0]
            
            if ($recordsToDelete -eq 0) {
                Write-Host "No records to purge" -ForegroundColor Yellow
                exit 0
            }
            
            Write-Host ("Records to purge: " + $recordsToDelete) -ForegroundColor Yellow
            
            if (-not $Force) {
                $confirm = Read-Host "Continue with purge? (Y/N)"
                if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                    Write-Host "Cancelled" -ForegroundColor Yellow
                    exit 0
                }
            }
            
            # NOTE: Kusto Emulator may have limited purge support
            # Using delete command as alternative
            Write-Host ""
            Write-Host "Deleting old records..." -ForegroundColor Red
            
            # This creates a new table without the old data
            $tempTable = $TableName + '_Temp_' + (Get-Date -Format 'yyyyMMddHHmmss')
            
            # Copy recent data to temp table - use literal string concatenation
            $sourceQuery = $TableName + ' | where TimeGenerated >= datetime(' + $cutoffDate + ')'
            $copyCommand = '.set-or-append ' + $tempTable + ' <| ' + $sourceQuery
            
            Write-Host "  Creating temporary table with recent data..." -ForegroundColor Yellow
            Invoke-KustoCommand -Command $copyCommand | Out-Null
            
            # Drop original table
            Write-Host "  Dropping original table..." -ForegroundColor Yellow
            $dropCommand = '.drop table ' + $TableName + ' ifexists'
            Invoke-KustoCommand -Command $dropCommand | Out-Null
            
            # Rename temp table
            Write-Host "  Renaming temporary table..." -ForegroundColor Yellow
            $renameCommand = '.rename table ' + $tempTable + ' to ' + $TableName
            Invoke-KustoCommand -Command $renameCommand | Out-Null
            
            Write-Host ""
            Write-Host "Purge complete!" -ForegroundColor Green
            Write-Host ("  Deleted: " + $recordsToDelete + " records") -ForegroundColor Cyan
        }
    }
    
    "RemovePolicy" {
        Write-Host "Removing retention policy..." -ForegroundColor Cyan
        
        if (-not $Force) {
            $confirm = Read-Host "Remove automatic data retention? (Y/N)"
            if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                Write-Host "Cancelled" -ForegroundColor Yellow
                exit 0
            }
        }
        
        $removeCommand = '.delete table ' + $TableName + ' policy retention'
        $result = Invoke-KustoCommand -Command $removeCommand
        
        if ($result) {
            Write-Host "Retention policy removed" -ForegroundColor Green
        }
    }
}

Write-Host ""