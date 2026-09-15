#Requires -Version 7.0
<#
.SYNOPSIS
    Entry point for the read-only CISO Assistant database comparison.
.DESCRIPTION
    This wrapper delegates to Compare-CisoAssistantDatabases-v2-core.ps1.
    The previous implementation is preserved in Git history. The wrapper keeps
    the original command name while avoiding parser ambiguity in interpolated
    strings containing a colon directly after a variable name.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DockerRoot = 'D:\_Docker',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Instances = @(
        'ciso-assistant-local',
        'ciso-assistant-dev01',
        'ciso-assistant-dev02',
        'ciso-assistant-grc-dev'
    ),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BackendImage = 'ghcr.io/intuitem/ciso-assistant-community/backend:latest',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = 'D:\_Docker\_CisoDatabaseComparison',

    [Parameter()]
    [ValidateRange(0, 20)]
    [int]$SampleLimit = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreScript = Join-Path -Path $PSScriptRoot -ChildPath 'Compare-CisoAssistantDatabases-v2-core.ps1'
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    throw ('Core comparison script not found: {0}' -f $coreScript)
}

$invokeParameters = @{
    DockerRoot   = $DockerRoot
    Instances    = $Instances
    BackendImage = $BackendImage
    OutputRoot   = $OutputRoot
    SampleLimit  = $SampleLimit
}

& $coreScript @invokeParameters
