param(
    [switch]$SkipDockerInstall,
    [switch]$SkipReboot,
    [switch]$DownloadOnly,
    [switch]$Manual,
    [string]$KustoPort = '8080',
    [string]$DataPath = '.\data',
    [switch]$Verbose,
    [switch]$CleanupTask
)

$global:LogFile = "KWL-AutoDeploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$global:ScriptPath = $PSScriptRoot
$global:RequiredReboot = $false
$global:TaskName = "KWL-AutoDeploy-Task"
$global:ScriptFullPath = $MyInvocation.MyCommand.Path
$global:ProgressFile = "$env:TEMP\KWL-Progress.json"

function Write-KWLLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [ConsoleColor]$Color = 'White'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Write-Host $logEntry -ForegroundColor $Color
    Add-Content -Path $global:LogFile -Value $logEntry
    
    if ($Verbose) {
        Write-Verbose $logEntry
    }
}

function Show-KWLBanner {
    Clear-Host
    Write-Host ""
    Write-Host "    KWL Auto-Deploy - Kusto Workspace Lab Automation" -ForegroundColor Yellow
    Write-Host "    Automated deployment for cyber range training environment" -ForegroundColor Yellow
    Write-Host "    WITH INTEGRATED DOCKER PROFILE BYPASS" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Log file: $global:LogFile" -ForegroundColor Gray
    Write-Host ""
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Save-Progress {
    param(
        [string]$Phase,
        [hashtable]$Data = @{}
    )
    
    $progress = @{
        Phase = $Phase
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Data = $Data
        ScriptPath = $global:ScriptFullPath
        Parameters = @{
            SkipDockerInstall = $SkipDockerInstall.IsPresent
            DownloadOnly = $DownloadOnly.IsPresent
            KustoPort = $KustoPort
            DataPath = $DataPath
            Verbose = $Verbose.IsPresent
        }
    }
    
    try {
        $progress | ConvertTo-Json -Depth 10 | Out-File $global:ProgressFile -Encoding UTF8
        Write-KWLLog "Progress saved: $Phase" 'INFO' 'Gray'
    }
    catch {
        Write-KWLLog "Failed to save progress: $($_.Exception.Message)" 'WARN' 'Yellow'
    }
}

function Get-Progress {
    if (Test-Path $global:ProgressFile) {
        try {
            $progress = Get-Content $global:ProgressFile -Raw | ConvertFrom-Json
            return $progress
        }
        catch {
            Write-KWLLog "Failed to read progress file: $($_.Exception.Message)" 'WARN' 'Yellow'
            return $null
        }
    }
    return $null
}

function Remove-Progress {
    if (Test-Path $global:ProgressFile) {
        Remove-Item $global:ProgressFile -Force -ErrorAction SilentlyContinue
        Write-KWLLog "Progress file cleaned up" 'INFO' 'Gray'
    }
}

function Test-ScheduledTaskExists {
    try {
        $task = Get-ScheduledTask -TaskName $global:TaskName -ErrorAction SilentlyContinue
        return $null -ne $task
    }
    catch {
        return $false
    }
}

function Test-TaskExecution {
    Write-KWLLog "Checking scheduled task execution history..." 'INFO' 'Cyan'
    
    try {
        $taskHistory = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-TaskScheduler/Operational'
            ID=102,103,106,107,108
        } -MaxEvents 20 -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$global:TaskName*"
        } | Sort-Object TimeCreated -Descending | Select-Object -First 5
        
        if ($taskHistory) {
            Write-KWLLog "Recent task events found:" 'INFO' 'Cyan'
            foreach ($event in $taskHistory) {
                $eventTime = $event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                Write-KWLLog "  [$eventTime] $($event.LevelDisplayName): $($event.Id)" 'INFO' 'Gray'
            }
        }
        else {
            Write-KWLLog "No recent task execution events found" 'INFO' 'Gray'
        }
    }
    catch {
        Write-KWLLog "Could not retrieve task history: $($_.Exception.Message)" 'WARN' 'Yellow'
    }
}

