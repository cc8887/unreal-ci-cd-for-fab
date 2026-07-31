<#
.SYNOPSIS
    A fast pipeline to build and package a plugin for multiple engine versions.
.DESCRIPTION
    This script automates the compilation and packaging of an Unreal Engine plugin,
    producing clean, marketplace-ready .zip files for each specified engine version.
    It uses smart copying to exclude .git, build artifacts, and other unnecessary files
    for faster, cleaner builds.
.PARAMETER OutputDirectory
    Optional. Specifies the output directory for build artifacts. If not provided, 
    creates a timestamped directory in the project root.
.NOTES
    Author: Prajwal Shetty
    Version: 1.10 - Fixed output directory structure and added parameter support
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [string]$EngineVersion,

    [Parameter(Mandatory=$false)]
    [switch]$UseCache,

    [Parameter(Mandatory=$true)]
    [string]$ConfigPath
)

# --- PREPARATION ---
$ScriptDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $ScriptDir
$GlobalSuccess = $true

# Load configuration
if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found at '$ConfigPath'."
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# Get Plugin Version from .uplugin file
$SourceUpluginPath = Join-Path -Path $Config.PluginSourceDirectory -ChildPath "$($Config.PluginName).uplugin"
if (-not (Test-Path $SourceUpluginPath)) {
    Write-Error "Could not find source .uplugin file at '$SourceUpluginPath'. Check your 'PluginSourceDirectory' and 'PluginName' in config.json."
    exit 1
}
$PluginInfo = Get-Content -Raw -Path $SourceUpluginPath | ConvertFrom-Json
$PluginVersion = $PluginInfo.VersionName

# --- Create output directory ---
if ($OutputDirectory) {
    $OutputBuildsDir = $OutputDirectory
} else {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputBuildsDir = Join-Path -Path $ProjectRoot -ChildPath "$($Config.OutputDirectory)_$Timestamp"
}
$LogsDir = Join-Path -Path $ProjectRoot -ChildPath "Logs"
New-Item -Path $OutputBuildsDir -ItemType Directory -Force | Out-Null
New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null

# --- MAIN EXECUTION LOOP ---
Write-Host "=================================================================" -ForegroundColor Green
Write-Host " STARTING FAST PLUGIN PACKAGING PIPELINE (Fab Upload)" -ForegroundColor Green
Write-Host "================================================================="
Write-Host "Plugin: $($Config.PluginName) v$($PluginVersion)"
Write-Host "Outputting to: $OutputBuildsDir"

# Determine which engine versions to process
$VersionsToProcess = if (-not [string]::IsNullOrEmpty($EngineVersion)) { @($EngineVersion) } else { $Config.EngineVersions }

