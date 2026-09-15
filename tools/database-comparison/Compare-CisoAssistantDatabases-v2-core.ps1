#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only comparison of local CISO Assistant SQLite databases.
.DESCRIPTION
    Compares the known local CISO Assistant instances without modifying them.
    Running backend containers are inspected with docker exec. If a backend is
    not running, a short-lived read-only analysis container is used as fallback.

    The Python helper opens SQLite with mode=ro and PRAGMA query_only=ON.
    Existing CISO Assistant containers are never started, stopped or recreated.
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

function Test-DockerAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    return $null -ne (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)
}

function Invoke-NativeProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @(),

        [Parameter()]
        [AllowNull()]
        [string]$InputText = $null
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    if ($null -ne $InputText) {
        $startInfo.RedirectStandardInput = $true
    }

    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-CisoDatabaseFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstancePath
    )

    $databaseDirectory = Join-Path -Path $InstancePath -ChildPath 'db'
    if (-not (Test-Path -LiteralPath $databaseDirectory -PathType Container)) {
        return $null
    }

    $preferredPath = Join-Path -Path $databaseDirectory -ChildPath 'ciso-assistant.sqlite3'
    if (Test-Path -LiteralPath $preferredPath -PathType Leaf) {
        return Get-Item -LiteralPath $preferredPath
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $databaseDirectory -File -Filter '*.sqlite3' -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending
    )

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    return $null
}

function Get-RunningBackendContainer {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Instance
    )

    $result = Invoke-NativeProcess -FilePath 'docker' -Arguments @(
        'ps',
        '--filter', ('label=com.docker.compose.project={0}' -f $Instance),
        '--filter', 'label=com.docker.compose.service=backend',
        '--format', '{{.ID}}'
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    $ids = @(
        $result.StdOut -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($ids.Count -eq 0) {
        return $null
    }

    return [string]$ids[0]
}

function ConvertFrom-InspectionOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$NativeResult,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($NativeResult.StdOut)) {
        throw ('{0} returned no JSON. stderr: {1}' -f $Context, $NativeResult.StdErr.Trim())
    }

    try {
        $inspection = $NativeResult.StdOut | ConvertFrom-Json -Depth 50
    }
    catch {
        $preview = [string]$NativeResult.StdOut
        if ($preview.Length -gt 500) {
            $preview = $preview.Substring(0, 500) + '...'
        }
        throw ('{0} returned invalid JSON. stdout: {1} stderr: {2}' -f $Context, $preview, $NativeResult.StdErr.Trim())
    }

    if ($NativeResult.ExitCode -ne 0 -or $inspection.status -ne 'ok') {
        $inspectionError = if ($inspection.PSObject.Properties.Name -contains 'error') {
            [string]$inspection.error
        }
        else {
            [string]$NativeResult.StdErr.Trim()
        }
        throw ('{0} failed: {1}' -f $Context, $inspectionError)
    }

    return $inspection
}

function Get-CisoInspectionFromRunningContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerId,

        [Parameter(Mandatory)]
        [System.IO.FileInfo]$DatabaseFile,

        [Parameter(Mandatory)]
        [ValidateRange(0, 20)]
        [int]$LocalSampleLimit,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$HelperContent
    )

    $containerDatabasePath = '/code/db/{0}' -f $DatabaseFile.Name
    $result = Invoke-NativeProcess -FilePath 'docker' -Arguments @(
        'exec',
        '-i',
        $ContainerId,
        'python',
        '-B',
        '-',
        $containerDatabasePath,
        '--sample-limit',
        $LocalSampleLimit.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    ) -InputText $HelperContent

    return ConvertFrom-InspectionOutput -NativeResult $result -Context ('docker exec {0}' -f $ContainerId)
}

function Get-CisoInspectionFromFallbackContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$DatabaseFile,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Image,

        [Parameter(Mandatory)]
        [ValidateRange(0, 20)]
        [int]$LocalSampleLimit,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$HelperPath
    )

    $imageCheck = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', $Image)
    if ($imageCheck.ExitCode -ne 0) {
        throw ('Backend image {0} is not available locally; fallback analysis cannot run.' -f $Image)
    }

    $databaseDirectory = $DatabaseFile.Directory.FullName
    $toolDirectory = Split-Path -Parent $HelperPath
    $databaseMount = 'type=bind,source={0},target=/data,readonly' -f $databaseDirectory
    $toolMount = 'type=bind,source={0},target=/tool,readonly' -f $toolDirectory
    $containerDatabasePath = '/data/{0}' -f $DatabaseFile.Name

    $result = Invoke-NativeProcess -FilePath 'docker' -Arguments @(
        'run',
        '--rm',
        '--pull', 'never',
        '--read-only',
        '--network', 'none',
        '--tmpfs', '/tmp:rw,noexec,nosuid,nodev',
        '--mount', $databaseMount,
        '--mount', $toolMount,
        '--entrypoint', 'python',
        $Image,
        '-B',
        '/tool/Inspect-CisoAssistantDatabase.py',
        $containerDatabasePath,
        '--sample-limit',
        $LocalSampleLimit.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    )

    return ConvertFrom-InspectionOutput -NativeResult $result -Context 'fallback docker run'
}

function Get-SafeFileHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$DatabaseFile
    )

    try {
        return (Get-FileHash -LiteralPath $DatabaseFile.FullName -Algorithm SHA256).Hash
    }
    catch {
        Write-Warning ('Hash could not be calculated for {0}: {1}' -f $DatabaseFile.FullName, $_.Exception.Message)
        return $null
    }
}

function Get-SummaryRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$InstanceResult
    )

    if ($InstanceResult.Status -ne 'OK') {
        return [pscustomobject]@{
            Instance           = $InstanceResult.Instance
            Status             = $InstanceResult.Status
            SourceMode         = $InstanceResult.SourceMode
            DatabaseMB         = if ($null -ne $InstanceResult.Length) { [math]::Round(($InstanceResult.Length / 1MB), 2) } else { $null }
            LastWriteTimeUtc   = $InstanceResult.LastWriteTimeUtc
            HashPrefix         = if ($InstanceResult.Sha256) { $InstanceResult.Sha256.Substring(0, [math]::Min(16, $InstanceResult.Sha256.Length)) } else { $null }
            Tables             = $null
            TotalRows          = $null
            BusinessRows       = $null
            AssetRows          = $null
            AssetM365Matches   = $null
            EvidenceRows       = $null
            RiskRows           = $null
            AssessmentRows     = $null
            M365KeywordMatches = $null
            MigrationCount     = $null
            Error              = $InstanceResult.Error
        }
    }

    $inspection = $InstanceResult.Inspection
    $categoryRows = $inspection.summary.category_rows
    $categoryMatches = $inspection.summary.category_m365_matches

    return [pscustomobject]@{
        Instance           = $InstanceResult.Instance
        Status             = 'OK'
        SourceMode         = $InstanceResult.SourceMode
        DatabaseMB         = [math]::Round(($InstanceResult.Length / 1MB), 2)
        LastWriteTimeUtc   = $InstanceResult.LastWriteTimeUtc
        HashPrefix         = if ($InstanceResult.Sha256) { $InstanceResult.Sha256.Substring(0, [math]::Min(16, $InstanceResult.Sha256.Length)) } else { $null }
        Tables             = [int]$inspection.summary.table_count
        TotalRows          = [int64]$inspection.summary.total_rows
        BusinessRows       = [int64]$inspection.summary.business_rows
        AssetRows          = [int64]$categoryRows.asset
        AssetM365Matches   = [int64]$categoryMatches.asset
        EvidenceRows       = [int64]$categoryRows.evidence
        RiskRows           = [int64]$categoryRows.risk
        AssessmentRows     = [int64]$categoryRows.assessment
        M365KeywordMatches = [int64]$inspection.summary.m365_keyword_matches
        MigrationCount     = [int64]$inspection.migrations.count
        Error              = $null
    }
}