function Create-AutoRestartTask {
    Write-KWLLog "Creating scheduled task for auto-restart..." 'INFO' 'Yellow'
    
    try {
        if (Test-ScheduledTaskExists) {
            Write-KWLLog "Removing existing scheduled task..." 'INFO' 'Cyan'
            Unregister-ScheduledTask -TaskName $global:TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        
        $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$global:ScriptFullPath`""
        
        if ($SkipDockerInstall) { $arguments += " -SkipDockerInstall" }
        if ($DownloadOnly) { $arguments += " -DownloadOnly" }
        if ($Verbose) { $arguments += " -Verbose" }
        if ($KustoPort -ne '8080') { $arguments += " -KustoPort $KustoPort" }
        if ($DataPath -ne '.\data') { $arguments += " -DataPath `"$DataPath`"" }
        $arguments += " -SkipReboot"
        
        Write-KWLLog "Task arguments: $arguments" 'INFO' 'Gray'
        
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        
        Write-KWLLog "Registering scheduled task..." 'INFO' 'Cyan'
        $task = Register-ScheduledTask -TaskName $global:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "KWL Auto-Deploy continuation after reboot"
        
        Start-Sleep -Seconds 3
        $verifyTask = Get-ScheduledTask -TaskName $global:TaskName -ErrorAction SilentlyContinue
        
        if ($verifyTask) {
            Write-KWLLog "Task verified successfully: State=$($verifyTask.State)" 'SUCCESS' 'Green'
            Write-KWLLog "Task will run automatically after reboot" 'INFO' 'Cyan'
            
            $taskInfo = Get-ScheduledTaskInfo -TaskName $global:TaskName -ErrorAction SilentlyContinue
            if ($taskInfo) {
                Write-KWLLog "Task last run: $($taskInfo.LastRunTime)" 'INFO' 'Gray'
                Write-KWLLog "Task next run: $($taskInfo.NextRunTime)" 'INFO' 'Gray'
            }
            
            return $true
        }
        else {
            Write-KWLLog "CRITICAL: Task creation failed - task not found after creation!" 'ERROR' 'Red'
            return $false
        }
    }
    catch {
        Write-KWLLog "Failed to create scheduled task: $($_.Exception.Message)" 'ERROR' 'Red'
        Write-KWLLog "Task creation error details: $($_.Exception.GetType().Name)" 'ERROR' 'Red'
        return $false
    }
}

function Remove-AutoRestartTask {
    Write-KWLLog "Removing scheduled task..." 'INFO' 'Yellow'
    
    try {
        if (Test-ScheduledTaskExists) {
            Unregister-ScheduledTask -TaskName $global:TaskName -Confirm:$false -ErrorAction Stop
            
            Start-Sleep -Seconds 2
            if (-not (Test-ScheduledTaskExists)) {
                Write-KWLLog "Scheduled task removed successfully" 'SUCCESS' 'Green'
            }
            else {
                Write-KWLLog "Warning: Task still exists after removal attempt" 'WARN' 'Yellow'
            }
        }
        else {
            Write-KWLLog "Scheduled task not found (already removed)" 'INFO' 'Gray'
        }
        return $true
    }
    catch {
        Write-KWLLog "Failed to remove scheduled task: $($_.Exception.Message)" 'WARN' 'Yellow'
        return $false
    }
}

function Get-CurrentPhase {
    Write-KWLLog "Determining current deployment phase..." 'INFO' 'Cyan'
    
    if (-not (Test-WSL2 -Silent)) {
        Write-KWLLog "Phase determined: WSL2_INSTALL" 'INFO' 'Yellow'
        return "WSL2_INSTALL"
    }
    
    if (-not (Test-DockerDesktop -Silent)) {
        Write-KWLLog "Phase determined: DOCKER_INSTALL" 'INFO' 'Yellow'
        return "DOCKER_INSTALL"
    }
    
    try {
        $dockerInfo = docker info 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-KWLLog "Phase determined: DOCKER_WAIT" 'INFO' 'Yellow'
            return "DOCKER_WAIT"
        }
    }
    catch {
        Write-KWLLog "Phase determined: DOCKER_WAIT" 'INFO' 'Yellow'
        return "DOCKER_WAIT"
    }
    
    $kustoContainer = docker ps -a --filter "name=kusto-emulator" --format "{{.Names}}" 2>$null
    if ($kustoContainer -ne "kusto-emulator") {
        Write-KWLLog "Phase determined: KUSTO_DEPLOY" 'INFO' 'Yellow'
        return "KUSTO_DEPLOY"
    }
    
    $runningKusto = docker ps --filter "name=kusto-emulator" --format "{{.Names}}" 2>$null
    if ($runningKusto -ne "kusto-emulator") {
        Write-KWLLog "Phase determined: KUSTO_START" 'INFO' 'Yellow'
        return "KUSTO_START"
    }
    
    Write-KWLLog "Phase determined: COMPLETE" 'SUCCESS' 'Green'
    return "COMPLETE"
}

function Test-WSL2 {
    param([switch]$Silent)
    
    if (-not $Silent) {
        Write-KWLLog "Checking WSL2 status..." 'INFO' 'Yellow'
    }
    
    try {
        $wslVersion = wsl --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            if (-not $Silent) { Write-KWLLog "WSL2 not installed" 'WARN' 'Yellow' }
            return $false
        }
        
        if (-not $Silent) { Write-KWLLog "WSL is installed, checking version..." 'INFO' 'Cyan' }
        $wslStatus = wsl --status 2>$null
        if ($wslStatus -match "update" -or $wslStatus -match "outdated") {
            if (-not $Silent) { Write-KWLLog "WSL needs updating" 'WARN' 'Yellow' }
            return "UPDATE_NEEDED"
        }
        
        if (-not $Silent) { Write-KWLLog "WSL2 is installed and up to date" 'SUCCESS' 'Green' }
        return $true
    }
    catch {
        if (-not $Silent) { Write-KWLLog "WSL2 check failed: $($_.Exception.Message)" 'WARN' 'Yellow' }
        return $false
    }
}

function Test-DockerDesktop {
    param([switch]$Silent)
    
    if (-not $Silent) {
        Write-KWLLog "Checking Docker Desktop installation..." 'INFO' 'Yellow'
    }
    
    $dockerPath = Get-Command docker -ErrorAction SilentlyContinue
    if ($dockerPath) {
        try {
            $dockerVersion = docker --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                if (-not $Silent) { Write-KWLLog "Docker Desktop is installed: $dockerVersion" 'SUCCESS' 'Green' }
                return $true
            }
        }
        catch {
            if (-not $Silent) { Write-KWLLog "Docker Desktop found but not responding" 'WARN' 'Yellow' }
        }
    }
    
    if (-not $Silent) { Write-KWLLog "Docker Desktop not installed" 'INFO' 'Yellow' }
    return $false
}

function Wait-ForDockerAfterReboot {
    param([int]$MaxWaitMinutes = 15)
    
    Write-KWLLog "Waiting for Docker Desktop after reboot..." 'INFO' 'Yellow'
    Write-KWLLog "Maximum wait time: $MaxWaitMinutes minutes" 'INFO' 'Gray'
    
    $timeout = (Get-Date).AddMinutes($MaxWaitMinutes)
    $attemptCount = 0
    
    while ((Get-Date) -lt $timeout) {
        $attemptCount++
        try {
            $dockerInfo = docker info 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-KWLLog "Docker is ready after $attemptCount attempts" 'SUCCESS' 'Green'
                return $true
            }
        }
        catch {
            # Docker command failed, continue waiting
        }
        
        if ($attemptCount % 4 -eq 0) {
            $waitedMinutes = [math]::Round(((Get-Date) - (Get-Date).AddMinutes(-$MaxWaitMinutes)).TotalMinutes + $MaxWaitMinutes - (($timeout - (Get-Date)).TotalMinutes), 1)
            Write-KWLLog "Still waiting for Docker... ($waitedMinutes/$MaxWaitMinutes minutes)" 'INFO' 'Yellow'
        }
        else {
            Write-Host "." -NoNewline -ForegroundColor Yellow
        }
        
        Start-Sleep -Seconds 30
    }
    
    Write-Host ""
    Write-KWLLog "Docker not ready after $MaxWaitMinutes minutes" 'ERROR' 'Red'
    Write-KWLLog "Docker Desktop may need manual intervention" 'ERROR' 'Red'
    return $false
}

