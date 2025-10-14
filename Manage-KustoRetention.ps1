# Manage-KustoRetention.ps1
# Utility script for managing retention and purging in the Kusto Emulator

param(
    [string]$KustoEndpoint = "http://localhost:8080",
    [string]$DatabaseName = "NetDefaultDB",
    [string]$TableName = "SecurityEvents",
    [ValidateSet("SetPolicy", "PurgeOldData", "ShowStats", "RemovePolicy", "RestoreDefault")]
    [string]$Action = "ShowStats",
    [int]$RetentionDays = 0,
    [int]$RetentionHours = 0,
    [int]$RetentionMinutes = 0,
    [switch]$UseDefault,
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

    if ($UseDefault) {
        $timespanString = "365.00:00:00"
        return @{
            Timespan      = $timespanString
            TotalMinutes  = 365 * 24 * 60
            DisplayString = "Default (365 day) retention"
        }
    }

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

function Invoke-KustoRequest {
    param(
        [string]$Path,
        [hashtable]$Body,
        [string]$ErrorContext,
        [int]$TimeoutSec = 30
    )

    $jsonBody = $Body | ConvertTo-Json

    try {
        return Invoke-RestMethod -Uri "$KustoEndpoint$Path" -Method Post -Body $jsonBody -ContentType 'application/json' -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    catch {
        Write-Host "    $ErrorContext failed: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host "    Details: $($_.ErrorDetails.Message)" -ForegroundColor DarkRed
        }
        return $null
    }
}

function Test-KustoConnection {
    $testBody = @{ db = $DatabaseName; csl = ".show databases" }
    $response = Invoke-KustoRequest -Path "/v1/rest/mgmt" -Body $testBody -ErrorContext "Connection test" -TimeoutSec 5
    return [bool]$response
}

function Invoke-KustoQuery {
    param([string]$Query)

    Write-Host "  [DEBUG] Query: $Query" -ForegroundColor DarkGray

    $body = @{ db = $DatabaseName; csl = $Query }
    return Invoke-KustoRequest -Path "/v1/rest/query" -Body $body -ErrorContext "Query"
}

function Invoke-KustoMgmt {
    param([string]$Command)

    Write-Host "  [DEBUG] Command: $Command" -ForegroundColor DarkGray

    $body = @{ db = $DatabaseName; csl = $Command }
    return Invoke-KustoRequest -Path "/v1/rest/mgmt" -Body $body -ErrorContext "Command"
}

function Convert-KustoRowToObject {
    param(
        $Table,
        [int]$RowIndex = 0
    )

    if (-not $Table -or $Table.Rows.Count -le $RowIndex) {
        return $null
    }

    $row = $Table.Rows[$RowIndex]
    $columns = $Table.Columns

    $result = [ordered]@{}

    for ($i = 0; $i -lt $columns.Count; $i++) {
        $columnName = $columns[$i].ColumnName
        if (-not $columnName) {
            $columnName = $columns[$i].Name
        }
        if (-not $columnName) {
            $columnName = "Column$i"
        }
        $result[$columnName] = $row[$i]
    }

    return [pscustomobject]$result
}

if (-not (Test-KustoConnection)) {
    Write-Host "  Ensure Docker container is running: docker ps | findstr kusto-emulator" -ForegroundColor Yellow
    exit 1
}

Write-Host "Connected to Kusto Emulator" -ForegroundColor Green
Write-Host "Database: $DatabaseName" -ForegroundColor Yellow
Write-Host "Table: $TableName" -ForegroundColor Yellow
Write-Host "Action: $Action" -ForegroundColor Yellow

if ($Action -in @("SetPolicy", "PurgeOldData")) {
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
        $countCmd = "$TableName | count"
        $countResult = Invoke-KustoQuery -Query $countCmd
        
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
        
        if ($policyResult -and $policyResult.Tables.Count -gt 0 -and $policyResult.Tables[0].Rows.Count -gt 0) {
            $policyTable = $policyResult.Tables[0]
            $policyRow = Convert-KustoRowToObject -Table $policyTable

            $policyJson = $null
            if ($policyRow.Policy -and $policyRow.Policy -ne 'null') {
                $policyJson = $policyRow.Policy
            } elseif ($policyRow.EffectivePolicy -and $policyRow.EffectivePolicy -ne 'null') {
                $policyJson = $policyRow.EffectivePolicy
            }

            if ($policyJson) {
                $policy = $policyJson | ConvertFrom-Json

                if ($policy.SoftDeletePeriod) {
                    Write-Host "  Soft delete period: $($policy.SoftDeletePeriod)" -ForegroundColor White
                }

                if ($policy.Recoverability) {
                    Write-Host "  Recoverability: $($policy.Recoverability)" -ForegroundColor White
                }
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
        if ($UseDefault) {
            $policyJson = '{ "SoftDeletePeriod": "' + $retentionTimespan + '", "Recoverability": "Enabled" }'
        } else {
            $policyJson = '{ "SoftDeletePeriod": "' + $retentionTimespan + '", "Recoverability": "Disabled" }'
        }
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

    "RestoreDefault" {
        Write-Host "Restoring retention policy to default..." -ForegroundColor Cyan

        $defaultPolicy = '{ "SoftDeletePeriod": "365.00:00:00", "Recoverability": "Enabled" }'
        $tick = '`'
        $policyCommand = '.alter table ' + $TableName + ' policy retention ' + $tick + $defaultPolicy + $tick

        $result = Invoke-KustoMgmt -Command $policyCommand

        if ($result) {
            Write-Host "Retention policy restored to default (365 days, Recoverability Enabled)" -ForegroundColor Green
        }
    }
}

Write-Host ""

