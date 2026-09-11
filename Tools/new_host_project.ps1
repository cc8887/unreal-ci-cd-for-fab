<#
.SYNOPSIS
    Generates a deterministic temporary Unreal host project for plugin builds.
.DESCRIPTION
    Creates a minimal version-specific Unreal project, copies the plugin source with
    standard exclusions, pins the plugin EngineVersion, and writes build metadata.
    The generated project is disposable and should not be committed.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^(4[.](26|27)|5[.][0-9]+)$')]
    [string]$EngineVersion,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$PluginName,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$PluginSourceDirectory,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$EnginePath,

    [Parameter(Mandatory=$false)]
    [string]$DependenciesJsonPath,

    [Parameter(Mandatory=$false)]
    [string]$ProjectName = 'HostProject',

    [Parameter(Mandatory=$false)]
    [string]$CompilerVersion,

    [Parameter(Mandatory=$false)]
    [string]$BuildId,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path, [bool]$MustExist) {
    if ($MustExist) {
        return (Resolve-Path -LiteralPath $Path).Path
    }
    return [System.IO.Path]::GetFullPath($Path)
}

if ($ProjectName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
    throw "ProjectName must be a valid Unreal identifier: '$ProjectName'."
}

$PluginSourceDirectory = Resolve-FullPath $PluginSourceDirectory $true
$OutputDirectory = Resolve-FullPath $OutputDirectory $false
$EnginePath = Resolve-FullPath $EnginePath $true
$SourceUpluginPath = Join-Path $PluginSourceDirectory "$PluginName.uplugin"
if (-not (Test-Path -LiteralPath $SourceUpluginPath -PathType Leaf)) {
    throw "Plugin descriptor not found: '$SourceUpluginPath'."
}

$SourcePlugin = Get-Content -LiteralPath $SourceUpluginPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($SourcePlugin.VersionName)) {
    throw "Plugin descriptor must define VersionName: '$SourceUpluginPath'."
}

$Dependencies = @()
if (-not [string]::IsNullOrWhiteSpace($DependenciesJsonPath)) {
    $DependenciesJsonPath = Resolve-FullPath $DependenciesJsonPath $true
    $Dependencies = @(Get-Content -LiteralPath $DependenciesJsonPath -Raw | ConvertFrom-Json | Where-Object { $null -ne $_ })
}
$ProvidedPluginNames = @($PluginName) + @($Dependencies | ForEach-Object { $_.Name })

function Copy-PluginToHost([string]$Name, [string]$SourceDirectory) {
    $ResolvedSource = Resolve-FullPath $SourceDirectory $true
    $DescriptorPath = Join-Path $ResolvedSource "$Name.uplugin"
    if (-not (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) {
        throw "Plugin descriptor not found: '$DescriptorPath'."
    }

    $Destination = Join-Path $OutputDirectory "Plugins/$Name"
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    $ExcludeDirectories = @(
        '.git', '.vs', '.vscode', '.idea', 'Binaries', 'Build', 'Intermediate',
        'Saved', 'DerivedDataCache', '__pycache__', 'Packages'
    )
    $RobocopyArguments = @($ResolvedSource, $Destination, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP', '/XD') + $ExcludeDirectories
    & robocopy @RobocopyArguments | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "Failed to copy plugin '$Name'. Robocopy exit code: $LASTEXITCODE."
    }

    # Preserve prebuilt third-party import/runtime libraries without copying
    # engine-version-specific module binaries from Binaries/Win64.
    $ThirdPartyBinaries = Join-Path $ResolvedSource 'Binaries/ThirdParty'
    if (Test-Path -LiteralPath $ThirdPartyBinaries -PathType Container) {
        $ThirdPartyDestination = Join-Path $Destination 'Binaries/ThirdParty'
        New-Item -Path $ThirdPartyDestination -ItemType Directory -Force | Out-Null
        & robocopy $ThirdPartyBinaries $ThirdPartyDestination /E /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -gt 7) {
            throw "Failed to copy third-party binaries for plugin '$Name'. Robocopy exit code: $LASTEXITCODE."
        }
    }
    return $Destination
}