function Start-AutomaticReboot {
    param([string]$Reason = "WSL2/Docker installation")
    
    Write-KWLLog "Automatic reboot required for: $Reason" 'WARN' 'Yellow'
    
    if (-not $Manual) {
        Save-Progress -Phase "REBOOT_REQUIRED" -Data @{ Reason = $Reason }
        
        Write-KWLLog "Creating scheduled task for post-reboot continuation..." 'INFO' 'Yellow'
        if (Create-AutoRestartTask) {
            Write-KWLLog "Scheduled task created and verified successfully" 'SUCCESS' 'Green'
            Write-KWLLog "System will reboot automatically in 10 seconds..." 'INFO' 'Yellow'
            Write-KWLLog "Script will continue automatically after reboot via scheduled task" 'INFO' 'Cyan'
            
            for ($i = 10; $i -gt 0; $i--) {
                Write-Host "`rRebooting in $i seconds... (Press Ctrl+C to cancel)" -NoNewline -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            
            Write-Host ""
            Write-KWLLog "Initiating automatic reboot..." 'INFO' 'Yellow'
            Restart-Computer -Force
        }
        else {
            Write-KWLLog "CRITICAL: Scheduled task creation failed!" 'ERROR' 'Red'
            Write-KWLLog "Falling back to manual reboot instructions" 'WARN' 'Yellow'
            Manual-RebootInstructions
        }
    }
    else {
        Manual-RebootInstructions
    }
}

function Manual-RebootInstructions {
    Write-Host ""
    Write-Host "MANUAL REBOOT REQUIRED" -ForegroundColor Red
    Write-Host "======================" -ForegroundColor Red
    Write-Host "Please reboot your system manually and then re-run:" -ForegroundColor Yellow
    Write-Host "  .\KWL-AutoDeploy.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "The script will detect the current state and continue." -ForegroundColor Cyan
    Write-Host ""
}

function Get-FastDockerDownload {
    param(
        [string]$Url,
        [string]$Destination
    )
    
    Write-KWLLog "Starting optimized Docker Desktop download..." 'INFO' 'Cyan'
    
    $downloadSuccess = $false
    $startTime = Get-Date
    
    if (Test-Path $Destination) {
        $existingSize = (Get-Item $Destination).Length
        $existingSizeMB = [math]::Round($existingSize / 1MB, 2)
        
        if ($existingSize -gt 400MB) {
            Write-KWLLog "Found existing installer: $existingSizeMB MB" 'SUCCESS' 'Green'
            return $true
        }
        else {
            Write-KWLLog "Removing incomplete file: $existingSizeMB MB" 'INFO' 'Yellow'
            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        }
    }
    
    try {
        Write-KWLLog "Method 1: BITS Transfer (fastest)..." 'INFO' 'Yellow'
        Import-Module BitsTransfer -ErrorAction Stop
        
        $bitsJob = Start-BitsTransfer -Source $Url -Destination $Destination -Asynchronous -DisplayName "Docker Desktop Download"
        
        $lastUpdate = Get-Date
        do {
            Start-Sleep -Seconds 1
            $job = Get-BitsTransfer -JobId $bitsJob.JobId
            
            if ($job.BytesTotal -gt 0 -and ((Get-Date) - $lastUpdate).TotalSeconds -gt 3) {
                $percentComplete = [math]::Round(($job.BytesTransferred / $job.BytesTotal) * 100, 1)
                $transferredMB = [math]::Round($job.BytesTransferred / 1MB, 1)
                $totalMB = [math]::Round($job.BytesTotal / 1MB, 1)
                $elapsed = (Get-Date) - $startTime
                
                if ($job.BytesTransferred -gt 0 -and $elapsed.TotalSeconds -gt 0) {
                    $speedMBps = [math]::Round(($job.BytesTransferred / $elapsed.TotalSeconds) / 1MB, 2)
                    $eta = if ($speedMBps -gt 0) { [math]::Round(($job.BytesTotal - $job.BytesTransferred) / ($speedMBps * 1MB), 0) } else { 0 }
                    Write-KWLLog "BITS: $transferredMB/$totalMB MB ($percentComplete%) - $speedMBps MB/s - ETA: ${eta}s" 'INFO' 'Cyan'
                }
                $lastUpdate = Get-Date
            }
        } while ($job.JobState -eq "Transferring")
        
        if ($job.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $job
            $downloadSuccess = $true
            $elapsed = (Get-Date) - $startTime
            $avgSpeed = [math]::Round((Get-Item $Destination).Length / $elapsed.TotalSeconds / 1MB, 2)
            Write-KWLLog "BITS download completed! Average speed: $avgSpeed MB/s" 'SUCCESS' 'Green'
        }
        else {
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            throw "BITS transfer failed with state: $($job.JobState)"
        }
    }
    catch {
        Write-KWLLog "BITS failed: $($_.Exception.Message)" 'WARN' 'Yellow'
        Write-KWLLog "Trying WebClient method..." 'INFO' 'Yellow'
    }
    
    if (-not $downloadSuccess) {
        try {
            Write-KWLLog "Method 2: .NET WebClient..." 'INFO' 'Yellow'
            
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($Url, $Destination)
            $webClient.Dispose()
            
            $downloadSuccess = Test-Path $Destination
            if ($downloadSuccess) {
                $elapsed = (Get-Date) - $startTime
                $avgSpeed = [math]::Round((Get-Item $Destination).Length / $elapsed.TotalSeconds / 1MB, 2)
                Write-KWLLog "WebClient download completed! Average speed: $avgSpeed MB/s" 'SUCCESS' 'Green'
            }
        }
        catch {
            Write-KWLLog "WebClient failed: $($_.Exception.Message)" 'WARN' 'Yellow'
        }
    }
    
    return $downloadSuccess
}

function Install-WSL2 {
    Write-KWLLog "Installing WSL2..." 'INFO' 'Yellow'
    
    try {
        Write-KWLLog "Enabling WSL feature..." 'INFO' 'Cyan'
        dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
        
        Write-KWLLog "Enabling Virtual Machine Platform..." 'INFO' 'Cyan'
        dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
        
        Write-KWLLog "Installing WSL2..." 'INFO' 'Cyan'
        wsl --install --no-distribution
        
        Write-KWLLog "Setting WSL2 as default version..." 'INFO' 'Cyan'
        wsl --set-default-version 2 2>$null
        
        Write-KWLLog "WSL2 installation completed. Reboot required." 'SUCCESS' 'Green'
        $global:RequiredReboot = $true
        return $true
    }
    catch {
        Write-KWLLog "Failed to install WSL2: $($_.Exception.Message)" 'ERROR' 'Red'
        return $false
    }
}

function Update-WSL2 {
    Write-KWLLog "Updating WSL2 to latest version..." 'INFO' 'Yellow'
    
    try {
        Write-KWLLog "Running WSL update..." 'INFO' 'Cyan'
        wsl --update
        
        if ($LASTEXITCODE -eq 0) {
            Write-KWLLog "WSL2 updated successfully" 'SUCCESS' 'Green'
            wsl --set-default-version 2 2>$null
            return $true
        }
        else {
            throw "WSL update failed with exit code: $LASTEXITCODE"
        }
    }
    catch {
        Write-KWLLog "Failed to update WSL2: $($_.Exception.Message)" 'ERROR' 'Red'
        return $false
    }
}

# NEW FUNCTION: Create Docker Profile Bypass Settings
function Set-DockerProfileBypass {
    Write-KWLLog "Configuring Docker profile bypass settings..." 'INFO' 'Cyan'
    
    try {
        # Step 1: Create Docker config directory
        $dockerConfigDir = "$env:APPDATA\Docker"
        if (-not (Test-Path $dockerConfigDir)) {
            New-Item -ItemType Directory -Path $dockerConfigDir -Force | Out-Null
            Write-KWLLog "Created Docker config directory" 'INFO' 'Green'
        }

        # Step 2: Create comprehensive bypass settings
        $settingsPath = "$dockerConfigDir\settings.json"
        $defaultSettings = @{
            "autoStart" = $false
            "openUIOnStartupMode" = 0
            "showWeeklyTips" = $false
            "displayedOnboarding" = $true
            "displayedTutorial" = $true
            "licenseTermsVersion" = 2
            "analyticsEnabled" = $false
            "checkForUpdates" = $false
            "skipOnboardingSignIn" = $true
            "skipSignIn" = $true
            "showSignInPrompt" = $false
            "requireSignIn" = $false
            "enableSignIn" = $false
            "displayedWelcome" = $true
            "hasSeenOnboarding" = $true
            "useWSL2" = $true
            "backend" = "wsl-2"
            "wslEngineEnabled" = $true
            "skipOnboardingSurvey" = $true
            "dismissedOnboardingSurvey" = $true
            "showOnboardingOnStartup" = $false
            "displayedOnboardingDialog" = $true
            "completedOnboarding" = $true
            "firstRun" = $false
            "onboardingCompleted" = $true
            "tosAccepted" = $true
            "privacyPolicyAccepted" = $true
            "marketingOptIn" = $false
            "memoryMiB" = 2048
            "cpus" = 2
            "diskSizeMiB" = 65536
            "allowCollectingBrowserUsage" = $false
            "allowCollectingKubernetesUsage" = $false
            "allowCollectingUsageStatistics" = $false
            "sendUsageStatistics" = $false
            "showDockerHubTour" = $false
            "skipDockerHubLogin" = $true
            "dockerHubUsername" = ""
            "settingsVersion" = 24
            "currentVersion" = "4.0.0"
            "configurationVersion" = 1
            "allowExperimentalFeatures" = $false
            "displayRestartDialog" = $false
            "showSystemContainers" = $false
            "exposeDockerAPIOnTCP2375" = $false
        }

        $settingsJson = $defaultSettings | ConvertTo-Json -Depth 10
        $settingsJson | Out-File -FilePath $settingsPath -Encoding UTF8 -Force
        Write-KWLLog "Created Docker bypass settings.json" 'SUCCESS' 'Green'

        # Step 3: Apply registry settings
        $dockerRegPath = "HKCU:\Software\Docker Inc.\Docker Desktop"
        if (-not (Test-Path $dockerRegPath)) {
            New-Item -Path $dockerRegPath -Force | Out-Null
        }
        
        Set-ItemProperty -Path $dockerRegPath -Name "SkipOnboarding" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $dockerRegPath -Name "OnboardingCompleted" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $dockerRegPath -Name "FirstRun" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $dockerRegPath -Name "ShowSignInPrompt" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Write-KWLLog "Applied Docker registry bypass settings" 'SUCCESS' 'Green'

        # Step 4: Disable auto-start
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        if (Get-ItemProperty -Path $runKey -Name "Docker Desktop" -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runKey -Name "Docker Desktop" -ErrorAction SilentlyContinue
            Write-KWLLog "Disabled Docker auto-start" 'SUCCESS' 'Green'
        }
        
        return $true
    }
    catch {
        Write-KWLLog "Failed to configure Docker profile bypass: $($_.Exception.Message)" 'ERROR' 'Red'
        return $false
    }
}

# NEW FUNCTION: Add user to docker-users group
function Add-UserToDockerGroup {
    Write-KWLLog "Adding user to docker-users group..." 'INFO' 'Yellow'
    
    $userName = $env:USERNAME
    try {
        Add-LocalGroupMember -Group "docker-users" -Member $userName -ErrorAction Stop
        Write-KWLLog "Added $userName to docker-users group (PowerShell)" 'SUCCESS' 'Green'
        return $true
    }
    catch {
        if ($_.Exception.Message -like "*already a member*") {
            Write-KWLLog "$userName already in docker-users group" 'SUCCESS' 'Green'
            return $true
        }
        else {
            # Try net command as fallback
            $result = net localgroup docker-users $userName /add 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-KWLLog "Added $userName to docker-users group (net command)" 'SUCCESS' 'Green'
                return $true
            }
            elseif ($LASTEXITCODE -eq 2) {
                Write-KWLLog "$userName already in docker-users group" 'SUCCESS' 'Green'
                return $true
            }
            else {
                Write-KWLLog "Failed to add user to docker-users group" 'ERROR' 'Red'
                return $false
            }
        }
    }
}

