# Manage-Retention-NEW.ps1
# Manages data retention and purging in Kusto Emulator
# FINAL VERSION - Uses KWL-Tool.ps1 patterns

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

function Get-RetentionTimespan {
    $totalDays = $RetentionDays
    $totalHours = $RetentionHours
    $totalMinutes = $RetentionMinutes
    
    if ($totalDays -eq 0 -and $totalHours -eq 0 -and $totalMinutes -eq 0) {
        $totalDays = 1
    }
    
    $timespanString = "$totalDays.$($totalHours.ToString('00')):$($totalMinutes.ToString('00')):00"
    
    return @{
        Timespan = $timespanString
        TotalMinutes = ($totalDays * 24 * 60) + ($totalHours * 60) + $totalMinutes
        DisplayString = if ($totalDays -gt 0) { "$totalDays day(s)" } 
                        elseif ($totalHours -gt 0) { "$totalHours hour(s)" }
                        else { "$totalMinutes minute(s)" }
    }
}

function Test-KustoConnection {
    $testBody = @{db=$DatabaseName; csl=".show databases"} | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/query" -Method Post -Body $testBody -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "  Connection failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Invoke-KustoQuery {
    param([string]$Query)
    
    # DEBUG: Show what we're sending
    Write-Host "  [DEBUG] Query: $Query" -ForegroundColor DarkGray
    
    $body = @{
        db = $DatabaseName
        csl = $Query
    } | ConvertTo-Json
    
    try {
        # USE MGMT ENDPOINT FOR EVERYTHING (like KWL-Tool does!)
        $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/mgmt" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        return $response
    }
    catch {
        Write-Host "    Query failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host "    Details: $($_.ErrorDetails.Message)" -ForegroundColor DarkRed
        }
        return $null
    }
}

