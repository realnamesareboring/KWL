# Docker Profile Bypass - Manual Fix Script
# Run this as Administrator to fix existing Docker installation

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "Docker Profile Bypass - Manual Fix" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator" -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as Administrator" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Running as Administrator - OK" -ForegroundColor Green
Write-Host ""

# Step 1: Add user to docker-users group
Write-Host "Step 1: Adding user to docker-users group..." -ForegroundColor Yellow

$userName = $env:USERNAME
try {
    # Try PowerShell method first
    Add-LocalGroupMember -Group "docker-users" -Member $userName -ErrorAction Stop
    Write-Host "  ✓ Added $userName to docker-users group (PowerShell)" -ForegroundColor Green
}
catch {
    if ($_.Exception.Message -like "*already a member*") {
        Write-Host "  ✓ $userName already in docker-users group" -ForegroundColor Green
    }
    else {
        # Try net command as fallback
        $result = net localgroup docker-users $userName /add 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Added $userName to docker-users group (net command)" -ForegroundColor Green
        }
        elseif ($LASTEXITCODE -eq 2) {
            Write-Host "  ✓ $userName already in docker-users group" -ForegroundColor Green
        }
        else {
            Write-Host "  ✗ Failed to add user to group" -ForegroundColor Red
        }
    }
}

# Step 2: Stop Docker Desktop
Write-Host ""
Write-Host "Step 2: Stopping Docker Desktop..." -ForegroundColor Yellow
try {
    Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "com.docker.service" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  ✓ Docker Desktop stopped" -ForegroundColor Green
}
catch {
    Write-Host "  ! Docker may already be stopped" -ForegroundColor Yellow
}

# Step 3: Configure settings.json
Write-Host ""
Write-Host "Step 3: Configuring Docker settings..." -ForegroundColor Yellow

$dockerConfigDir = "$env:APPDATA\Docker"
if (-not (Test-Path $dockerConfigDir)) {
    New-Item -ItemType Directory -Path $dockerConfigDir -Force | Out-Null
    Write-Host "  ✓ Created Docker config directory" -ForegroundColor Green
}

$settingsPath = "$dockerConfigDir\settings.json"

# Comprehensive settings to bypass ALL onboarding
$defaultSettings = @{
    # Core bypass settings
    "autoStart" = $false
    "openUIOnStartupMode" = 0
    "showWeeklyTips" = $false
    "displayedOnboarding" = $true
    "displayedTutorial" = $true
    "licenseTermsVersion" = 2
    "analyticsEnabled" = $false
    "checkForUpdates" = $false
    
    # Sign-in bypass settings
    "skipOnboardingSignIn" = $true
    "skipSignIn" = $true
    "showSignInPrompt" = $false
    "requireSignIn" = $false
    "enableSignIn" = $false
    "displayedWelcome" = $true
    "hasSeenOnboarding" = $true
    
    # Backend configuration
    "useWSL2" = $true
    "backend" = "wsl-2"
    "wslEngineEnabled" = $true
    
    # Additional bypass flags
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
    
    # Resource settings
    "memoryMiB" = 2048
    "cpus" = 2
    "diskSizeMiB" = 65536
    
    # Disable telemetry
    "allowCollectingBrowserUsage" = $false
    "allowCollectingKubernetesUsage" = $false
    "allowCollectingUsageStatistics" = $false
    "sendUsageStatistics" = $false
    
    # Docker Hub settings
    "showDockerHubTour" = $false
    "skipDockerHubLogin" = $true
    "dockerHubUsername" = ""
    
    # Version tracking
    "settingsVersion" = 24
    "currentVersion" = "4.0.0"
    "configurationVersion" = 1
    
    # Additional control settings
    "allowExperimentalFeatures" = $false
    "displayRestartDialog" = $false
    "showSystemContainers" = $false
    "exposeDockerAPIOnTCP2375" = $false
}

# Save settings
$settingsJson = $defaultSettings | ConvertTo-Json -Depth 10
$settingsJson | Out-File -FilePath $settingsPath -Encoding UTF8 -Force
Write-Host "  ✓ Created comprehensive settings.json" -ForegroundColor Green

# Step 4: Apply registry settings
Write-Host ""
Write-Host "Step 4: Applying registry settings..." -ForegroundColor Yellow

$dockerRegPath = "HKCU:\Software\Docker Inc.\Docker Desktop"
if (-not (Test-Path $dockerRegPath)) {
    New-Item -Path $dockerRegPath -Force | Out-Null
}

# Set registry values
Set-ItemProperty -Path $dockerRegPath -Name "SkipOnboarding" -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $dockerRegPath -Name "OnboardingCompleted" -Value 1 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $dockerRegPath -Name "FirstRun" -Value 0 -Type DWord -ErrorAction SilentlyContinue
Set-ItemProperty -Path $dockerRegPath -Name "ShowSignInPrompt" -Value 0 -Type DWord -ErrorAction SilentlyContinue

Write-Host "  ✓ Applied registry bypass settings" -ForegroundColor Green

# Step 5: Remove auto-start
Write-Host ""
Write-Host "Step 5: Disabling auto-start..." -ForegroundColor Yellow

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Get-ItemProperty -Path $runKey -Name "Docker Desktop" -ErrorAction SilentlyContinue) {
    Remove-ItemProperty -Path $runKey -Name "Docker Desktop" -ErrorAction SilentlyContinue
    Write-Host "  ✓ Removed Docker from auto-start" -ForegroundColor Green
}
else {
    Write-Host "  ✓ Docker auto-start already disabled" -ForegroundColor Green
}

# Step 6: Final instructions
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "MANUAL FIX COMPLETED!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host "1. Start Docker Desktop manually" -ForegroundColor White
Write-Host "2. It should skip the sign-in prompt" -ForegroundColor White
Write-Host "3. If you still see prompts, try:" -ForegroundColor White
Write-Host "   - Click 'Skip' on any dialogs" -ForegroundColor Yellow
Write-Host "   - Click 'Continue without the service' if prompted" -ForegroundColor Yellow
Write-Host ""
Write-Host "TROUBLESHOOTING:" -ForegroundColor Cyan
Write-Host "If Docker still shows prompts:" -ForegroundColor White
Write-Host "1. Close Docker Desktop completely" -ForegroundColor White
Write-Host "2. Run this script again" -ForegroundColor White
Write-Host "3. Restart your computer" -ForegroundColor White
Write-Host "4. Try starting Docker Desktop again" -ForegroundColor White
Write-Host ""

Read-Host "Press Enter to exit"