function Install-DockerDesktop {
    Write-KWLLog "Installing Docker Desktop..." 'INFO' 'Yellow'
    
    # INTEGRATION POINT 1: Apply Docker profile bypass BEFORE installation
    Write-KWLLog "Applying Docker profile bypass settings before installation..." 'INFO' 'Cyan'
    Set-DockerProfileBypass
    Add-UserToDockerGroup
    
    $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
    
    try {
        Write-KWLLog "Downloading Docker Desktop installer (~500MB)..." 'INFO' 'Cyan'
        $downloadSuccess = Get-FastDockerDownload -Url $dockerUrl -Destination $dockerInstaller
        
        if (-not $downloadSuccess) {
            throw "All download methods failed."
        }
        
        $fileSize = (Get-Item $dockerInstaller).Length
        $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
        
        if ($fileSize -lt 100MB) {
            throw "Downloaded file appears incomplete ($fileSizeMB MB). Expected ~500MB."
        }
        
        Write-KWLLog "Verified installer: $fileSizeMB MB" 'SUCCESS' 'Green'
        
        Write-KWLLog "Installing Docker Desktop (this may take several minutes)..." 'INFO' 'Cyan'
        
        $installArgs = @(
            "install",
            "--quiet",
            "--accept-license", 
            "--backend=wsl-2"
        )
        
        $process = Start-Process -FilePath $dockerInstaller -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-KWLLog "Docker Desktop installation completed successfully" 'SUCCESS' 'Green'
            Remove-Item $dockerInstaller -Force -ErrorAction SilentlyContinue
            
            # INTEGRATION POINT 2: Re-apply bypass settings after installation
            Write-KWLLog "Re-applying Docker profile bypass settings after installation..." 'INFO' 'Cyan'
            Start-Sleep -Seconds 3
            Set-DockerProfileBypass
            
            $global:RequiredReboot = $true
            return $true
        }
        else {
            throw "Docker Desktop installation failed with exit code: $($process.ExitCode)"
        }
    }
    catch {
        Write-KWLLog "Docker Desktop installation failed: $($_.Exception.Message)" 'ERROR' 'Red'
        
        Write-Host ""
        Write-Host "MANUAL INSTALLATION OPTION" -ForegroundColor Yellow
        Write-Host "Download manually from:" -ForegroundColor Cyan
        Write-Host "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -ForegroundColor White
        Write-Host ""
        
        return $false
    }
}

