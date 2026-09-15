#Requires -Version 7.0
<#
.SYNOPSIS
    Vergleicht lokale CISO-Assistant-SQLite-Datenbanken read-only.
.DESCRIPTION
    Version 2 bevorzugt die Analyse innerhalb des bereits laufenden Backend-Containers.
    Dadurch wird die Datenbank ueber denselben Docker-Bind-Mount gelesen, den CISO Assistant
    selbst verwendet. Das vermeidet Probleme mit separaten Windows-/Docker-Desktop-Bind-Mounts
    und mit aktiven SQLite-WAL-Dateien.

    Die SQLite-Verbindung wird durch Inspect-CisoAssistantDatabase.py mit mode=ro und
    PRAGMA query_only=ON geoeffnet. Bestehende Container werden nicht gestartet, gestoppt,
    aktualisiert oder neu erstellt. Falls kein Backend-Container laeuft, wird optional ein
    kurzlebiger read-only Analyse-Container als Fallback verwendet.
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
    [int]$SampleLimit = 3
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
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    if ($null -ne $InputText) {
        $process.StandardInput.Write($InputText)
        $process.StandardInput.Close()
    }

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $standardOutput
        StdErr   = $standardError
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
        '--filter', "label=com.docker.compose.project=$Instance",
        '--filter', 'label=com.docker.compose.service=backend',
        '--format', '{{.ID}}'
    )

    if ($result.ExitCode -ne 0) {
        return $null
    }

    $containerId = @(
        $result.StdOut -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($containerId)) {
        return $null
    }

    return $containerId
}

function ConvertFrom-InspectionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$NativeResult,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($NativeResult.StdOut)) {
        throw "$Context returned no JSON. stderr: $($NativeResult.StdErr.Trim())"
    }

    try {
        $inspection = $NativeResult.StdOut | ConvertFrom-Json -Depth 50
    }
    catch {
        $preview = $NativeResult.StdOut
        if ($preview.Length -gt 500) {
            $preview = $preview.Substring(0, 500) + '...'
        }
        throw "$Context returned invalid JSON. stdout: $preview stderr: $($NativeResult.StdErr.Trim())"
    }

    if ($NativeResult.ExitCode -ne 0 -or $inspection.status -ne 'ok') {
        $inspectionError = if ($inspection.PSObject.Properties.Name -contains 'error') {
            [string]$inspection.error
        }
        else {
            [string]$NativeResult.StdErr.Trim()
        }
        throw "$Context failed: $inspectionError"
    }

    return $inspection
}

function Get-CisoDatabaseInspectionFromRunningContainer {
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

    $containerDatabasePath = "/code/db/$($DatabaseFile.Name)"
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

    return ConvertFrom-InspectionResult -NativeResult $result -Context "docker exec $ContainerId"
}

function Get-CisoDatabaseInspectionFromFallbackContainer {
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
        throw "Backend image '$Image' is not available locally; fallback analysis cannot run."
    }

    $databaseDirectory = $DatabaseFile.Directory.FullName
    $toolDirectory = Split-Path -Parent $HelperPath
    $databaseMount = "type=bind,source=$databaseDirectory,target=/data,readonly"
    $toolMount = "type=bind,source=$toolDirectory,target=/tool,readonly"
    $containerDatabasePath = "/data/$($DatabaseFile.Name)"

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

    return ConvertFrom-InspectionResult -NativeResult $result -Context 'fallback docker run'
}

function Get-SafeFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$DatabaseFile
    )

    try {
        return (Get-FileHash -LiteralPath $DatabaseFile.FullName -Algorithm SHA256).Hash
    }
    catch {
        Write-Warning "Hash could not be calculated for '$($DatabaseFile.FullName)': $($_.Exception.Message)"
        return $null
    }
}