function Test-EnginePluginInstalled([string]$Name) {
    $EnginePluginsDirectory = Join-Path $EnginePath 'Engine/Plugins'
    return $null -ne (Get-ChildItem -LiteralPath $EnginePluginsDirectory -Filter "$Name.uplugin" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Update-HostPluginDescriptor([string]$Name, [string]$Directory) {
    $DescriptorPath = Join-Path $Directory "$Name.uplugin"
    $Descriptor = Get-Content -LiteralPath $DescriptorPath -Raw | ConvertFrom-Json
    $Descriptor | Add-Member -NotePropertyName EngineVersion -NotePropertyValue "$EngineVersion.0" -Force
    if ($Descriptor.Plugins) {
        $FilteredReferences = @()
        foreach ($Reference in @($Descriptor.Plugins)) {
            if ($ProvidedPluginNames -contains $Reference.Name -or (Test-EnginePluginInstalled $Reference.Name)) {
                $FilteredReferences += $Reference
            } else {
                Write-Warning "Removing unavailable engine plugin reference '$($Reference.Name)' from temporary descriptor '$Name' for UE $EngineVersion."
            }
        }
        $Descriptor.Plugins = $FilteredReferences
    }
    $Descriptor | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $DescriptorPath -Encoding UTF8
    return $DescriptorPath
}

if (Test-Path -LiteralPath $OutputDirectory) {
    if (-not $Force) {
        throw "Output directory already exists: '$OutputDirectory'. Use -Force to replace it."
    }
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$HostPluginDirectory = Copy-PluginToHost $PluginName $PluginSourceDirectory
$HostUpluginPath = Update-HostPluginDescriptor $PluginName $HostPluginDirectory
$HostDependencies = @()
foreach ($Dependency in $Dependencies) {
    $DependencyDirectory = Copy-PluginToHost $Dependency.Name $Dependency.SourceDirectory
    $DependencyDescriptor = Update-HostPluginDescriptor $Dependency.Name $DependencyDirectory
    $HostDependencies += [ordered]@{
        name = $Dependency.Name
        sourceDirectory = (Resolve-FullPath $Dependency.SourceDirectory $true)
        pluginDirectory = $DependencyDirectory
        pluginDescriptor = $DependencyDescriptor
    }
}

$EnabledPlugins = @([ordered]@{ Name = $PluginName; Enabled = $true })
$EnabledPlugins += @($Dependencies | ForEach-Object { [ordered]@{ Name = $_.Name; Enabled = $true } })
$ProjectDescriptor = [ordered]@{
    FileVersion = 3
    EngineAssociation = $EngineVersion
    Category = ''
    Description = "Generated host project for $PluginName"
    Plugins = $EnabledPlugins
}
$ProjectPath = Join-Path $OutputDirectory "$ProjectName.uproject"
$ProjectDescriptor | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ProjectPath -Encoding UTF8

$MetadataDirectory = Join-Path $OutputDirectory '.fabbuild'
New-Item -Path $MetadataDirectory -ItemType Directory -Force | Out-Null
$Metadata = [ordered]@{
    schemaVersion = 1
    generatedBy = 'Tools/new_host_project.ps1'
    buildId = $BuildId
    projectName = $ProjectName
    engineVersion = $EngineVersion
    compilerVersion = $CompilerVersion
    pluginName = $PluginName
    pluginVersion = $SourcePlugin.VersionName
    pluginSourceDirectory = $PluginSourceDirectory
    enginePath = $EnginePath
    dependencies = $HostDependencies
    projectFile = $ProjectPath
    pluginDescriptor = $HostUpluginPath
}
$MetadataPath = Join-Path $MetadataDirectory 'host-project.json'
$Metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $MetadataPath -Encoding UTF8

$ReadmePath = Join-Path $OutputDirectory 'README.md'
$CompilerDisplay = if ([string]::IsNullOrWhiteSpace($CompilerVersion)) { 'UnrealBuildTool default' } else { "MSVC $CompilerVersion" }
$BuildIdDisplay = if ([string]::IsNullOrWhiteSpace($BuildId)) { 'not specified' } else { $BuildId }
$RegenerateCommand = ".\Tools\new_host_project.ps1 -EngineVersion `"$EngineVersion`" -EnginePath `"$EnginePath`" -PluginName `"$PluginName`" -PluginSourceDirectory `"$PluginSourceDirectory`" -OutputDirectory `"$OutputDirectory`""
if (-not [string]::IsNullOrWhiteSpace($DependenciesJsonPath)) {
    $RegenerateCommand += " -DependenciesJsonPath `"$DependenciesJsonPath`""
}
if (-not [string]::IsNullOrWhiteSpace($CompilerVersion)) {
    $RegenerateCommand += " -CompilerVersion `"$CompilerVersion`""
}
if (-not [string]::IsNullOrWhiteSpace($BuildId)) {
    $RegenerateCommand += " -BuildId `"$BuildId`""
}
$RegenerateCommand += ' -Force'

@"
# Generated Unreal Host Project

This disposable project was generated by ``Tools/new_host_project.ps1`` to build and validate the ``$PluginName`` plugin.

- Unreal Engine: ``$EngineVersion``
- Compiler: ``$CompilerDisplay``
- Plugin version: ``$($SourcePlugin.VersionName)``
- Build ID: ``$BuildIdDisplay``
- Build metadata: ``.fabbuild/host-project.json``
- Original plugin source: ``$PluginSourceDirectory``

## Important

- Do not commit this directory. Generated host projects are excluded by the root repository's ``.gitignore``.
- Do not edit the plugin copy under ``Plugins/$PluginName``. Make changes in the original plugin repository and regenerate this project.
- Running the generator with ``-Force`` deletes and recreates this directory.
- This is a build container, not a production Unreal project.

## Regenerate

``````powershell
$RegenerateCommand
``````
"@ | Set-Content -LiteralPath $ReadmePath -Encoding UTF8

$Result = [pscustomobject]@{
    ProjectDirectory = $OutputDirectory
    ProjectFile = $ProjectPath
    PluginDirectory = $HostPluginDirectory
    PluginDescriptor = $HostUpluginPath
    MetadataFile = $MetadataPath
    ReadmeFile = $ReadmePath
    EngineVersion = $EngineVersion
    CompilerVersion = $CompilerVersion
}

Write-Output $Result
$global:LASTEXITCODE = 0