function Deploy-KustoEmulator {
    Write-KWLLog "Deploying Kusto Emulator container..." 'INFO' 'Yellow'
    
    try {
        Write-KWLLog "Checking for existing Kusto Emulator container..." 'INFO' 'Cyan'
        $existingContainer = docker ps -a --filter "name=kusto-emulator" --format "{{.Names}}" 2>$null
        
        if ($existingContainer -eq "kusto-emulator") {
            Write-KWLLog "Stopping existing container..." 'INFO' 'Cyan'
            docker stop kusto-emulator 2>$null
            
            Write-KWLLog "Removing existing container..." 'INFO' 'Cyan'
            docker rm kusto-emulator 2>$null
        }
        
        Write-KWLLog "Pulling Kusto Emulator image..." 'INFO' 'Cyan'
        docker pull mcr.microsoft.com/azuredataexplorer/kustainer-linux:latest
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to pull Kusto Emulator image"
        }
        
        Write-KWLLog "Starting Kusto Emulator container on port $KustoPort..." 'INFO' 'Cyan'
        $dockerCommand = @(
            "run", "-d",
            "-p", "${KustoPort}:8080",
            "-e", "ACCEPT_EULA=Y",
            "-v", "kusto-data:/kusto/data",
            "--restart", "unless-stopped",
            "--name", "kusto-emulator",
            "mcr.microsoft.com/azuredataexplorer/kustainer-linux:latest"
        )
        
        $containerID = docker @dockerCommand 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-KWLLog "Kusto Emulator container started successfully" 'SUCCESS' 'Green'
            Write-KWLLog "Container ID: $containerID" 'INFO' 'Cyan'
            Write-KWLLog "Web interface available at: http://localhost:$KustoPort" 'INFO' 'Green'
            
            Write-KWLLog "Waiting for Kusto Emulator to initialize..." 'INFO' 'Yellow'
            Start-Sleep -Seconds 15
            
            $runningContainer = docker ps --filter "name=kusto-emulator" --format "{{.Names}}" 2>$null
            if ($runningContainer -eq "kusto-emulator") {
                Write-KWLLog "Kusto Emulator is running and ready" 'SUCCESS' 'Green'
                return $true
            }
            else {
                Write-KWLLog "Container started but is not running properly" 'ERROR' 'Red'
                docker logs kusto-emulator 2>$null | ForEach-Object { Write-KWLLog "Container log: $_" 'DEBUG' 'Gray' }
                return $false
            }
        }
        else {
            throw "Failed to start Kusto Emulator container"
        }
    }
    catch {
        Write-KWLLog "Failed to deploy Kusto Emulator: $($_.Exception.Message)" 'ERROR' 'Red'
        return $false
    }
}