function Get-CisoSummaryRow {
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

function Write-CisoMarkdownReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]]$SummaryRows,

        [Parameter(Mandatory)]
        [pscustomobject[]]$DetailedResults,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [datetime]$GeneratedAt
    )

    $okRows = @($SummaryRows | Where-Object Status -eq 'OK')
    $candidateText = 'Kein eindeutiger M365-Kandidat ermittelbar.'

    if ($okRows.Count -gt 0) {
        $maxAssetMatches = ($okRows | Measure-Object -Property AssetM365Matches -Maximum).Maximum
        if ($null -ne $maxAssetMatches -and $maxAssetMatches -gt 0) {
            $leaders = @($okRows | Where-Object AssetM365Matches -eq $maxAssetMatches)
            if ($leaders.Count -eq 1) {
                $candidateText = "Staerkster M365-Import-Kandidat: **$($leaders[0].Instance)** mit $maxAssetMatches M365-Treffern in Asset-Tabellen."
            }
            else {
                $candidateText = "Mehrere Instanzen teilen den hoechsten Asset-M365-Wert ($maxAssetMatches): **$($leaders.Instance -join ', ')**."
            }
        }
    }

    $hashGroups = @(
        $DetailedResults |
            Where-Object { $_.Status -eq 'OK' -and -not [string]::IsNullOrWhiteSpace($_.Sha256) } |
            Group-Object -Property Sha256 |
            Where-Object Count -gt 1
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# CISO Assistant Database Comparison v2')
    $lines.Add('')
    $lines.Add("Erstellt: $($GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss K'))")
    $lines.Add('')
    $lines.Add('## Kernaussage')
    $lines.Add('')
    $lines.Add($candidateText)
    $lines.Add('')
    $lines.Add('## Vergleich')
    $lines.Add('')
    $lines.Add('| Instance | Status | Mode | DB MB | LastWrite UTC | Asset rows | Asset M365 | Evidence | Risks | Assessments | M365 total | Migrations | Hash |')
    $lines.Add('|---|---|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---|')

    foreach ($row in $SummaryRows) {
        $lines.Add("| $($row.Instance) | $($row.Status) | $($row.SourceMode) | $($row.DatabaseMB) | $($row.LastWriteTimeUtc) | $($row.AssetRows) | $($row.AssetM365Matches) | $($row.EvidenceRows) | $($row.RiskRows) | $($row.AssessmentRows) | $($row.M365KeywordMatches) | $($row.MigrationCount) | $($row.HashPrefix) |")
    }

    $lines.Add('')
    $lines.Add('## Fehler')
    $lines.Add('')
    $errorRows = @($SummaryRows | Where-Object Status -ne 'OK')
    if ($errorRows.Count -eq 0) {
        $lines.Add('Keine Fehler.')
    }
    else {
        foreach ($row in $errorRows) {
            $lines.Add("- **$($row.Instance)** [$($row.Status) / $($row.SourceMode)]: $($row.Error)")
        }
    }

    $lines.Add('')
    $lines.Add('## Identische Hauptdatenbankdateien')
    $lines.Add('')
    if ($hashGroups.Count -eq 0) {
        $lines.Add('Keine identischen SHA-256-Hauptdatenbankdateien gefunden oder Hash nicht verfuegbar.')
    }
    else {
        foreach ($group in $hashGroups) {
            $lines.Add("- Identischer Hash: $($group.Group.Instance -join ', ')")
        }
    }

    $lines.Add('')
    $lines.Add('## M365-Treffer je Instanz')
    foreach ($result in $DetailedResults) {
        $lines.Add('')
        $lines.Add("### $($result.Instance)")
        if ($result.Status -ne 'OK') {
            $lines.Add('')
            $lines.Add("Status: $($result.Status) - $($result.Error)")
            continue
        }

        $matchingTables = @(
            $result.Inspection.tables |
                Where-Object { $_.m365_keyword_matches -gt 0 -and $_.categories.Count -gt 0 } |
                Sort-Object -Property m365_keyword_matches -Descending
        )

        $lines.Add('')
        if ($matchingTables.Count -eq 0) {
            $lines.Add('Keine M365-Schluesselwoerter in den fachlich kategorisierten Tabellen gefunden.')
        }
        else {
            $lines.Add('| Table | Categories | Rows | M365 matches | Latest |')
            $lines.Add('|---|---|---:|---:|---|')
            foreach ($table in $matchingTables) {
                $latest = if ($null -ne $table.latest_timestamp) { $table.latest_timestamp.value } else { '' }
                $categories = $table.categories -join ', '
                $lines.Add("| $($table.name) | $categories | $($table.row_count) | $($table.m365_keyword_matches) | $latest |")
            }
        }
    }

    $lines.Add('')
    $lines.Add('## Sicherheitsmerkmale')
    $lines.Add('')
    $lines.Add('- Bevorzugt wird docker exec in den bereits laufenden Backend-Container.')
    $lines.Add('- Der Python-Helper wird dabei ueber stdin uebergeben; es wird keine Datei in den Container kopiert.')
    $lines.Add('- SQLite wird mit mode=ro und PRAGMA query_only=ON geoeffnet.')
    $lines.Add('- Fallback-Container: --read-only, --network none, read-only Bind-Mounts, --pull never.')
    $lines.Add('- Bestehende CISO-Container werden weder gestartet noch gestoppt.')
    $lines.Add('- Es werden keine Django-Migrationen oder schreibenden Django-Kommandos ausgefuehrt.')

    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
}

