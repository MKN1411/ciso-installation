#Requires -Version 7.0
<#
.SYNOPSIS
    Vergleicht die lokalen SQLite-Datenbanken mehrerer CISO-Assistant-Docker-Instanzen read-only.
.DESCRIPTION
    Ermittelt fuer die bekannten lokalen Instanzen die SQLite-Datei, Metadaten, Hash, Tabellen-
    und Zeilenanzahlen sowie M365-bezogene Treffer in fachlich relevanten Tabellen. Die eigentliche
    SQLite-Analyse wird in einem kurzlebigen Container mit dem bereits lokal vorhandenen CISO-
    Assistant-Backend-Image ausgefuehrt. Datenbank- und Tool-Verzeichnisse werden ausschliesslich
    read-only eingebunden; Netzwerkzugriff ist fuer den Analyse-Container deaktiviert.

    Das Skript startet, stoppt oder aktualisiert keine bestehende CISO-Assistant-Instanz und fuehrt
    kein docker compose up/down aus. Das Backend-Image wird mit --pull never verwendet.
.PARAMETER DockerRoot
    Root-Verzeichnis der lokalen CISO-Assistant-Installationen.
.PARAMETER Instances
    Namen der zu vergleichenden Instanzverzeichnisse unter DockerRoot.
.PARAMETER BackendImage
    Bereits lokal vorhandenes Backend-Image, das Python und SQLite-Unterstuetzung bereitstellt.
.PARAMETER OutputRoot
    Zielverzeichnis fuer JSON-, CSV- und Markdown-Ergebnisse.
.PARAMETER SampleLimit
    Maximale Anzahl lokaler Beispieldatensaetze je M365-Treffertabelle im JSON-Detailreport.
.EXAMPLE
    .\Compare-CisoAssistantDatabases.ps1
.EXAMPLE
    .\Compare-CisoAssistantDatabases.ps1 -SampleLimit 0
.NOTES
    Read-only Diagnose. Die Quelldatenbanken werden nicht veraendert.
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
        [string[]]$Arguments = @()
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    [pscustomobject]@{
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

function Get-CisoDatabaseInspection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$DatabaseFile,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Image,

        [Parameter(Mandatory)]
        [ValidateRange(0, 20)]
        [int]$LocalSampleLimit
    )

    $databaseDirectory = $DatabaseFile.Directory.FullName
    $toolDirectory = $PSScriptRoot
    $helperPath = Join-Path -Path $toolDirectory -ChildPath 'Inspect-CisoAssistantDatabase.py'
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Python helper not found: $helperPath"
    }

    $databaseMount = "type=bind,source=$databaseDirectory,target=/data,readonly"
    $toolMount = "type=bind,source=$toolDirectory,target=/tool,readonly"
    $containerDatabasePath = "/data/$($DatabaseFile.Name)"

    $dockerArguments = @(
        'run',
        '--rm',
        '--pull', 'never',
        '--read-only',
        '--network', 'none',
        '--mount', $databaseMount,
        '--mount', $toolMount,
        '--entrypoint', 'python',
        $Image,
        '-B',
        '/tool/Inspect-CisoAssistantDatabase.py',
        $containerDatabasePath,
        '--sample-limit', $LocalSampleLimit.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    )

    $nativeResult = Invoke-NativeProcess -FilePath 'docker' -Arguments $dockerArguments
    if ([string]::IsNullOrWhiteSpace($nativeResult.StdOut)) {
        throw "Database inspection returned no JSON. Docker stderr: $($nativeResult.StdErr.Trim())"
    }

    try {
        $inspection = $nativeResult.StdOut | ConvertFrom-Json -Depth 50
    }
    catch {
        throw "Database inspection returned invalid JSON. Docker stderr: $($nativeResult.StdErr.Trim())"
    }

    if ($nativeResult.ExitCode -ne 0 -or $inspection.status -ne 'ok') {
        $inspectionError = if ($inspection.PSObject.Properties.Name -contains 'error') { $inspection.error } else { $nativeResult.StdErr.Trim() }
        throw "Database inspection failed: $inspectionError"
    }

    return $inspection
}

