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
    [ValidatePattern('^5\.\d+$')]
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
$SourceUpluginPath = Join-Path $PluginSourceDirectory "$PluginName.uplugin"
if (-not (Test-Path -LiteralPath $SourceUpluginPath -PathType Leaf)) {
    throw "Plugin descriptor not found: '$SourceUpluginPath'."
}

$SourcePlugin = Get-Content -LiteralPath $SourceUpluginPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($SourcePlugin.VersionName)) {
    throw "Plugin descriptor must define VersionName: '$SourceUpluginPath'."
}

if (Test-Path -LiteralPath $OutputDirectory) {
    if (-not $Force) {
        throw "Output directory already exists: '$OutputDirectory'. Use -Force to replace it."
    }
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$HostPluginDirectory = Join-Path $OutputDirectory "Plugins/$PluginName"
New-Item -Path $HostPluginDirectory -ItemType Directory -Force | Out-Null

$ExcludeDirectories = @(
    '.git', '.vs', '.vscode', '.idea', 'Binaries', 'Build', 'Intermediate',
    'Saved', 'DerivedDataCache', '__pycache__', 'Packages'
)
$RobocopyArguments = @($PluginSourceDirectory, $HostPluginDirectory, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP', '/XD') + $ExcludeDirectories
& robocopy @RobocopyArguments | Out-Null
if ($LASTEXITCODE -gt 7) {
    throw "Failed to copy plugin source. Robocopy exit code: $LASTEXITCODE."
}

$HostUpluginPath = Join-Path $HostPluginDirectory "$PluginName.uplugin"
$HostPlugin = Get-Content -LiteralPath $HostUpluginPath -Raw | ConvertFrom-Json
$HostPlugin | Add-Member -NotePropertyName EngineVersion -NotePropertyValue "$EngineVersion.0" -Force
$HostPlugin | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $HostUpluginPath -Encoding UTF8

$ProjectDescriptor = [ordered]@{
    FileVersion = 3
    EngineAssociation = $EngineVersion
    Category = ''
    Description = "Generated host project for $PluginName"
    Plugins = @([ordered]@{ Name = $PluginName; Enabled = $true })
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
    projectFile = $ProjectPath
    pluginDescriptor = $HostUpluginPath
}
$MetadataPath = Join-Path $MetadataDirectory 'host-project.json'
$Metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $MetadataPath -Encoding UTF8

$ReadmePath = Join-Path $OutputDirectory 'README.md'
$CompilerDisplay = if ([string]::IsNullOrWhiteSpace($CompilerVersion)) { 'UnrealBuildTool default' } else { "MSVC $CompilerVersion" }
$BuildIdDisplay = if ([string]::IsNullOrWhiteSpace($BuildId)) { 'not specified' } else { $BuildId }
$RegenerateCommand = ".\Tools\new_host_project.ps1 -EngineVersion `"$EngineVersion`" -PluginName `"$PluginName`" -PluginSourceDirectory `"$PluginSourceDirectory`" -OutputDirectory `"$OutputDirectory`""
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