foreach ($CurrentEngineVersion in $VersionsToProcess) {
    $CurrentStage = "SETUP"
    
    # Resolve Engine Path
    $EngineBasePaths = @($Config.UnrealEngineBasePath)
    $EnginePath = $null
    foreach ($BasePath in $EngineBasePaths) {
        $PotentialPath = Join-Path -Path $BasePath -ChildPath "UE_$CurrentEngineVersion"
        if (Test-Path $PotentialPath) {
            $EnginePath = $PotentialPath
            break
        }
    }
    
    if (-not $EnginePath) {
        Write-Error "Could not find UE_$CurrentEngineVersion in any of the configured base paths."
        $GlobalSuccess = $false
        continue
    }

    # Use the engine-local UBT configuration so different engine versions can build concurrently.
    $EngineBuildConfigDir = Join-Path -Path $EnginePath -ChildPath "Engine/Saved/UnrealBuildTool"
    $EngineBuildConfigPath = Join-Path -Path $EngineBuildConfigDir -ChildPath "BuildConfiguration.xml"
    $EngineBuildConfigBackupPath = Join-Path -Path $EngineBuildConfigDir -ChildPath "BuildConfiguration.xml.fabbuild.bak"
    $EngineConfigLock = $null

    $LogFile = Join-Path -Path $LogsDir -ChildPath "BuildLog_UE_${CurrentEngineVersion}_$Timestamp.txt"

    # Define paths for temporary and final artifacts for this version
    $TempDir = Join-Path -Path $OutputBuildsDir -ChildPath "Temp_${CurrentEngineVersion}"
    $HostProjectDir = Join-Path -Path $TempDir -ChildPath "HostProject"
    $PackageOutputDir = Join-Path -Path $TempDir -ChildPath "PackagedPlugin_Raw"
    $CleanedPluginStageDir = Join-Path -Path $TempDir -ChildPath "Staging"
    
    $FinalPluginZipPath = Join-Path -Path $OutputBuildsDir -ChildPath "$($Config.PluginName)_v$($PluginVersion)_ue$($CurrentEngineVersion).zip"

    Write-Host "`n-----------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host " [TASK] Starting pipeline for Unreal Engine $CurrentEngineVersion" -ForegroundColor Yellow
    Write-Host " (Full log will be saved to: $LogFile)" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------------------"

    # --- CACHE CHECK ---
    if ($UseCache.IsPresent -and (Test-Path $FinalPluginZipPath)) {
        Write-Host "[CACHE] Skipping UE $CurrentEngineVersion because output already exists: $FinalPluginZipPath" -ForegroundColor Cyan
        continue
    }

    try {
        # --- 1. SETUP BUILD ENVIRONMENT ---
        $CurrentStage = "SETUP_BUILD_CONFIG"
        Write-Host "[1/3] [CONFIG] Setting up build environment for UE $CurrentEngineVersion..."
        
        if (Test-Path $TempDir) { Remove-Item -Recurse -Force -Path $TempDir }
        New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

        # Serialize builds targeting the same engine installation while allowing
        # different engine versions to run concurrently.
        $LockName = "Global\FabBuild_UE_$($CurrentEngineVersion.Replace('.', '_'))_$([Math]::Abs($EnginePath.ToLowerInvariant().GetHashCode()))"
        $EngineConfigLock = New-Object System.Threading.Mutex($false, $LockName)
        if (-not $EngineConfigLock.WaitOne([TimeSpan]::FromMinutes(30))) {
            throw "Timed out waiting for engine configuration lock '$LockName'."
        }

        New-Item -Path $EngineBuildConfigDir -ItemType Directory -Force | Out-Null
        if (Test-Path $EngineBuildConfigBackupPath) {
            throw "Stale engine configuration backup exists at '$EngineBuildConfigBackupPath'. Restore or remove it before building."
        }
        if (Test-Path $EngineBuildConfigPath) {
            Move-Item -Path $EngineBuildConfigPath -Destination $EngineBuildConfigBackupPath -Force
        }
        
        # Pin each engine to its supported Visual Studio 2022 toolchain.
        $ToolchainVersion = switch ($CurrentEngineVersion) {
            "5.1" { "14.32.31326" }
            "5.2" { "14.34.31933" }
            "5.3" { "14.36.32532" }
            "5.4" { "14.38.33130" }
            "5.5" { "14.38.33130" }
            "5.6" { "14.38.33130" }
            default { "14.44.35222" }
        }

        # Build the compiler configuration XML
        $CompilerXml = ""
        if ($Config.BuildOptions -and $Config.BuildOptions.PSObject.Properties.Name -contains 'UseClang' -and $Config.BuildOptions.UseClang) {
            $CompilerXml = "        <Compiler>Clang</Compiler>"
        } else {
            $CompilerXml = "        <CompilerVersion>$($ToolchainVersion)</CompilerVersion>"
        }

        @"
<?xml version="1.0" encoding="utf-8" ?>
<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration">
    <WindowsPlatform>
$CompilerXml
    </WindowsPlatform>
</Configuration>
"@ | Out-File -FilePath $EngineBuildConfigPath -Encoding utf8
        Write-Host "Using isolated UBT config: $EngineBuildConfigPath" -ForegroundColor DarkGray

        if (-not (Test-Path $EnginePath)) {
            throw "[SKIP] Engine not found at '$EnginePath'"
        }

        # --- 2. SETUP & BUILD HOST PROJECT ---
        $CurrentStage = "BUILD"
        Write-Host "[2/3] [BUILD] Generating standardized temporary host project..."
        $BuildId = "ue$($CurrentEngineVersion)-$PID-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $HostProject = & "$ScriptDir/new_host_project.ps1" `
            -EngineVersion $CurrentEngineVersion `
            -PluginName $Config.PluginName `
            -PluginSourceDirectory $Config.PluginSourceDirectory `
            -OutputDirectory $HostProjectDir `
            -CompilerVersion $ToolchainVersion `
            -BuildId $BuildId `
            -Force
        if (-not $HostProject -or -not (Test-Path -LiteralPath $HostProject.ProjectFile) -or -not (Test-Path -LiteralPath $HostProject.PluginDescriptor)) {
            throw "Host project generation failed for UE $CurrentEngineVersion."
        }
        $HostUprojectPath = $HostProject.ProjectFile
        $HostPluginDir = $HostProject.PluginDirectory
        $HostUpluginPath = $HostProject.PluginDescriptor
        Write-Host "Generated host project: $HostUprojectPath" -ForegroundColor DarkGray
        Write-Host "Build metadata: $($HostProject.MetadataFile)" -ForegroundColor DarkGray
        Write-Host "Compiling plugin using generated host project..."

        # Show live build output and save the same stream to the version log.
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" BuildPlugin -Plugin="$HostUpluginPath" -Package="$PackageOutputDir" -TargetPlatforms=Win64 -Rocket *>&1 | Tee-Object -FilePath $LogFile -Append
        if ($LASTEXITCODE -ne 0) { throw "Packaging failed. Check the log file." }
        Write-Host "Build process completed successfully."

        # --- 3. CREATE CLEAN DISTRIBUTABLE ---
        $CurrentStage = "CREATE_DISTRIBUTABLE"
        Write-Host "[3/3] [FINALIZE] Creating clean distributable zip..."
        
        $PackagedUpluginFile = Get-ChildItem -Path $PackageOutputDir -Filter "$($Config.PluginName).uplugin" -Recurse | Select-Object -First 1
        if (-not $PackagedUpluginFile) {
            throw "Could not find the packaged .uplugin file in '$PackageOutputDir'. Build may have failed to produce output."
        }
        $SourceForCleaning = $PackagedUpluginFile.DirectoryName
        
        New-Item -Path $CleanedPluginStageDir -ItemType Directory -Force | Out-Null
        
        $PluginRootInStage = Join-Path -Path $CleanedPluginStageDir -ChildPath $Config.PluginName
        New-Item -Path $PluginRootInStage -ItemType Directory -Force | Out-Null

        "Source", "Content", "Resources" | ForEach-Object {
            $SourcePath = Join-Path -Path $SourceForCleaning -ChildPath $_
            if (Test-Path $SourcePath) { Copy-Item -Recurse -Force -Path $SourcePath -Destination (Join-Path -Path $PluginRootInStage -ChildPath $_) }
        }
        Copy-Item -Force -Path $PackagedUpluginFile.FullName -Destination (Join-Path -Path $PluginRootInStage -ChildPath $PackagedUpluginFile.Name)
        
        # Robust retry loop to handle file locking issues during zipping.
        $ItemToZip = Get-ChildItem -Path $CleanedPluginStageDir | Select-Object -First 1
        if (-not $ItemToZip) {
            throw "Staging directory is empty. Nothing to zip."
        }
        
        $MaxRetries = 6
        $RetryDelaySeconds = 5
        for ($i = 1; $i -le $MaxRetries; $i++) {
            try {
                Compress-Archive -Path $ItemToZip.FullName -DestinationPath $FinalPluginZipPath -Force -ErrorAction Stop
                Write-Host "Zipping successful." -ForegroundColor Green
                break # Exit loop on success
            }
            catch {
                if ($i -eq $MaxRetries) {
                    Write-Error "Failed to zip files after $MaxRetries attempts. The last error was:"
                    throw # Re-throw the last exception to fail the script
                }
                Write-Host "Attempt $i/${MaxRetries}: Zipping failed, file may be locked. Retrying in $RetryDelaySeconds seconds..." -ForegroundColor Yellow
                Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor DarkGray
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }

        Write-Host "[SUCCESS] UE $CurrentEngineVersion package created successfully!" -ForegroundColor Green

    } catch {
        $GlobalSuccess = $false
        Write-Host "`n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "!!!! BUILD FAILED for UE $CurrentEngineVersion at stage: $CurrentStage !!!!" -ForegroundColor Red
        Write-Host "!!!! Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "!!!! Check the log file for details: $LogFile" -ForegroundColor Red
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
    } finally {
        # --- Cleanup ---
        Write-Host "Cleaning up temporary files for UE $CurrentEngineVersion..."
        if (Test-Path $TempDir) {
            for ($CleanupAttempt = 1; $CleanupAttempt -le 5; $CleanupAttempt++) {
                try {
                    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction Stop
                    break
                } catch {
                    if ($CleanupAttempt -eq 5) {
                        Write-Warning "Could not fully remove temporary directory '$TempDir': $($_.Exception.Message)"
                    } else {
                        Start-Sleep -Milliseconds (250 * $CleanupAttempt)
                    }
                }
            }
        }
        
        if (Test-Path $EngineBuildConfigPath) { Remove-Item -Path $EngineBuildConfigPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $EngineBuildConfigBackupPath) {
            Move-Item -Path $EngineBuildConfigBackupPath -Destination $EngineBuildConfigPath -Force
        }
        if ($EngineConfigLock) {
            try { $EngineConfigLock.ReleaseMutex() } catch { }
            $EngineConfigLock.Dispose()
        }
    }
}

# Propagate build failures to callers and CI systems.
exit $(if ($GlobalSuccess) { 0 } else { 1 })

