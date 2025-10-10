# KWL Tool  - Kusto Workspace Lab 
# Version 2.0 - Enhanced with Azure Monitor Integration

param(
    [string]$KustoEndpoint = "http://localhost:8080",
    [string]$DatabaseName = "NetDefaultDB",
    [string]$ConfigPath = ".\tables.json",
    [string]$DataPath = ".\data",
    [string]$AzureMonitorScriptPath = ".\AzureMonitorTablesScraper.ps1"
)

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "    The KWL (Kusto Workspace Lab) Tool - Cyber Range Kusto Deployment Tool" -ForegroundColor Cyan
    Write-Host "    Guiding Your Data Through the Cyber Seas" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Endpoint: $KustoEndpoint | Database: $DatabaseName" -ForegroundColor Yellow
    Write-Host ""
}

function Invoke-KustoCommand {
    param(
        [string]$Command,
        [string]$Description,
        [switch]$Silent
    )
    
    if (-not $Silent) {
        Write-Host "  -> $Description" -ForegroundColor Yellow
    }
    
    $body = @{
        db = $DatabaseName
        csl = $Command
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/mgmt" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        
        if (-not $Silent) {
            Write-Host "    SUCCESS" -ForegroundColor Green
        }
        return $true
    }
    catch {
        if (-not $Silent) {
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
        return $false
    }
}

function Test-KustoConnection {
    Write-Host ""
    Write-Host "Checking Kusto Emulator connection..." -ForegroundColor Cyan
    
    $maxRetries = 10
    $retryCount = 0
    
    while ($retryCount -lt $maxRetries) {
        try {
            $testBody = @{db=$DatabaseName; csl=".show databases"} | ConvertTo-Json
            $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/query" -Method Post -Body $testBody -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
            
            Write-Host "  Connected successfully!" -ForegroundColor Green
            return $true
        }
        catch {
            $retryCount++
            Write-Host "  Waiting for Kusto... (Attempt $retryCount/$maxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
    }
    
    Write-Host "  Connection failed!" -ForegroundColor Red
    Write-Host "  Ensure Docker container is running: docker ps | findstr kusto-emulator" -ForegroundColor Yellow
    return $false
}

function Load-TableConfig {
    if (-not (Test-Path $ConfigPath)) {
        Write-Host "  Configuration file not found: $ConfigPath" -ForegroundColor Red
        Write-Host "  Run option 3 to create a configuration file" -ForegroundColor Yellow
        return $null
    }
    
    try {
        $rawConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        
        # Check if this is Azure Monitor format (has Categories property)
        if ($rawConfig.PSObject.Properties.Name -contains "Categories") {
            Write-Host "  Detected Azure Monitor format, converting..." -ForegroundColor Yellow
            
            # Convert Azure Monitor format to KQL-Lighthouse format
            $tables = @()
            
            foreach ($category in $rawConfig.Categories.PSObject.Properties) {
                $categoryName = $category.Name
                
                foreach ($table in $category.Value) {
                    $schema = @()
                    foreach ($column in $table.Columns) {
                        $kustoType = Convert-AzureMonitorTypeToKusto -AzureType $column.Type
                        $schema += @{
                            name = $column.Name
                            type = $kustoType
                            description = $column.Description
                        }
                    }
                    
                    $tables += @{
                        name = $table.TableName
                        category = $categoryName
                        schema = $schema
                        source = "Azure Monitor"
                        url = $table.Url
                    }
                }
            }
            
            $config = @{
                tables = $tables
                functions = @()
                metadata = @{
                    source = "Azure Monitor Reference"
                    originalFormat = $true
                }
            }
            
            Write-Host "  Converted $($tables.Count) tables from Azure Monitor format" -ForegroundColor Green
            return $config
        }
        # Standard format (has tables property)
        elseif ($rawConfig.PSObject.Properties.Name -contains "tables") {
            Write-Host "  Loaded configuration: $($rawConfig.tables.Count) tables defined" -ForegroundColor Green
            return $rawConfig
        }
        else {
            Write-Host "  Unknown configuration format!" -ForegroundColor Red
            Write-Host "  Expected 'tables' or 'Categories' property" -ForegroundColor Yellow
            return $null
        }
    }
    catch {
        Write-Host "  Failed to parse configuration: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Convert-AzureMonitorTypeToKusto {
    param([string]$AzureType)
    
    # Map Azure Monitor types to Kusto types
    switch -Regex ($AzureType.ToLower()) {
        "^string$|^text$" { return "string" }
        "^int$|^integer$" { return "int" }
        "^long$" { return "long" }
        "^real$|^double$|^float$" { return "real" }
        "^datetime$|^timestamp$" { return "datetime" }
        "^bool$|^boolean$" { return "bool" }
        "^dynamic$|^json$" { return "dynamic" }
        "^guid$|^uuid$" { return "guid" }
        "^timespan$" { return "timespan" }
        default { return "string" }
    }
}

function Import-AzureMonitorJSON {
    param([string]$JsonPath)
    
    Write-Host ""
    Write-Host "  Importing Azure Monitor table definitions..." -ForegroundColor Cyan
    
    if (-not (Test-Path $JsonPath)) {
        Write-Host "  File not found: $JsonPath" -ForegroundColor Red
        return $null
    }
    
    try {
        $azureData = Get-Content $JsonPath -Raw | ConvertFrom-Json
        
        $tables = @()
        
        foreach ($category in $azureData.Categories.PSObject.Properties) {
            $categoryName = $category.Name
            Write-Host "  Processing category: $categoryName" -ForegroundColor Yellow
            
            foreach ($table in $category.Value) {
                Write-Host "    - $($table.TableName) ($($table.ColumnCount) columns)" -ForegroundColor Gray
                
                $schema = @()
                foreach ($column in $table.Columns) {
                    $kustoType = Convert-AzureMonitorTypeToKusto -AzureType $column.Type
                    $schema += @{
                        name = $column.Name
                        type = $kustoType
                        description = $column.Description
                    }
                }
                
                $tables += @{
                    name = $table.TableName
                    category = $categoryName
                    schema = $schema
                    source = "Azure Monitor"
                    url = $table.Url
                }
            }
        }
        
        Write-Host ""
        Write-Host "  Successfully imported $($tables.Count) tables" -ForegroundColor Green
        
        return @{
            tables = $tables
            functions = @()
            metadata = @{
                source = "Azure Monitor Reference"
                imported = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                originalFile = $JsonPath
            }
        }
    }
    catch {
        Write-Host "  Failed to parse Azure Monitor JSON: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Import-StandaloneTable {
    Show-Banner
    Write-Host ""
    Write-Host "IMPORT STANDALONE TABLE DATA" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Select import source:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1 - Import from Azure Monitor JSON file" -ForegroundColor White
    Write-Host "  2 - Browse for custom JSON file" -ForegroundColor White
    Write-Host "  3 - Cancel" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Enter choice"
    
    switch ($choice) {
        "1" {
            $defaultPath = ".\AzureMonitorTables_Security.json"
            if (Test-Path $defaultPath) {
                $jsonPath = $defaultPath
            } else {
                Write-Host ""
                $jsonPath = Read-Host "Enter path to Azure Monitor JSON file"
            }
            
            if (Test-Path $jsonPath) {
                $importedConfig = Import-AzureMonitorJSON -JsonPath $jsonPath
                
                if ($null -ne $importedConfig) {
                    Write-Host ""
                    Write-Host "  Merge with existing config or replace?" -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  1 - Merge (add new tables)" -ForegroundColor White
                    Write-Host "  2 - Replace (overwrite tables.json)" -ForegroundColor White
                    Write-Host "  3 - Cancel" -ForegroundColor White
                    Write-Host ""
                    
                    $mergeChoice = Read-Host "Enter choice"
                    
                    if ($mergeChoice -eq "1") {
                        # Merge with existing
                        if (Test-Path $ConfigPath) {
                            $existing = Get-Content $ConfigPath -Raw | ConvertFrom-Json
                            
                            # Merge tables
                            $allTables = @()
                            $allTables += $existing.tables
                            $allTables += $importedConfig.tables
                            
                            $importedConfig.tables = $allTables
                            $importedConfig.functions = $existing.functions
                        }
                    }
                    
                    if ($mergeChoice -ne "3") {
                        $importedConfig | ConvertTo-Json -Depth 10 | Out-File $ConfigPath -Encoding UTF8
                        Write-Host ""
                        Write-Host "  Configuration saved to $ConfigPath" -ForegroundColor Green
                    }
                }
            } else {
                Write-Host ""
                Write-Host "  File not found!" -ForegroundColor Red
            }
        }
        "2" {
            Write-Host ""
            $jsonPath = Read-Host "Enter path to JSON file"
            
            if (Test-Path $jsonPath) {
                try {
                    $customConfig = Get-Content $jsonPath -Raw | ConvertFrom-Json
                    $customConfig | ConvertTo-Json -Depth 10 | Out-File $ConfigPath -Encoding UTF8
                    Write-Host ""
                    Write-Host "  Configuration imported successfully!" -ForegroundColor Green
                }
                catch {
                    Write-Host ""
                    Write-Host "  Failed to import: $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                Write-Host ""
                Write-Host "  File not found!" -ForegroundColor Red
            }
        }
        "3" {
            Write-Host ""
            Write-Host "  Cancelled" -ForegroundColor Yellow
        }
        default {
            Write-Host ""
            Write-Host "  Invalid option" -ForegroundColor Red
        }
    }
    
    Pause
}

function Pull-AzureMonitorData {
    Show-Banner
    Write-Host ""
    Write-Host "PULL AZURE MONITOR TABLE REFERENCE" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-Path $AzureMonitorScriptPath)) {
        Write-Host "  Azure Monitor scraper not found: $AzureMonitorScriptPath" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Please ensure AzureMonitorTablesScraper.ps1 is in the current directory" -ForegroundColor Yellow
        Pause
        return
    }
    
    Write-Host "  Select category to pull:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1 - Security (recommended)" -ForegroundColor White
    Write-Host "  2 - Network" -ForegroundColor White
    Write-Host "  3 - Audit" -ForegroundColor White
    Write-Host "  4 - All categories (WARNING: Large dataset)" -ForegroundColor White
    Write-Host "  5 - Custom category" -ForegroundColor White
    Write-Host "  6 - Cancel" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Enter choice"
    
    $category = ""
    $outputFile = ".\AzureMonitorTables_Downloaded.json"
    
    switch ($choice) {
        "1" { $category = "Security"; $outputFile = ".\AzureMonitorTables_Security.json" }
        "2" { $category = "Network"; $outputFile = ".\AzureMonitorTables_Network.json" }
        "3" { $category = "Audit"; $outputFile = ".\AzureMonitorTables_Audit.json" }
        "4" { 
            Write-Host ""
            Write-Host "  WARNING: This will download ALL categories and may take several minutes" -ForegroundColor Yellow
            $confirm = Read-Host "  Continue? (Y/N)"
            if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                Write-Host "  Cancelled" -ForegroundColor Yellow
                Pause
                return
            }
            $outputFile = ".\AzureMonitorTables_All.json"
        }
        "5" { 
            Write-Host ""
            $category = Read-Host "Enter category name (e.g., 'Containers', 'Applications')"
            $outputFile = ".\AzureMonitorTables_$category.json"
        }
        "6" {
            Write-Host ""
            Write-Host "  Cancelled" -ForegroundColor Yellow
            Pause
            return
        }
        default {
            Write-Host ""
            Write-Host "  Invalid option" -ForegroundColor Red
            Pause
            return
        }
    }
    
    Write-Host ""
    Write-Host "  Downloading Azure Monitor table data..." -ForegroundColor Cyan
    Write-Host "  This may take a few minutes..." -ForegroundColor Yellow
    Write-Host ""
    
    try {
        if ($choice -eq "4") {
            # All categories
            & $AzureMonitorScriptPath -AllCategories -OutputFile $outputFile
        } elseif ($category) {
            # Specific category
            & $AzureMonitorScriptPath -CategoryFilter $category -OutputFile $outputFile
        }
        
        if (Test-Path $outputFile) {
            Write-Host ""
            Write-Host "  Download complete!" -ForegroundColor Green
            Write-Host "  Saved to: $outputFile" -ForegroundColor Cyan
            Write-Host ""
            
            $import = Read-Host "Import this data into tables.json now? (Y/N)"
            
            if ($import -eq 'Y' -or $import -eq 'y') {
                $importedConfig = Import-AzureMonitorJSON -JsonPath $outputFile
                
                if ($null -ne $importedConfig) {
                    $importedConfig | ConvertTo-Json -Depth 10 | Out-File $ConfigPath -Encoding UTF8
                    Write-Host ""
                    Write-Host "  Configuration saved to $ConfigPath" -ForegroundColor Green
                }
            }
        } else {
            Write-Host ""
            Write-Host "  Download failed or was cancelled" -ForegroundColor Red
        }
    }
    catch {
        Write-Host ""
        Write-Host "  Error running scraper: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Pause
}

function Modify-Tables {
    Show-Banner
    Write-Host ""
    Write-Host "MODIFY TABLES" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "  1 - Import standalone table data" -ForegroundColor White
    Write-Host "  2 - Pull down table data from Microsoft Azure Monitor Table reference" -ForegroundColor White
    Write-Host "  3 - Edit existing" -ForegroundColor White
    Write-Host "  4 - Create new file" -ForegroundColor White
    Write-Host "  5 - Cancel" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Enter choice"
    
    switch ($choice) {
        "1" { Import-StandaloneTable }
        "2" { Pull-AzureMonitorData }
        "3" { 
            if (Test-Path $ConfigPath) {
                Write-Host ""
                Write-Host "  Opening configuration file..." -ForegroundColor Cyan
                if (Get-Command code -ErrorAction SilentlyContinue) {
                    code $ConfigPath
                    Write-Host "  Opened in VS Code" -ForegroundColor Green
                } elseif (Get-Command notepad -ErrorAction SilentlyContinue) {
                    notepad $ConfigPath
                    Write-Host "  Opened in Notepad" -ForegroundColor Green
                }
                Pause
            } else {
                Write-Host ""
                Write-Host "  Configuration file does not exist: $ConfigPath" -ForegroundColor Red
                Write-Host "  Use option 4 to create a new file" -ForegroundColor Yellow
                Pause
            }
        }
        "4" { Create-DefaultConfig; Pause }
        "5" { 
            Write-Host ""
            Write-Host "  Cancelled" -ForegroundColor Yellow
        }
        default {
            Write-Host ""
            Write-Host "  Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

function Deploy-FirstTime {
    Show-Banner
    Write-Host ""
    Write-Host "FIRST TIME DEPLOYMENT" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-KustoConnection)) {
        Pause
        return
    }
    
    $config = Load-TableConfig
    if ($null -eq $config) {
        Pause
        return
    }
    
    Write-Host ""
    Write-Host "Creating/updating tables..." -ForegroundColor Cyan
    $successCount = 0
    $failCount = 0
    
    foreach ($table in $config.tables) {
        $columns = ($table.schema | ForEach-Object { "$($_.name): $($_.type)" }) -join ", "
        
        # Use .create-merge to create or update the table schema
        $command = ".create-merge table $($table.name) ($columns)"
        
        $result = Invoke-KustoCommand -Command $command -Description "Creating/updating table: $($table.name)"
        
        if ($result) {
            $successCount++
        } else {
            $failCount++
        }
    }
    
    Write-Host ""
    Write-Host "Creating functions..." -ForegroundColor Cyan
    $funcSuccessCount = 0
    $funcFailCount = 0
    
    foreach ($func in $config.functions) {
        $result = Invoke-KustoCommand -Command $func.definition -Description "Creating function: $($func.name)"
        
        if ($result) {
            $funcSuccessCount++
        } else {
            $funcFailCount++
        }
    }
    
    Write-Host ""
    Write-Host "Deployment complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Tables processed: $($config.tables.Count)" -ForegroundColor White
    Write-Host "    - Success: $successCount" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "    - Failed: $failCount" -ForegroundColor Red
    }
    Write-Host "  Functions processed: $($config.functions.Count)" -ForegroundColor White
    Write-Host "    - Success: $funcSuccessCount" -ForegroundColor Green
    if ($funcFailCount -gt 0) {
        Write-Host "    - Failed: $funcFailCount" -ForegroundColor Red
    }
    Write-Host ""
    
    Pause
}

function Purge-AllData {
    Show-Banner
    Write-Host ""
    Write-Host "DELETE ALL TABLES" -ForegroundColor Red
    Write-Host "======================================" -ForegroundColor Red
    Write-Host ""
    
    Write-Host "WARNING: This will PERMANENTLY DELETE ALL tables!" -ForegroundColor Red
    Write-Host "Tables will be completely removed from the database." -ForegroundColor Yellow
    Write-Host "Use Option 1 (Deploy) to recreate them afterwards." -ForegroundColor Yellow
    Write-Host ""
    
    $confirm = Read-Host "Type DELETE to confirm"
    
    if ($confirm -ne 'DELETE') {
        Write-Host ""
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        Pause
        return
    }
    
    if (-not (Test-KustoConnection)) {
        Pause
        return
    }
    
    # Discover all tables dynamically
    Write-Host ""
    Write-Host "Discovering tables in database..." -ForegroundColor Cyan
    
    $command = ".show tables"
    $body = @{
        db = $DatabaseName
        csl = $command
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/mgmt" -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        
        $tables = @()
        
        if ($response.Tables -and $response.Tables.Count -gt 0) {
            $tableData = $response.Tables[0]
            
            $tableNameIndex = -1
            for ($i = 0; $i -lt $tableData.Columns.Count; $i++) {
                if ($tableData.Columns[$i].ColumnName -eq "TableName") {
                    $tableNameIndex = $i
                    break
                }
            }
            
            if ($tableNameIndex -ge 0 -and $tableData.Rows) {
                foreach ($row in $tableData.Rows) {
                    $tableName = $row[$tableNameIndex]
                    if ($tableName) {
                        $tables += $tableName
                    }
                }
            }
        }
        
        if ($tables.Count -eq 0) {
            Write-Host "  No tables found in database" -ForegroundColor Yellow
            Pause
            return
        }
        
        Write-Host "  Found $($tables.Count) tables" -ForegroundColor Green
    }
    catch {
        Write-Host "  Failed to retrieve table list: $($_.Exception.Message)" -ForegroundColor Red
        Pause
        return
    }
    
    Write-Host ""
    Write-Host "Deleting tables..." -ForegroundColor Red
    $successCount = 0
    $failCount = 0
    $failedTables = @()
    
    foreach ($tableName in $tables) {
        Write-Host "  -> Deleting: $tableName" -ForegroundColor Yellow
        
        $dropCommand = ".drop table $tableName ifexists"
        $dropBody = @{
            db = $DatabaseName
            csl = $dropCommand
        } | ConvertTo-Json
        
        try {
            $response = Invoke-RestMethod -Uri "$KustoEndpoint/v1/rest/mgmt" -Method Post -Body $dropBody -ContentType "application/json" -ErrorAction Stop
            Write-Host "    DELETED" -ForegroundColor Green
            $successCount++
        }
        catch {
            Write-Host "    FAILED" -ForegroundColor Red
            Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor DarkGray
            $failCount++
            $failedTables += $tableName
        }
    }
    
    Write-Host ""
    Write-Host "Deletion complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Total tables: $($tables.Count)" -ForegroundColor White
    Write-Host "  Successfully deleted: $successCount" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "  Failed to delete: $failCount" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Failed tables:" -ForegroundColor Yellow
        foreach ($failedTable in $failedTables) {
            Write-Host "    - $failedTable" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    
    Pause
}

function Create-DefaultConfig {
    $functionDef = @'
.create function SimulateFailedLogons() { range x from 1 to 100 step 1 | extend TimeGenerated = now() - (rand(168) * 1h) | extend Computer = strcat('WS-', tostring(toint(rand(50)) + 1)) | extend EventID = 4625 | extend Activity = 'Failed Logon' | extend Account = strcat('user', tostring(toint(rand(100))), '@company.com') | extend LogonType = toint(rand(5)) + 2 | extend SourceIP = strcat(tostring(toint(rand(254)) + 1), '.', tostring(toint(rand(254)) + 1), '.', tostring(toint(rand(254)) + 1), '.', tostring(toint(rand(254)) + 1)) | extend DestinationIP = '10.0.0.5' | extend Process = 'winlogon.exe' | extend CommandLine = '' | project TimeGenerated, Computer, EventID, Activity, Account, LogonType, SourceIP, DestinationIP, Process, CommandLine }
'@

    $defaultConfig = @{
        tables = @(
            @{
                name = "SecurityEvents"
                schema = @(
                    @{ name = "TimeGenerated"; type = "datetime" }
                    @{ name = "Computer"; type = "string" }
                    @{ name = "EventID"; type = "int" }
                    @{ name = "Activity"; type = "string" }
                    @{ name = "Account"; type = "string" }
                    @{ name = "LogonType"; type = "int" }
                    @{ name = "SourceIP"; type = "string" }
                    @{ name = "DestinationIP"; type = "string" }
                    @{ name = "Process"; type = "string" }
                    @{ name = "CommandLine"; type = "string" }
                )
            }
        )
        functions = @(
            @{
                name = "SimulateFailedLogons"
                definition = $functionDef
            }
        )
    }
    
    $defaultConfig | ConvertTo-Json -Depth 10 | Out-File $ConfigPath -Encoding UTF8
    Write-Host ""
    Write-Host "  Default configuration created: $ConfigPath" -ForegroundColor Green
}

function Reset-DockerContainer {
    Show-Banner
    Write-Host ""
    Write-Host "RESET DOCKER CONTAINER" -ForegroundColor Red
    Write-Host "======================================" -ForegroundColor Red
    Write-Host ""
    
    Write-Host "WARNING: DANGER ZONE" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will:" -ForegroundColor Yellow
    Write-Host "  * STOP the Kusto Emulator container" -ForegroundColor Yellow
    Write-Host "  * REMOVE the container completely" -ForegroundColor Yellow
    Write-Host "  * DELETE all data" -ForegroundColor Yellow
    Write-Host "  * RESTART a fresh container" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "ALL DATA WILL BE LOST!" -ForegroundColor Red
    Write-Host ""
    
    $confirm = Read-Host "Type RESET to confirm"
    
    if ($confirm -ne 'RESET') {
        Write-Host ""
        Write-Host "Operation cancelled - Container is safe!" -ForegroundColor Green
        Pause
        return
    }
    
    Write-Host ""
    Write-Host "Stopping container..." -ForegroundColor Yellow
    docker stop kusto-emulator 2>$null
    
    Write-Host "Removing container..." -ForegroundColor Yellow
    docker rm kusto-emulator 2>$null
    
    Write-Host "Starting fresh container..." -ForegroundColor Yellow
    docker run -d -p 8080:8080 -e ACCEPT_EULA=Y -v kusto-data:/kusto/data --restart unless-stopped --name kusto-emulator mcr.microsoft.com/azuredataexplorer/kustainer-linux:latest
    
    Write-Host ""
    Write-Host "Container reset complete!" -ForegroundColor Green
    Write-Host "Wait 10-15 seconds for the container to be ready" -ForegroundColor Yellow
    Pause
}

function Import-CSVData {
    Write-Host ""
    Write-Host "Importing CSV data..." -ForegroundColor Cyan
    
    if (-not (Test-Path $DataPath)) {
        Write-Host "  Data directory not found: $DataPath" -ForegroundColor Red
        return
    }
    
    $csvFiles = Get-ChildItem -Path $DataPath -Filter "*.csv" -ErrorAction SilentlyContinue
    
    if ($csvFiles.Count -eq 0) {
        Write-Host "  No CSV files found in $DataPath" -ForegroundColor Yellow
        return
    }
    
    foreach ($csvFile in $csvFiles) {
        $tableName = [System.IO.Path]::GetFileNameWithoutExtension($csvFile.Name)
        Write-Host "  Importing: $tableName from $($csvFile.Name)" -ForegroundColor Yellow
        
        try {
            $csvData = Import-Csv -Path $csvFile.FullName -ErrorAction Stop
            
            if ($csvData.Count -eq 0) {
                Write-Host "    No data in file, skipping" -ForegroundColor Yellow
                continue
            }
            
            $inlineData = $csvData | ForEach-Object {
                $row = $_
                $values = ($row.PSObject.Properties | ForEach-Object { 
                    if ($null -eq $_.Value -or $_.Value -eq '') { '""' }
                    else { """$($_.Value)""" }
                }) -join ","
                $values
            }
            
            $leftChar = '<'
            $pipeChar = '|'
            $ingestOp = "$leftChar$pipeChar"
            $command = ".ingest inline into table $tableName $ingestOp `n" + ($inlineData -join "`n")
            
            $result = Invoke-KustoCommand -Command $command -Description "Importing to $tableName" -Silent
            if ($result) {
                Write-Host "    Imported $($csvData.Count) rows" -ForegroundColor Green
            } else {
                Write-Host "    Import failed" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "    Failed to read CSV: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Show-Menu {
    Show-Banner
    
    Write-Host "MAIN MENU" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "  1 - Deploy for First Time" -ForegroundColor White
    Write-Host "  2 - Purge All Table Data" -ForegroundColor White
    Write-Host "  3 - Modify tables" -ForegroundColor White
    Write-Host "  4 - Reset Docker Container" -ForegroundColor White
    Write-Host "  5 - Import CSV Data" -ForegroundColor White
    Write-Host "  6 - Exit" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Select an option"
    
    switch ($choice) {
        "1" { Deploy-FirstTime }
        "2" { Purge-AllData }
        "3" { Modify-Tables }
        "4" { Reset-DockerContainer }
        "5" { Show-Banner; Import-CSVData; Pause }
        "6" { 
            Clear-Host
            Write-Host ""
            Write-Host "Fair winds and following seas!" -ForegroundColor Cyan
            Write-Host ""
            exit 
        }
        default { 
            Write-Host ""
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

# Main loop
while ($true) {
    Show-Menu
}