function Export-ComparisonResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]]$SummaryRows,

        [Parameter(Mandatory)]
        [pscustomobject[]]$DetailedResults,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationDirectory,

        [Parameter(Mandatory)]
        [datetime]$GeneratedAt
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $DestinationDirectory -Force
    }

    $jsonPath = Join-Path -Path $DestinationDirectory -ChildPath 'ciso-database-comparison-v2.json'
    $csvPath = Join-Path -Path $DestinationDirectory -ChildPath 'ciso-database-comparison-v2.csv'
    $markdownPath = Join-Path -Path $DestinationDirectory -ChildPath 'ciso-database-comparison-v2.md'

    $payload = [pscustomobject]@{
        GeneratedAt = $GeneratedAt.ToString('o')
        Version     = '2-core'
        Summary     = $SummaryRows
        Instances   = $DetailedResults
    }

    $payload | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    $SummaryRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# CISO Assistant Database Comparison v2')
    $lines.Add('')
    $lines.Add(('Generated: {0}' -f $GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss K')))
    $lines.Add('')
    $lines.Add('| Instance | Status | Mode | DB MB | Asset rows | Asset M365 | Evidence | Risks | Assessments | M365 total | Migrations | Hash | Error |')
    $lines.Add('|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|')
    foreach ($row in $SummaryRows) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} | {12} |' -f `
            $row.Instance, $row.Status, $row.SourceMode, $row.DatabaseMB, $row.AssetRows, $row.AssetM365Matches, `
            $row.EvidenceRows, $row.RiskRows, $row.AssessmentRows, $row.M365KeywordMatches, $row.MigrationCount, `
            $row.HashPrefix, ($row.Error -replace '\|', '/')))
    }

    $okRows = @($SummaryRows | Where-Object Status -eq 'OK')
    $lines.Add('')
    $lines.Add('## Candidate assessment')
    $lines.Add('')
    if ($okRows.Count -eq 0) {
        $lines.Add('No instance could be analyzed successfully.')
    }
    else {
        $maxAssetMatches = ($okRows | Measure-Object -Property AssetM365Matches -Maximum).Maximum
        if ($maxAssetMatches -gt 0) {
            $leaders = @($okRows | Where-Object AssetM365Matches -eq $maxAssetMatches)
            $lines.Add(('Highest M365 asset match count: {0}; instance(s): {1}' -f $maxAssetMatches, ($leaders.Instance -join ', ')))
        }
        else {
            $lines.Add('No M365 keyword matches were found in asset tables.')
        }
    }

    [System.IO.File]::WriteAllLines($markdownPath, $lines, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Json     = $jsonPath
        Csv      = $csvPath
        Markdown = $markdownPath
    }
}

if (-not (Test-DockerAvailable)) {
    throw 'Docker CLI wurde nicht gefunden. Bitte Docker Desktop starten bzw. Docker in PATH bereitstellen.'
}

$helperPath = Join-Path -Path $PSScriptRoot -ChildPath 'Inspect-CisoAssistantDatabase.py'
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw ('Python helper not found: {0}' -f $helperPath)
}
$helperContent = Get-Content -LiteralPath $helperPath -Raw -Encoding utf8

$generatedAt = Get-Date
$runDirectoryName = $generatedAt.ToString('yyyyMMdd-HHmmss') + '-v2'
$destinationDirectory = Join-Path -Path $OutputRoot -ChildPath $runDirectoryName
$detailedResults = [System.Collections.Generic.List[object]]::new()