function Invoke-KustoMgmt {
    param([string]$Command)
    
    $body = @{
        db = $DatabaseName
        csl = $Command
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/mgmt" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        return $response
    }
    catch {
        Write-Host "    Command failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

if (-not (Test-KustoConnection)) {
    Write-Host "  Ensure Docker container is running: docker ps | findstr kusto-emulator" -ForegroundColor Yellow
    exit 1
}

Write-Host "Connected to Kusto Emulator" -ForegroundColor Green
Write-Host "Database: $DatabaseName" -ForegroundColor Yellow
Write-Host "Table: $TableName" -ForegroundColor Yellow
Write-Host "Action: $Action" -ForegroundColor Yellow

if ($Action -ne "ShowStats") {
    $retention = Get-RetentionTimespan
    Write-Host "Retention: $($retention.DisplayString)" -ForegroundColor Yellow
}

Write-Host ""

switch ($Action) {
    "ShowStats" {
        Write-Host "Retrieving table statistics..." -ForegroundColor Cyan
        Write-Host ""
        
        # Try using .show commands instead of queries
        Write-Host "Checking table extents..." -ForegroundColor Gray
        $extentsCmd = ".show table $TableName extents"
        Write-Host "  [DEBUG] Command: $extentsCmd" -ForegroundColor DarkGray
        $extentsResult = Invoke-KustoMgmt -Command $extentsCmd
        
        if ($extentsResult -and $extentsResult.Tables[0].Rows.Count -gt 0) {
            Write-Host "Table exists with data extents" -ForegroundColor Green
        }
        
        # Show table details
        Write-Host ""
        Write-Host "Table details:" -ForegroundColor Cyan
        $tableCmd = ".show table $TableName details"
        $tableResult = Invoke-KustoMgmt -Command $tableCmd
        
        # Try a simple count using evaluate
        Write-Host ""
        Write-Host "Attempting row count..." -ForegroundColor Cyan
        $countCmd = ".show table $TableName | count"
        Write-Host "  [DEBUG] Command: $countCmd" -ForegroundColor DarkGray
        $countResult = Invoke-KustoMgmt -Command $countCmd
        
        if ($countResult -and $countResult.Tables[0].Rows.Count -gt 0) {
            Write-Host "Count result received" -ForegroundColor Green
        } else {
            Write-Host "NOTE: The Kusto Emulator REST API may not support KQL queries" -ForegroundColor Yellow
            Write-Host "Use the Kusto Web Explorer at http://localhost:8080 to query data" -ForegroundColor Yellow
        }
        
        # Current retention policy
        Write-Host ""
        Write-Host "Current retention policy:" -ForegroundColor Cyan
        $policyCommand = ".show table $TableName policy retention"
        Write-Host "  [DEBUG] Command: $policyCommand" -ForegroundColor DarkGray
        $policyResult = Invoke-KustoMgmt -Command $policyCommand
        
        if ($policyResult -and $policyResult.Tables[0].Rows.Count -gt 0) {
            $policy = $policyResult.Tables[0].Rows[0][1] | ConvertFrom-Json
            if ($policy.SoftDeletePeriod) {
                Write-Host "  Soft delete period: $($policy.SoftDeletePeriod)" -ForegroundColor White
            } else {
                Write-Host "  No retention policy set" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Could not retrieve retention policy" -ForegroundColor Yellow
        }
    }
    
    "SetPolicy" {
        $retention = Get-RetentionTimespan
        
        Write-Host "Setting retention policy..." -ForegroundColor Cyan
        Write-Host "  Retention period: $($retention.DisplayString)" -ForegroundColor Yellow
        Write-Host ""
        
        if (-not $Force) {
            $confirmMsg = "This will automatically delete data older than $($retention.DisplayString). Continue? (Y/N)"
            $confirm = Read-Host $confirmMsg
            if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                Write-Host "Cancelled" -ForegroundColor Yellow
                exit 0
            }
        }
        
        # Build policy command using simple concatenation
        $retentionTimespan = $retention.Timespan
        $tick = '`'
        $policyJson = '{ "SoftDeletePeriod": "' + $retentionTimespan + '", "Recoverability": "Disabled" }'
        $policyCommand = '.alter table ' + $TableName + ' policy retention ' + $tick + $policyJson + $tick
        
        $result = Invoke-KustoMgmt -Command $policyCommand
        
        if ($result) {
            $successMsg = "Retention policy set successfully"
            Write-Host $successMsg -ForegroundColor Green
            $infoMsg = "Data older than $($retention.DisplayString) will be automatically purged"
            Write-Host "  $infoMsg" -ForegroundColor Cyan
        }
    }
    
    "PurgeOldData" {
        $retention = Get-RetentionTimespan
        
        Write-Host "Purging data older than $($retention.DisplayString)..." -ForegroundColor Cyan
        
        $cutoffDate = (Get-Date).AddMinutes(-$retention.TotalMinutes).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Write-Host "  Cutoff date: $cutoffDate" -ForegroundColor Yellow
        Write-Host ""
        
        # Build query with < using variable (KWL-Tool pattern)
        $lessThan = '<'
        $checkQuery = "$TableName | where TimeGenerated $lessThan datetime($cutoffDate) | count"
        $checkResult = Invoke-KustoQuery -Query $checkQuery
        
        if ($checkResult -and $checkResult.Tables[0].Rows.Count -gt 0) {
            $recordsToDelete = $checkResult.Tables[0].Rows[0][0]
            
            if ($recordsToDelete -eq 0) {
                Write-Host "No records to purge" -ForegroundColor Yellow
                exit 0
            }
            
            Write-Host "Records to purge: $recordsToDelete" -ForegroundColor Yellow
            
            if (-not $Force) {
                $confirm = Read-Host "Continue with purge? (Y/N)"
                if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                    Write-Host "Cancelled" -ForegroundColor Yellow
                    exit 0
                }
            }
            
            Write-Host ""
            Write-Host "Deleting old records..." -ForegroundColor Red
            
            $tempTable = "${TableName}_Temp_$(Get-Date -Format 'yyyyMMddHHmmss')"
            
            # Build <| operator using variables (KWL-Tool pattern)
            $leftChar = '<'
            $pipeChar = '|'
            $ingestOp = "$leftChar$pipeChar"
            $greaterEqual = '>='
            $sourceQuery = "$TableName | where TimeGenerated $greaterEqual datetime($cutoffDate)"
            $copyCommand = ".set-or-append $tempTable $ingestOp $sourceQuery"
            
            Write-Host "  Creating temporary table with recent data..." -ForegroundColor Yellow
            Invoke-KustoMgmt -Command $copyCommand | Out-Null
            
            Write-Host "  Dropping original table..." -ForegroundColor Yellow
            $dropCommand = ".drop table $TableName ifexists"
            Invoke-KustoMgmt -Command $dropCommand | Out-Null
            
            Write-Host "  Renaming temporary table..." -ForegroundColor Yellow
            $renameCommand = ".rename table $tempTable to $TableName"
            Invoke-KustoMgmt -Command $renameCommand | Out-Null
            
            Write-Host ""
            Write-Host "Purge complete!" -ForegroundColor Green
            Write-Host "  Deleted: $recordsToDelete records" -ForegroundColor Cyan
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
        $result = Invoke-KustoMgmt -Command $removeCommand
        
        if ($result) {
            $successMsg = "Retention policy removed successfully"
            Write-Host $successMsg -ForegroundColor Green
        }
    }
}

Write-Host ""