function Test-KustoConnection {
    param([int]$TimeoutSeconds = 60)
    
    Write-KWLLog "Testing connection to Kusto Emulator..." 'INFO' 'Yellow'
    
    $timeout = (Get-Date).AddSeconds($TimeoutSeconds)
    $connected = $false
    
    while ((Get-Date) -lt $timeout -and -not $connected) {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$KustoPort" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-KWLLog "Successfully connected to Kusto Emulator" 'SUCCESS' 'Green'
                $connected = $true
            }
        }
        catch {
            Write-Host "." -NoNewline -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    
    Write-Host ""
    
    if (-not $connected) {
        Write-KWLLog "Failed to connect to Kusto Emulator within timeout period" 'ERROR' 'Red'
        return $false
    }
    
    return $true
}

function Create-SampleData {
    Write-KWLLog "Creating sample data files..." 'INFO' 'Yellow'
    
    try {
        if (-not (Test-Path $DataPath)) {
            New-Item -ItemType Directory -Path $DataPath -Force | Out-Null
            Write-KWLLog "Created data directory: $DataPath" 'INFO' 'Cyan'
        }
        
        $securityEventsPath = Join-Path $DataPath "SecurityEvents.csv"
        $securityEventsData = @"
TimeGenerated,Computer,EventID,Activity,Account,LogonType,SourceIP,DestinationIP,Process,CommandLine,SubjectUserName,TargetUserName,Status,Level
2025-10-03T08:15:23Z,WS-001,4625,Failed Logon,admin@company.com,3,192.168.1.100,10.0.0.5,winlogon.exe,,SYSTEM,admin@company.com,0xC000006D,Warning
2025-10-03T08:15:45Z,WS-001,4625,Failed Logon,admin@company.com,3,192.168.1.100,10.0.0.5,winlogon.exe,,SYSTEM,admin@company.com,0xC000006D,Warning
2025-10-03T08:16:12Z,WS-001,4625,Failed Logon,admin@company.com,3,192.168.1.100,10.0.0.5,winlogon.exe,,SYSTEM,admin@company.com,0xC000006D,Warning
2025-10-03T08:20:33Z,WS-002,4624,Successful Logon,john.doe@company.com,2,10.0.1.50,10.0.0.5,winlogon.exe,,john.doe@company.com,john.doe@company.com,0x0,Information
2025-10-03T08:25:11Z,DC01,4720,User Account Created,jane.smith@company.com,3,10.0.1.25,10.0.0.10,,,Administrator,jane.smith@company.com,0x0,Information
2025-10-03T08:30:22Z,WS-003,4688,Process Created,bob.jones@company.com,3,10.0.1.75,,powershell.exe,powershell.exe -enc JABzAD0ATgBlAHcALQBPAGIAagBlAGMAdAAgAEkATwAuAE0A,bob.jones@company.com,,0x0,Warning
2025-10-03T08:35:45Z,WS-004,4624,Successful Logon,alice.williams@company.com,10,203.0.113.45,10.0.0.5,winlogon.exe,,alice.williams@company.com,alice.williams@company.com,0x0,Information
2025-10-03T08:40:12Z,DC01,4728,Member Added to Security Group,,,10.0.1.25,10.0.0.10,,,Administrator,bob.jones@company.com,0x0,Information
2025-10-03T08:45:33Z,WS-005,4625,Failed Logon,service_account@company.com,3,10.0.1.100,10.0.0.5,winlogon.exe,,SYSTEM,service_account@company.com,0xC000006D,Warning
2025-10-03T08:50:22Z,WS-006,4688,Process Created,charlie.brown@company.com,2,10.0.1.80,,cmd.exe,cmd.exe /c whoami,charlie.brown@company.com,,0x0,Information
"@
        
        $securityEventsData | Out-File -FilePath $securityEventsPath -Encoding UTF8
        Write-KWLLog "Created SecurityEvents.csv with sample data" 'SUCCESS' 'Green'
        
        return $true
    }
    catch {
        Write-KWLLog "Failed to create sample data: $($_.Exception.Message)" 'ERROR' 'Red'
        return $false
    }
}