function Export-CisoComparison {
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
        Version     = 2
        Summary     = $SummaryRows
        Instances   = $DetailedResults
    }

    $payload | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    $SummaryRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM
    Write-CisoMarkdownReport -SummaryRows $SummaryRows -DetailedResults $DetailedResults -Path $markdownPath -GeneratedAt $GeneratedAt

    return [pscustomobject]@{
        Json     = $jsonPath
        Csv      = $csvPath
        Markdown = $markdownPath
    }
}

if (-not (Test-DockerAvailable)) {
    throw 'Docker CLI wurde nicht gefunden. Bitte Docker Desktop starten bzw. die Docker CLI in PATH bereitstellen.'
}

$helperPath = Join-Path -Path $PSScriptRoot -ChildPath 'Inspect-CisoAssistantDatabase.py'
if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "Python helper not found: $helperPath"
}
$helperContent = Get-Content -LiteralPath $helperPath -Raw -Encoding utf8

$generatedAt = Get-Date
$runDirectoryName = $generatedAt.ToString('yyyyMMdd-HHmmss') + '-v2'
$destinationDirectory = Join-Path -Path $OutputRoot -ChildPath $runDirectoryName
$detailedResults = [System.Collections.Generic.List[object]]::new()

foreach ($instance in $Instances) {
    Write-Information "Analysiere $instance ..." -InformationAction Continue
    $instancePath = Join-Path -Path $DockerRoot -ChildPath $instance

    if (-not (Test-Path -LiteralPath $instancePath -PathType Container)) {
        $message = "Instance directory not found: $instancePath"
        Write-Warning "$instance: $message"
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
        $message = "No *.sqlite3 database found below: $(Join-Path -Path $instancePath -ChildPath 'db')"
        Write-Warning "$instance: $message"
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
            $inspection = Get-CisoDatabaseInspectionFromRunningContainer `
                -ContainerId $containerId `
                -DatabaseFile $databaseFile `
                -LocalSampleLimit $SampleLimit `
                -HelperContent $helperContent
        }
        else {
            $inspection = Get-CisoDatabaseInspectionFromFallbackContainer `
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
        Write-Warning "$instance [$sourceMode]: $message"
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

$summaryRows = @($detailedResults | ForEach-Object { Get-CisoSummaryRow -InstanceResult $_ })
$exportedFiles = Export-CisoComparison `
    -SummaryRows $summaryRows `
    -DetailedResults @($detailedResults) `
    -DestinationDirectory $destinationDirectory `
    -GeneratedAt $generatedAt

$summaryRows |
    Select-Object Instance, Status, SourceMode, DatabaseMB, AssetRows, AssetM365Matches, EvidenceRows, RiskRows, AssessmentRows, M365KeywordMatches, Error |
    Format-Table -AutoSize -Wrap

Write-Information "`nMarkdown report: $($exportedFiles.Markdown)" -InformationAction Continue
Write-Information "JSON details:    $($exportedFiles.Json)" -InformationAction Continue
Write-Information "CSV summary:     $($exportedFiles.Csv)" -InformationAction Continue

$errorCount = @($summaryRows | Where-Object Status -ne 'OK').Count
if ($errorCount -gt 0) {
    Write-Warning "$errorCount instance(s) could not be analyzed. The error text is now shown directly above and stored in the reports."
}