foreach ($instance in $Instances) {
    Write-Information ('Analysiere {0} ...' -f $instance) -InformationAction Continue
    $instancePath = Join-Path -Path $DockerRoot -ChildPath $instance

    if (-not (Test-Path -LiteralPath $instancePath -PathType Container)) {
        $message = 'Instance directory not found: {0}' -f $instancePath
        Write-Warning ('{0}: {1}' -f $instance, $message)
        $detailedResults.Add([pscustomobject]@{
            Instance         = $instance
            Status           = 'MISSING_INSTANCE'
            SourceMode       = 'none'
            Error            = $message
            DatabasePath     = $null
            Length           = $null
            LastWriteTimeUtc = $null
            Sha256           = $null
            Inspection       = $null
        })
        continue
    }

    $databaseFile = Get-CisoDatabaseFile -InstancePath $instancePath
    if ($null -eq $databaseFile) {
        $message = 'No *.sqlite3 database found below: {0}' -f (Join-Path -Path $instancePath -ChildPath 'db')
        Write-Warning ('{0}: {1}' -f $instance, $message)
        $detailedResults.Add([pscustomobject]@{
            Instance         = $instance
            Status           = 'MISSING_DATABASE'
            SourceMode       = 'none'
            Error            = $message
            DatabasePath     = $null
            Length           = $null
            LastWriteTimeUtc = $null
            Sha256           = $null
            Inspection       = $null
        })
        continue
    }

    $hash = Get-SafeFileHash -DatabaseFile $databaseFile
    $containerId = Get-RunningBackendContainer -Instance $instance
    $sourceMode = if ($containerId) { 'docker-exec' } else { 'docker-run-fallback' }

    try {
        if ($containerId) {
            $inspection = Get-CisoInspectionFromRunningContainer `
                -ContainerId $containerId `
                -DatabaseFile $databaseFile `
                -LocalSampleLimit $SampleLimit `
                -HelperContent $helperContent
        }
        else {
            $inspection = Get-CisoInspectionFromFallbackContainer `
                -DatabaseFile $databaseFile `
                -Image $BackendImage `
                -LocalSampleLimit $SampleLimit `
                -HelperPath $helperPath
        }

        $detailedResults.Add([pscustomobject]@{
            Instance         = $instance
            Status           = 'OK'
            SourceMode       = $sourceMode
            Error            = $null
            DatabasePath     = $databaseFile.FullName
            Length           = $databaseFile.Length
            LastWriteTimeUtc = $databaseFile.LastWriteTimeUtc.ToString('o')
            Sha256           = $hash
            Inspection       = $inspection
        })
    }
    catch {
        $message = $_.Exception.Message
        Write-Warning ('{0} [{1}]: {2}' -f $instance, $sourceMode, $message)
        $detailedResults.Add([pscustomobject]@{
            Instance         = $instance
            Status           = 'ERROR'
            SourceMode       = $sourceMode
            Error            = $message
            DatabasePath     = $databaseFile.FullName
            Length           = $databaseFile.Length
            LastWriteTimeUtc = $databaseFile.LastWriteTimeUtc.ToString('o')
            Sha256           = $hash
            Inspection       = $null
        })
    }
}

$summaryRows = @($detailedResults | ForEach-Object { Get-SummaryRow -InstanceResult $_ })
$exportedFiles = Export-ComparisonResult `
    -SummaryRows $summaryRows `
    -DetailedResults @($detailedResults) `
    -DestinationDirectory $destinationDirectory `
    -GeneratedAt $generatedAt

$summaryRows |
    Select-Object Instance, Status, SourceMode, DatabaseMB, AssetRows, AssetM365Matches, EvidenceRows, RiskRows, AssessmentRows, M365KeywordMatches, Error |
    Format-Table -AutoSize -Wrap

Write-Information ('Markdown report: {0}' -f $exportedFiles.Markdown) -InformationAction Continue
Write-Information ('JSON details:    {0}' -f $exportedFiles.Json) -InformationAction Continue
Write-Information ('CSV summary:     {0}' -f $exportedFiles.Csv) -InformationAction Continue

$errorCount = @($summaryRows | Where-Object Status -ne 'OK').Count
if ($errorCount -gt 0) {
    Write-Warning ('{0} instance(s) could not be analyzed. See the error column and generated report.' -f $errorCount)
}
