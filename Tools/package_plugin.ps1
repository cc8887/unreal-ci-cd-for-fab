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
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if ($OutputDirectory) {
    $OutputBuildsDir = $OutputDirectory
} else {
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

    # Launcher UBT reads the per-user AppData config and ignores Engine/Saved.
    # Serialize access, back up the original, and restore it in finally.
    $EngineBuildConfigDir = Join-Path -Path $env:APPDATA -ChildPath 'Unreal Engine/UnrealBuildTool'
    $EngineBuildConfigPath = Join-Path -Path $EngineBuildConfigDir -ChildPath 'BuildConfiguration.xml'
    $EngineBuildConfigBackupPath = $null
    $EngineConfigLock = $null
    $TemporaryDependencyDirs = @()

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

        # Pin each engine to a supported installed MSVC toolchain.
        $RequestedToolchainVersion = switch ($CurrentEngineVersion) {
            "4.27" { "14.32" }
            "5.1" { "14.32" }
            "5.2" { "14.34" }
            "5.3" { "14.36" }
            "5.4" { "14.38" }
            "5.5" { "14.38" }
            "5.6" { "14.44" }
            "5.7" { "14.44" }
            "5.8" { "14.44" }
            default { throw "No supported MSVC toolchain mapping is defined for UE $CurrentEngineVersion." }
        }
        $MsvcRoots = @(
            "$env:ProgramFiles/Microsoft Visual Studio/2022/Community/VC/Tools/MSVC",
            "$env:ProgramFiles/Microsoft Visual Studio/2022/Professional/VC/Tools/MSVC",
            "$env:ProgramFiles/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC",
            "${env:ProgramFiles(x86)}/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC"
        )
        $InstalledToolchains = @($MsvcRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Directory | ForEach-Object { $_.Name }
        } | Where-Object { $_ -like "$RequestedToolchainVersion.*" } | Sort-Object { [version]$_ } -Descending -Unique)
        if ($InstalledToolchains.Count -eq 0) {
            throw "Requested MSVC $RequestedToolchainVersion for UE $CurrentEngineVersion is not installed."
        }
        $ToolchainVersion = $InstalledToolchains[0]
        Write-Host "MSVC toolchain requested=$RequestedToolchainVersion selected=$ToolchainVersion" -ForegroundColor Cyan

        $LockName = 'Global\FabBuild_UBT_UserConfig'
        $EngineConfigLock = New-Object System.Threading.Mutex($false, $LockName)
        if (-not $EngineConfigLock.WaitOne([TimeSpan]::FromMinutes(30))) {
            throw "Timed out waiting for UBT user configuration lock '$LockName'."
        }
        $EngineBuildConfigBackupPath = "$EngineBuildConfigPath.fabbuild.$PID.bak"
        New-Item -Path $EngineBuildConfigDir -ItemType Directory -Force | Out-Null
        if (Test-Path -LiteralPath $EngineBuildConfigBackupPath) {
            throw "Stale UBT configuration backup exists at '$EngineBuildConfigBackupPath'."
        }
        if (Test-Path -LiteralPath $EngineBuildConfigPath) {
            Move-Item -LiteralPath $EngineBuildConfigPath -Destination $EngineBuildConfigBackupPath -Force
        }

        # Build the compiler configuration XML
        $CompilerXml = ""
        if ($Config.BuildOptions -and $Config.BuildOptions.PSObject.Properties.Name -contains 'UseClang' -and $Config.BuildOptions.UseClang) {
            $CompilerXml = "        <Compiler>Clang</Compiler>"
        } else {
            $CompilerXml = "        <Compiler>VisualStudio2022</Compiler>`r`n        <CompilerVersion>$($ToolchainVersion)</CompilerVersion>"
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
        $DependenciesJsonPath = Join-Path -Path $TempDir -ChildPath 'build-plugin-dependencies.json'
        $BuildPluginDependencies = @()
        if ($Config.PSObject.Properties.Name -contains 'BuildPluginDependencies') {
            $BuildPluginDependencies = @($Config.BuildPluginDependencies)
        }
        Write-Host "Build plugin dependency count: $($BuildPluginDependencies.Count)" -ForegroundColor DarkGray
        ConvertTo-Json -InputObject $BuildPluginDependencies -Depth 8 | Set-Content -LiteralPath $DependenciesJsonPath -Encoding UTF8
        $HostProjectArguments = @{
            EngineVersion = $CurrentEngineVersion
            EnginePath = $EnginePath
            PluginName = $Config.PluginName
            PluginSourceDirectory = $Config.PluginSourceDirectory
            OutputDirectory = $HostProjectDir
            CompilerVersion = $ToolchainVersion
            BuildId = $BuildId
            Force = $true
        }
        if ($BuildPluginDependencies.Count -gt 0) {
            $HostProjectArguments.DependenciesJsonPath = $DependenciesJsonPath
        }
        $HostProject = & "$ScriptDir/new_host_project.ps1" @HostProjectArguments
        if (-not $HostProject -or -not (Test-Path -LiteralPath $HostProject.ProjectFile) -or -not (Test-Path -LiteralPath $HostProject.PluginDescriptor)) {
            throw "Host project generation failed for UE $CurrentEngineVersion."
        }
        $HostUprojectPath = $HostProject.ProjectFile
        $HostPluginDir = $HostProject.PluginDirectory
        $HostUpluginPath = $HostProject.PluginDescriptor
        Write-Host "Generated host project: $HostUprojectPath" -ForegroundColor DarkGray
        Write-Host "Build metadata: $($HostProject.MetadataFile)" -ForegroundColor DarkGray

        if ($BuildPluginDependencies.Count -gt 0) {
            $MarketplacePluginsDir = Join-Path -Path $EnginePath -ChildPath 'Engine/Plugins/Marketplace'
            $DependencyBuildRoot = Join-Path -Path $TempDir -ChildPath 'Dependencies'
            $DependencyBuildPlans = @()

            # Refuse all existing destinations before starting any dependency build.
            foreach ($Dependency in $BuildPluginDependencies) {
                $DependencyName = [string]$Dependency.Name
                if ([string]::IsNullOrWhiteSpace($DependencyName)) {
                    throw "BuildPluginDependencies contains an entry without a Name."
                }
                if ($DependencyName -notmatch '^[A-Za-z0-9_.-]+$') {
                    throw "Build dependency name '$DependencyName' contains characters that are unsafe for a temporary directory name."
                }
                $HostDependencyDir = Join-Path -Path $HostProjectDir -ChildPath "Plugins/$DependencyName"
                $HostDependencyDescriptor = Join-Path -Path $HostDependencyDir -ChildPath "$DependencyName.uplugin"
                if (-not (Test-Path -LiteralPath $HostDependencyDescriptor -PathType Leaf)) {
                    throw "Versioned host dependency descriptor '$HostDependencyDescriptor' was not found."
                }
                $TemporaryDependencyDir = Join-Path -Path $MarketplacePluginsDir -ChildPath $DependencyName
                if (Test-Path -LiteralPath $TemporaryDependencyDir) {
                    throw "Build dependency destination already exists at '$TemporaryDependencyDir'. Refusing to overwrite or remove it; handle the existing engine plugin directory before retrying."
                }
                $DependencyBuildPlans += [pscustomobject]@{
                    Name = $DependencyName
                    Descriptor = $HostDependencyDescriptor
                    PackageDirectory = (Join-Path -Path $DependencyBuildRoot -ChildPath $DependencyName)
                    ExposedDirectory = $TemporaryDependencyDir
                }
            }

            foreach ($DependencyBuildPlan in $DependencyBuildPlans) {
                $DependencyName = $DependencyBuildPlan.Name
                Write-Host "[DEPENDENCY BUILD START] $DependencyName" -ForegroundColor Cyan
                $DependencyBuildArguments = @('BuildPlugin', "-Plugin=$($DependencyBuildPlan.Descriptor)", "-Package=$($DependencyBuildPlan.PackageDirectory)", '-TargetPlatforms=Win64', '-Rocket')
                & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" @DependencyBuildArguments *>&1 | Tee-Object -FilePath $LogFile -Append
                if ($LASTEXITCODE -ne 0) {
                    throw "Dependency build failed for '$DependencyName'. Main plugin build was not started. Check '$LogFile'."
                }
                $PackagedDependencyDescriptor = Join-Path -Path $DependencyBuildPlan.PackageDirectory -ChildPath "$DependencyName.uplugin"
                if (-not (Test-Path -LiteralPath $PackagedDependencyDescriptor -PathType Leaf)) {
                    throw "Dependency build for '$DependencyName' succeeded but its packaged descriptor was not found at '$PackagedDependencyDescriptor'. Main plugin build was not started."
                }
                Write-Host "[DEPENDENCY BUILD SUCCESS] $DependencyName" -ForegroundColor Green
                try {
                    # AutomationTool packages manifest build products, including import libraries.
                    Copy-Item -LiteralPath $DependencyBuildPlan.PackageDirectory -Destination $DependencyBuildPlan.ExposedDirectory -Recurse -ErrorAction Stop
                    $TemporaryDependencyDirs += $DependencyBuildPlan.ExposedDirectory
                } catch {
                    if (Test-Path -LiteralPath $DependencyBuildPlan.ExposedDirectory) {
                        $TemporaryDependencyDirs += $DependencyBuildPlan.ExposedDirectory
                    }
                    throw "Failed to expose built dependency '$DependencyName' at '$($DependencyBuildPlan.ExposedDirectory)': $($_.Exception.Message)"
                }
                Write-Host "[DEPENDENCY EXPOSED] $DependencyName -> $($DependencyBuildPlan.ExposedDirectory)" -ForegroundColor Cyan
            }
        }

        Write-Host "Compiling plugin using generated host project..."
        $MainBuildArguments = @('BuildPlugin', "-Plugin=$HostUpluginPath", "-Package=$PackageOutputDir", '-TargetPlatforms=Win64', '-Rocket')
        & "$EnginePath/Engine/Build/BatchFiles/RunUAT.bat" @MainBuildArguments *>&1 | Tee-Object -FilePath $LogFile -Append
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
        
        foreach ($TemporaryDependencyDir in @($TemporaryDependencyDirs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
            try {
                if (Test-Path -LiteralPath $TemporaryDependencyDir) {
                    Remove-Item -LiteralPath $TemporaryDependencyDir -Recurse -Force -ErrorAction Stop
                }
            } catch {
                $GlobalSuccess = $false
                Write-Warning "Could not remove temporary dependency directory '$TemporaryDependencyDir': $($_.Exception.Message)"
            }
        }

        if ($EngineConfigLock) {
            if (Test-Path -LiteralPath $EngineBuildConfigPath) {
                Remove-Item -LiteralPath $EngineBuildConfigPath -Force -ErrorAction SilentlyContinue
            }
            if ($EngineBuildConfigBackupPath -and (Test-Path -LiteralPath $EngineBuildConfigBackupPath)) {
                Move-Item -LiteralPath $EngineBuildConfigBackupPath -Destination $EngineBuildConfigPath -Force
            }
            try { $EngineConfigLock.ReleaseMutex() } catch { }
            $EngineConfigLock.Dispose()
        }
    }
}

# Propagate build failures to callers and CI systems.
exit $(if ($GlobalSuccess) { 0 } else { 1 })