function Get-CisoSummaryRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$InstanceResult
    )

    if ($InstanceResult.Status -ne 'OK') {
        return [pscustomobject]@{
            Instance            = $InstanceResult.Instance
            Status              = $InstanceResult.Status
            DatabaseMB          = $null
            LastWriteTimeUtc    = $null
            HashPrefix          = $null
            Tables              = $null
            TotalRows           = $null
            BusinessRows        = $null
            AssetRows           = $null
            AssetM365Matches    = $null
            EvidenceRows        = $null
            RiskRows            = $null
            AssessmentRows      = $null
            M365KeywordMatches  = $null
            MigrationCount      = $null
            Error               = $InstanceResult.Error
        }
    }

    $inspection = $InstanceResult.Inspection
    $categoryRows = $inspection.summary.category_rows
    $categoryMatches = $inspection.summary.category_m365_matches

    return [pscustomobject]@{
        Instance            = $InstanceResult.Instance
        Status              = 'OK'
        DatabaseMB          = [math]::Round(($InstanceResult.Length / 1MB), 2)
        LastWriteTimeUtc    = $InstanceResult.LastWriteTimeUtc
        HashPrefix          = $InstanceResult.Sha256.Substring(0, [math]::Min(16, $InstanceResult.Sha256.Length))
        Tables              = [int]$inspection.summary.table_count
        TotalRows           = [int64]$inspection.summary.total_rows
        BusinessRows        = [int64]$inspection.summary.business_rows
        AssetRows           = [int64]$categoryRows.asset
        AssetM365Matches    = [int64]$categoryMatches.asset
        EvidenceRows        = [int64]$categoryRows.evidence
        RiskRows            = [int64]$categoryRows.risk
        AssessmentRows      = [int64]$categoryRows.assessment
        M365KeywordMatches  = [int64]$inspection.summary.m365_keyword_matches
        MigrationCount      = [int64]$inspection.migrations.count
        Error               = $null
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
            Where-Object Status -eq 'OK' |
            Group-Object -Property Sha256 |
            Where-Object Count -gt 1
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# CISO Assistant Database Comparison')
    $lines.Add('')
    $lines.Add("Erstellt: $($GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss K'))")
    $lines.Add('')
    $lines.Add('## Kernaussage')
    $lines.Add('')
    $lines.Add($candidateText)
    $lines.Add('')
    $lines.Add('Die Bewertung ist eine technische Heuristik. Fuer die Zuordnung des frueheren M365-Imports sind insbesondere AssetM365Matches, AssetRows, Evidenzen, Aenderungszeitpunkt und Datenbank-Hash relevant.')
    $lines.Add('')
    $lines.Add('## Vergleich')
    $lines.Add('')
    $lines.Add('| Instance | Status | DB MB | LastWrite UTC | Asset rows | Asset M365 | Evidence | Risks | Assessments | M365 total | Migrations | Hash |')
    $lines.Add('|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---|')

    foreach ($row in $SummaryRows) {
        $lines.Add("| $($row.Instance) | $($row.Status) | $($row.DatabaseMB) | $($row.LastWriteTimeUtc) | $($row.AssetRows) | $($row.AssetM365Matches) | $($row.EvidenceRows) | $($row.RiskRows) | $($row.AssessmentRows) | $($row.M365KeywordMatches) | $($row.MigrationCount) | $($row.HashPrefix) |")
    }

    $lines.Add('')
    $lines.Add('## Identische Datenbanken')
    $lines.Add('')
    if ($hashGroups.Count -eq 0) {
        $lines.Add('Keine identischen SHA-256-Datenbankdateien gefunden.')
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
    $lines.Add('## Sicherheitsmerkmale der Auswertung')
    $lines.Add('')
    $lines.Add('- Quelldatenbanken werden read-only gemountet.')
    $lines.Add('- SQLite wird mit mode=ro und PRAGMA query_only=ON geoeffnet.')
    $lines.Add('- Der Analyse-Container laeuft mit --read-only und --network none.')
    $lines.Add('- --pull never verhindert einen Image-Download.')
    $lines.Add('- Bestehende CISO-Container werden weder gestartet noch gestoppt.')
    $lines.Add('- Es werden keine Migrationen oder schreibenden Django-Kommandos ausgefuehrt.')

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

    $jsonPath = Join-Path -Path $DestinationDirectory -ChildPath 'ciso-database-comparison.json'
    $csvPath = Join-Path -Path $DestinationDirectory -ChildPath 'ciso-database-comparison.csv'
    $markdownPath = Join-Path -Path $DestinationDirectory -ChildPath 'ciso-database-comparison.md'

    $payload = [pscustomobject]@{
        GeneratedAt = $GeneratedAt.ToString('o')
        Summary     = $SummaryRows
        Instances   = $DetailedResults
    }

    $payload | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    $SummaryRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM
    Write-CisoMarkdownReport -SummaryRows $SummaryRows -DetailedResults $DetailedResults -Path $markdownPath -GeneratedAt $GeneratedAt

    [pscustomobject]@{
        Json     = $jsonPath
        Csv      = $csvPath
        Markdown = $markdownPath
    }
}

if (-not (Test-DockerAvailable)) {
    throw 'Docker CLI wurde nicht gefunden. Bitte Docker Desktop starten bzw. die Docker CLI in PATH bereitstellen.'
}

$imageCheck = Invoke-NativeProcess -FilePath 'docker' -Arguments @('image', 'inspect', $BackendImage)
if ($imageCheck.ExitCode -ne 0) {
    throw "Das Backend-Image '$BackendImage' ist lokal nicht vorhanden. Das Skript laedt absichtlich kein Image herunter (--pull never)."
}

$generatedAt = Get-Date
$runDirectoryName = $generatedAt.ToString('yyyyMMdd-HHmmss')
$destinationDirectory = Join-Path -Path $OutputRoot -ChildPath $runDirectoryName
$detailedResults = [System.Collections.Generic.List[object]]::new()

foreach ($instance in $Instances) {
    $instancePath = Join-Path -Path $DockerRoot -ChildPath $instance
    if (-not (Test-Path -LiteralPath $instancePath -PathType Container)) {
        $detailedResults.Add([pscustomobject]@{
            Instance = $instance
            Status   = 'MISSING_INSTANCE'
            Error    = "Instance directory not found: $instancePath"
        })
        continue
    }

    $databaseFile = Get-CisoDatabaseFile -InstancePath $instancePath
    if ($null -eq $databaseFile) {
        $detailedResults.Add([pscustomobject]@{
            Instance = $instance
            Status   = 'MISSING_DATABASE'
            Error    = "No *.sqlite3 database found below: $(Join-Path -Path $instancePath -ChildPath 'db')"
        })
        continue
    }

    try {
        $hash = Get-FileHash -LiteralPath $databaseFile.FullName -Algorithm SHA256
        $inspection = Get-CisoDatabaseInspection -DatabaseFile $databaseFile -Image $BackendImage -LocalSampleLimit $SampleLimit
        $detailedResults.Add([pscustomobject]@{
            Instance         = $instance
            Status           = 'OK'
            Error            = $null
            DatabasePath     = $databaseFile.FullName
            Length           = $databaseFile.Length
            LastWriteTimeUtc = $databaseFile.LastWriteTimeUtc.ToString('o')
            Sha256           = $hash.Hash
            Inspection       = $inspection
        })
    }
    catch {
        $detailedResults.Add([pscustomobject]@{
            Instance         = $instance
            Status           = 'ERROR'
            Error            = $_.Exception.Message
            DatabasePath     = $databaseFile.FullName
            Length           = $databaseFile.Length
            LastWriteTimeUtc = $databaseFile.LastWriteTimeUtc.ToString('o')
            Sha256           = $null
            Inspection       = $null
        })
    }
}

$summaryRows = @($detailedResults | ForEach-Object { Get-CisoSummaryRow -InstanceResult $_ })
$exportedFiles = Export-CisoComparison -SummaryRows $summaryRows -DetailedResults @($detailedResults) -DestinationDirectory $destinationDirectory -GeneratedAt $generatedAt

$summaryRows | Format-Table -AutoSize
Write-Information "`nMarkdown report: $($exportedFiles.Markdown)" -InformationAction Continue
Write-Information "JSON details:    $($exportedFiles.Json)" -InformationAction Continue
Write-Information "CSV summary:     $($exportedFiles.Csv)" -InformationAction Continue