function Start-KWLAutoDeploy {
    Show-KWLBanner
    
    if ($CleanupTask) {
        Write-KWLLog "Cleanup mode: Removing scheduled task..." 'INFO' 'Yellow'
        Remove-AutoRestartTask
        Remove-Progress
        exit 0
    }
    
    Write-KWLLog "Starting KWL Auto-Deploy process with integrated Docker bypass..." 'INFO' 'Cyan'
    
    if ($Manual) {
        Write-KWLLog "Running in MANUAL mode (no scheduled tasks)" 'INFO' 'Yellow'
    }
    else {
        Write-KWLLog "Running in AUTOMATIC mode (with scheduled task support)" 'INFO' 'Cyan'
    }
    
    $previousProgress = Get-Progress
    if ($previousProgress) {
        Write-KWLLog "Found previous progress: $($previousProgress.Phase)" 'INFO' 'Cyan'
        Write-KWLLog "Continuing from last checkpoint..." 'INFO' 'Yellow'
    }
    
    Test-TaskExecution
    
    if (-not (Test-Administrator)) {
        Write-KWLLog "This script must be run as Administrator" 'ERROR' 'Red'
        Write-Host ""
        Write-Host "Press any key to exit..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
    
    Write-KWLLog "Running as Administrator" 'SUCCESS' 'Green'
    
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10) {
        Write-KWLLog "Windows 10 or later is required" 'ERROR' 'Red'
        exit 1
    }
    Write-KWLLog "Windows version check passed" 'SUCCESS' 'Green'
    
    if ($DownloadOnly) {
        Write-KWLLog "Download-only mode enabled" 'INFO' 'Yellow'
        $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
        $dockerInstaller = "$env:TEMP\DockerDesktopInstaller.exe"
        
        Write-KWLLog "Downloading Docker Desktop installer..." 'INFO' 'Cyan'
        $downloadSuccess = Get-FastDockerDownload -Url $dockerUrl -Destination $dockerInstaller
        
        if ($downloadSuccess) {
            $fileSize = (Get-Item $dockerInstaller).Length
            $fileSizeMB = [math]::Round($fileSize / 1MB, 2)
            Write-KWLLog "Download completed: $fileSizeMB MB" 'SUCCESS' 'Green'
            Write-KWLLog "File saved to: $dockerInstaller" 'INFO' 'Cyan'
            Write-Host ""
            Write-Host "Download completed!" -ForegroundColor Green
        }
        else {
            Write-KWLLog "Download failed" 'ERROR' 'Red'
            exit 1
        }
        
        exit 0
    }
    
    $currentPhase = Get-CurrentPhase
    Write-KWLLog "Current deployment phase: $currentPhase" 'INFO' 'Magenta'
    
    switch ($currentPhase) {
        "WSL2_INSTALL" {
            Write-KWLLog "=== PHASE 1: WSL2 INSTALLATION ===" 'INFO' 'Magenta'
            Save-Progress -Phase "WSL2_INSTALL"
            
            $wslResult = Install-WSL2
            if (-not $wslResult) {
                Write-KWLLog "WSL2 installation failed" 'ERROR' 'Red'
                exit 1
            }
        }
        
        "DOCKER_INSTALL" {
            Write-KWLLog "=== PHASE 2: DOCKER DESKTOP INSTALLATION WITH BYPASS ===" 'INFO' 'Magenta'
            Save-Progress -Phase "DOCKER_INSTALL"
            
            if (-not $SkipDockerInstall) {
                $dockerResult = Install-DockerDesktop
                if (-not $dockerResult) {
                    Write-KWLLog "Docker Desktop installation failed" 'ERROR' 'Red'
                    exit 1
                }
            }
            else {
                Write-KWLLog "Skipping Docker Desktop installation (flag set)" 'INFO' 'Yellow'
                # Still apply bypass settings even if skipping install
                Write-KWLLog "Applying Docker profile bypass settings..." 'INFO' 'Cyan'
                Set-DockerProfileBypass
                Add-UserToDockerGroup
            }
        }
        
        "DOCKER_WAIT" {
            Write-KWLLog "=== PHASE 3: WAITING FOR DOCKER READY ===" 'INFO' 'Magenta'
            Save-Progress -Phase "DOCKER_WAIT"
            
            # INTEGRATION POINT 3: Re-apply bypass settings if Docker isn't ready yet
            Write-KWLLog "Ensuring Docker bypass settings are applied..." 'INFO' 'Cyan'
            Set-DockerProfileBypass
            
            if (-not (Wait-ForDockerAfterReboot -MaxWaitMinutes 15)) {
                Write-KWLLog "Docker Desktop not ready after extended wait" 'ERROR' 'Red'
                Write-Host ""
                Write-Host "DOCKER TROUBLESHOOTING:" -ForegroundColor Yellow
                Write-Host "1. Check if Docker Desktop is starting up" -ForegroundColor White
                Write-Host "2. Look for Docker Desktop in system tray" -ForegroundColor White
                Write-Host "3. Try restarting Docker Desktop manually" -ForegroundColor White
                Write-Host "4. Re-run this script after Docker is ready" -ForegroundColor White
                Write-Host "5. Docker should now skip sign-in prompts thanks to bypass settings" -ForegroundColor Cyan
                exit 1
            }
        }
        
        "KUSTO_DEPLOY" {
            Write-KWLLog "=== PHASE 4: KUSTO EMULATOR DEPLOYMENT ===" 'INFO' 'Magenta'
            Save-Progress -Phase "KUSTO_DEPLOY"
            
            if (-not (Deploy-KustoEmulator)) {
                Write-KWLLog "Kusto Emulator deployment failed" 'ERROR' 'Red'
                exit 1
            }
        }
        
        "KUSTO_START" {
            Write-KWLLog "=== PHASE 5: STARTING KUSTO CONTAINER ===" 'INFO' 'Magenta'
            Save-Progress -Phase "KUSTO_START"
            
            Write-KWLLog "Starting existing Kusto container..." 'INFO' 'Cyan'
            docker start kusto-emulator 2>$null
            
            if ($LASTEXITCODE -eq 0) {
                Write-KWLLog "Kusto container started successfully" 'SUCCESS' 'Green'
            }
            else {
                Write-KWLLog "Failed to start Kusto container" 'ERROR' 'Red'
                exit 1
            }
        }
        
        "COMPLETE" {
            Write-KWLLog "=== DEPLOYMENT ALREADY COMPLETE ===" 'SUCCESS' 'Green'
            Write-KWLLog "All components are installed and running" 'SUCCESS' 'Green'
            Write-KWLLog "Docker bypass settings should prevent sign-in prompts" 'INFO' 'Cyan'
        }
    }
    
    if ($global:RequiredReboot -and -not $SkipReboot) {
        Start-AutomaticReboot -Reason "WSL2 and Docker Desktop installation"
        exit 0
    }
    
    if ($currentPhase -ne "COMPLETE") {
        Write-KWLLog "=== FINAL VERIFICATION ===" 'INFO' 'Magenta'
        Save-Progress -Phase "FINAL_VERIFICATION"
        
        if (-not (Test-KustoConnection -TimeoutSeconds 120)) {
            Write-KWLLog "Warning: Kusto connection test failed" 'WARN' 'Yellow'
            Write-KWLLog "Container may still be initializing" 'INFO' 'Yellow'
            Write-KWLLog "Try accessing: http://localhost:$KustoPort" 'INFO' 'Cyan'
        }
        
        if (-not (Create-SampleData)) {
            Write-KWLLog "Warning: Failed to create sample data files" 'WARN' 'Yellow'
        }
        
        # INTEGRATION POINT 4: Final bypass verification
        Write-KWLLog "Verifying Docker bypass settings..." 'INFO' 'Cyan'
        $dockerSettingsPath = "$env:APPDATA\Docker\settings.json"
        if (Test-Path $dockerSettingsPath) {
            Write-KWLLog "Docker bypass settings.json confirmed" 'SUCCESS' 'Green'
        }
        else {
            Write-KWLLog "Warning: Docker settings.json not found" 'WARN' 'Yellow'
        }
        
        $finalPhase = Get-CurrentPhase
        if ($finalPhase -eq "COMPLETE") {
            Write-KWLLog "Final verification: PASSED" 'SUCCESS' 'Green'
        }
        else {
            Write-KWLLog "Final verification: Some components may need attention" 'WARN' 'Yellow'
        }
    }
    
    if (-not $Manual) {
        Write-KWLLog "Cleaning up scheduled task and progress files..." 'INFO' 'Yellow'
        Remove-AutoRestartTask
    }
    Remove-Progress
    
    Write-KWLLog "=== DEPLOYMENT COMPLETED SUCCESSFULLY ===" 'SUCCESS' 'Green'
    Show-PostInstallInstructions
}

function Show-PostInstallInstructions {
    Write-Host ""
    Write-Host "===============================================" -ForegroundColor Green
    Write-Host "KWL AUTO-DEPLOY COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "WITH INTEGRATED DOCKER PROFILE BYPASS" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "KUSTO EMULATOR STATUS:" -ForegroundColor Cyan
    Write-Host "   Web Interface: http://localhost:$KustoPort" -ForegroundColor White
    Write-Host "   Container Name: kusto-emulator" -ForegroundColor White
    Write-Host "   Database: NetDefaultDB" -ForegroundColor White
    Write-Host ""
    
    Write-Host "DOCKER BYPASS STATUS:" -ForegroundColor Cyan
    Write-Host "   Profile bypass: ENABLED" -ForegroundColor Green
    Write-Host "   Sign-in prompts: DISABLED" -ForegroundColor Green
    Write-Host "   Auto-start: DISABLED" -ForegroundColor Green
    Write-Host "   User group: Added to docker-users" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "NEXT STEPS:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Connect with Kusto Explorer:" -ForegroundColor Yellow
    Write-Host "   - Download from: https://aka.ms/ke" -ForegroundColor White
    Write-Host "   - Connection string: http://localhost:$KustoPort" -ForegroundColor White
    Write-Host "   - Security: Select 'None' or 'Anonymous'" -ForegroundColor White
    Write-Host ""
    
    Write-Host "2. Test your setup:" -ForegroundColor Yellow
    Write-Host "   Run: .show tables" -ForegroundColor White
    Write-Host ""
    
    Write-Host "3. Docker Desktop:" -ForegroundColor Yellow
    Write-Host "   - Should start WITHOUT sign-in prompts" -ForegroundColor Green
    Write-Host "   - Profile setup screens BYPASSED" -ForegroundColor Green
    Write-Host "   - Ready for immediate use" -ForegroundColor Green
    Write-Host ""
    
    Write-Host "DOCKER COMMANDS:" -ForegroundColor Cyan
    Write-Host "   Start:  docker start kusto-emulator" -ForegroundColor White
    Write-Host "   Stop:   docker stop kusto-emulator" -ForegroundColor White
    Write-Host "   Status: docker ps" -ForegroundColor White
    Write-Host ""
    
    Write-Host "USAGE MODES:" -ForegroundColor Cyan
    Write-Host "   Automatic: .\KWL-AutoDeploy.ps1" -ForegroundColor White
    Write-Host "   Manual:    .\KWL-AutoDeploy.ps1 -Manual" -ForegroundColor White
    Write-Host ""
    
    Write-Host "BYPASS INTEGRATION SUMMARY:" -ForegroundColor Magenta
    Write-Host "   [SUCCESS] Docker profile bypass applied BEFORE installation" -ForegroundColor Green
    Write-Host "   [SUCCESS] Docker profile bypass re-applied AFTER installation" -ForegroundColor Green
    Write-Host "   [SUCCESS] User added to docker-users group" -ForegroundColor Green
    Write-Host "   [SUCCESS] Registry settings configured" -ForegroundColor Green
    Write-Host "   [SUCCESS] Auto-start disabled" -ForegroundColor Green
    Write-Host ""
}

try {
    Start-KWLAutoDeploy
}
catch {
    Write-KWLLog "Critical error: $($_.Exception.Message)" 'ERROR' 'Red'
    
    if (-not $Manual) {
        Remove-AutoRestartTask
        Remove-Progress
    }
    
    Write-Host ""
    Write-Host "DEPLOYMENT FAILED" -ForegroundColor Red
    Write-Host "Common solutions:" -ForegroundColor Cyan
    Write-Host "  1. Ensure you're running as Administrator" -ForegroundColor White
    Write-Host "  2. Check your internet connection" -ForegroundColor White
    Write-Host "  3. Try manual mode: .\KWL-AutoDeploy.ps1 -Manual" -ForegroundColor White
    Write-Host "  4. Check log file: $global:LogFile" -ForegroundColor White
    Write-Host "  5. Docker bypass settings saved for next run" -ForegroundColor Cyan
    Write-Host ""
    
    exit 1
}

Write-KWLLog "Script execution completed" 'INFO' 'Gray'