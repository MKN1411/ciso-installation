#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only provenance inventory for local CISO Assistant instances.
.DESCRIPTION
    Collects Git, Docker Compose and PowerShell-history evidence for the local
    CISO Assistant instances without changing repositories, containers or files.

    Important: Deploy-Local.ps1 clones the upstream repository
    https://github.com/intuitem/ciso-assistant-community.git into every target
    instance directory. Therefore the instance's own Git origin normally proves
    the upstream CISO Assistant source, but not which wrapper repository
    (for example MKN1411/ciso-installation or ankbs/ciso-installation) launched
    the deployment. To reconstruct that wrapper provenance, this script also
    inspects local wrapper repositories and PowerShell command history.
.PARAMETER DockerRoot
    Root directory containing ciso-assistant-* installations.
.PARAMETER GrcRoot
    Root directory in which wrapper/onboarding Git repositories are expected.
.PARAMETER OutputRoot
    Destination for JSON, CSV and Markdown reports.
.EXAMPLE
    .\Get-CisoAssistantInstanceProvenance.ps1
.NOTES
    Read-only. No git pull/fetch/checkout, no docker start/stop/up/down, no file edits.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DockerRoot = 'D:\_Docker',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$GrcRoot = 'D:\_GRC_Agent',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = 'D:\_Docker\_CisoInstanceProvenance',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$Instances = @(
        'ciso-assistant-local',
        'ciso-assistant-dev01',
        'ciso-assistant-dev02',
        'ciso-assistant-grc-dev'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ReadOnlyNativeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @(),

        [Parameter()]
        [string]$WorkingDirectory
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout.Trim()
        StdErr   = $stderr.Trim()
    }
}

function Get-GitValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = Invoke-ReadOnlyNativeCommand -FilePath 'git' -Arguments (@('-C', $RepositoryPath) + $Arguments)
    if ($result.ExitCode -eq 0) {
        return $result.StdOut
    }
    return $null
}

function Get-GitRepositoryInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath
    )

    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryPath '.git'))) {
        return $null
    }

    $origin = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('config', '--get', 'remote.origin.url')
    $branch = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('branch', '--show-current')
    $head = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('rev-parse', 'HEAD')
    $commitDate = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('log', '-1', '--format=%cI')
    $commitSubject = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('log', '-1', '--format=%s')
    $reflogFirst = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('reflog', '--all', '--reverse', '--date=iso-strict', '--format=%gD|%cI|%gs')
    $status = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('status', '--porcelain=v1', '--untracked-files=no')

    $firstReflogLine = $null
    if (-not [string]::IsNullOrWhiteSpace($reflogFirst)) {
        $firstReflogLine = ($reflogFirst -split "`r?`n" | Select-Object -First 1)
    }

    return [pscustomobject]@{
        RepositoryPath      = $RepositoryPath
        Origin              = $origin
        Branch              = $branch
        Head                = $head
        LatestCommitDate    = $commitDate
        LatestCommitSubject = $commitSubject
        FirstReflogEntry    = $firstReflogLine
        HasTrackedChanges   = -not [string]::IsNullOrWhiteSpace($status)
    }
}

function Get-ComposeEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ProjectName
    )

    if ($null -eq (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)) {
        return $null
    }

    $psResult = Invoke-ReadOnlyNativeCommand -FilePath 'docker' -Arguments @(
        'ps', '-a',
        '--filter', "label=com.docker.compose.project=$ProjectName",
        '--format', '{{.ID}}'
    )

    if ($psResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($psResult.StdOut)) {
        return $null
    }

    $containerIds = @($psResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($containerId in $containerIds) {
        $inspectResult = Invoke-ReadOnlyNativeCommand -FilePath 'docker' -Arguments @(
            'inspect',
            '--format', '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{.State.Status}}',
            $containerId
        )
        if ($inspectResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($inspectResult.StdOut)) {
            $parts = $inspectResult.StdOut -split '\|', 5
            $rows.Add([pscustomobject]@{
                Container    = if ($parts.Count -gt 0) { $parts[0].TrimStart('/') } else { $null }
                Project      = if ($parts.Count -gt 1) { $parts[1] } else { $null }
                WorkingDir   = if ($parts.Count -gt 2) { $parts[2] } else { $null }
                ConfigFiles  = if ($parts.Count -gt 3) { $parts[3] } else { $null }
                Status       = if ($parts.Count -gt 4) { $parts[4] } else { $null }
            })
        }
    }

    return @($rows)
}

function Get-WrapperRepositories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath
    )

    $repositories = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return @()
    }

    $gitDirectories = @(
        Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object Name -eq '.git'
    )

    foreach ($gitDirectory in $gitDirectories) {
        $repoPath = $gitDirectory.Parent.FullName
        $info = Get-GitRepositoryInfo -RepositoryPath $repoPath
        if ($null -ne $info) {
            $repositories.Add($info)
        }
    }

    return @($repositories | Sort-Object RepositoryPath -Unique)
}

function Get-PowerShellHistoryEvidence {
    [CmdletBinding()]
    param()

    $patterns = @(
        'ciso-installation',
        'Deploy-Local.ps1',
        'Install-LocalDocker.ps1',
        'MKN1411',
        'ankbs',
        'dev01',
        'dev02',
        'grc-dev'
    )

    $historyCandidates = [System.Collections.Generic.List[string]]::new()
    if ($env:APPDATA) {
        $historyRoot = Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine'
        if (Test-Path -LiteralPath $historyRoot -PathType Container) {
            Get-ChildItem -LiteralPath $historyRoot -File -Filter '*_history.txt' -ErrorAction SilentlyContinue |
                ForEach-Object { $historyCandidates.Add($_.FullName) }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($historyFile in ($historyCandidates | Sort-Object -Unique)) {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $historyFile -ErrorAction SilentlyContinue)) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $matched = @($patterns | Where-Object { $line -match [regex]::Escape($_) })
            if ($matched.Count -gt 0) {
                $results.Add([pscustomobject]@{
                    HistoryFile = $historyFile
                    LineNumber  = $lineNumber
                    Matched     = ($matched -join ', ')
                    Command     = $line
                })
            }
        }
    }

    return @($results)
}

function Get-InstanceInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath
    )

    $path = Join-Path $RootPath $InstanceName
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{
            Instance = $InstanceName
            Status   = 'MISSING'
            Path     = $path
        }
    }

    $directory = Get-Item -LiteralPath $path
    $gitInfo = Get-GitRepositoryInfo -RepositoryPath $path
    $compose = Get-ComposeEvidence -ProjectName $InstanceName

    $composePath = Join-Path $path 'docker-compose.yml'
    $composeHash = $null
    if (Test-Path -LiteralPath $composePath -PathType Leaf) {
        $composeHash = (Get-FileHash -LiteralPath $composePath -Algorithm SHA256).Hash
    }

    return [pscustomobject]@{
        Instance         = $InstanceName
        Status           = 'OK'
        Path             = $path
        DirectoryCreated = $directory.CreationTime.ToString('o')
        DirectoryUpdated = $directory.LastWriteTime.ToString('o')
        Git              = $gitInfo
        ComposeSha256    = $composeHash
        DockerCompose    = $compose
    }
}

function Export-ProvenanceReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$InstanceResults,

        [Parameter(Mandatory)]
        [object[]]$WrapperRepositories,

        [Parameter(Mandatory)]
        [object[]]$HistoryEvidence,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Destination -Force
    }

    $jsonPath = Join-Path $Destination 'ciso-instance-provenance.json'
    $csvPath = Join-Path $Destination 'ciso-instance-provenance.csv'
    $mdPath = Join-Path $Destination 'ciso-instance-provenance.md'

    $summary = foreach ($item in $InstanceResults) {
        [pscustomobject]@{
            Instance           = $item.Instance
            Status             = $item.Status
            DirectoryCreated   = if ($item.Status -eq 'OK') { $item.DirectoryCreated } else { $null }
            Origin             = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.Origin } else { $null }
            Branch             = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.Branch } else { $null }
            Head               = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.Head } else { $null }
            FirstReflogEntry   = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.FirstReflogEntry } else { $null }
            HasTrackedChanges  = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.HasTrackedChanges } else { $null }
            ComposeSha256      = if ($item.Status -eq 'OK') { $item.ComposeSha256 } else { $null }
            ComposeWorkingDirs = if ($item.Status -eq 'OK' -and $null -ne $item.DockerCompose) { (@($item.DockerCompose.WorkingDir | Sort-Object -Unique) -join '; ') } else { $null }
        }
    }

    $payload = [pscustomobject]@{
        GeneratedAt         = (Get-Date).ToString('o')
        ImportantNote       = 'Instance Git origins normally point to intuitem/ciso-assistant-community because Deploy-Local.ps1 clones that upstream directly. Wrapper provenance must be inferred from wrapper repositories, command history and timeline evidence.'
        Instances           = $InstanceResults
        WrapperRepositories = $WrapperRepositories
        PowerShellHistory   = $HistoryEvidence
    }
    $payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    $summary | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# CISO Assistant Instance Provenance')
    $lines.Add('')
    $lines.Add('> Important: the CISO instance repository origin is expected to be `intuitem/ciso-assistant-community`, because `Deploy-Local.ps1` clones that upstream directly. It does **not** by itself identify whether the launcher was `MKN1411/ciso-installation` or a fork such as `ankbs/ciso-installation`.')
    $lines.Add('')
    $lines.Add('## Instances')
    $lines.Add('')
    $lines.Add('| Instance | Created | Origin | Branch | HEAD | Tracked changes | Compose working dir |')
    $lines.Add('|---|---|---|---|---|---:|---|')
    foreach ($row in $summary) {
        $headShort = if ($row.Head) { $row.Head.Substring(0, [math]::Min(12, $row.Head.Length)) } else { '' }
        $lines.Add("| $($row.Instance) | $($row.DirectoryCreated) | $($row.Origin) | $($row.Branch) | $headShort | $($row.HasTrackedChanges) | $($row.ComposeWorkingDirs) |")
    }

    $lines.Add('')
    $lines.Add('## Wrapper repositories found under GRC root')
    $lines.Add('')
    if ($WrapperRepositories.Count -eq 0) {
        $lines.Add('No Git repositories found under the configured GRC root.')
    }
    else {
        $lines.Add('| Path | Origin | Branch | HEAD |')
        $lines.Add('|---|---|---|---|')
        foreach ($repo in $WrapperRepositories) {
            $headShort = if ($repo.Head) { $repo.Head.Substring(0, [math]::Min(12, $repo.Head.Length)) } else { '' }
            $lines.Add("| $($repo.RepositoryPath) | $($repo.Origin) | $($repo.Branch) | $headShort |")
        }
    }

    $lines.Add('')
    $lines.Add('## PowerShell history evidence')
    $lines.Add('')
    if ($HistoryEvidence.Count -eq 0) {
        $lines.Add('No matching PowerShell history lines found.')
    }
    else {
        foreach ($entry in $HistoryEvidence) {
            $safeCommand = $entry.Command.Replace('|', '\|')
            $lines.Add("- `$($entry.HistoryFile):$($entry.LineNumber)` [$($entry.Matched)] `$safeCommand`")
        }
    }

    [System.IO.File]::WriteAllLines($mdPath, $lines, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Json     = $jsonPath
        Csv      = $csvPath
        Markdown = $mdPath
    }
}

if ($null -eq (Get-Command -Name 'git' -ErrorAction SilentlyContinue)) {
    throw 'Git CLI was not found in PATH.'
}

$instanceResults = [System.Collections.Generic.List[object]]::new()
foreach ($instance in $Instances) {
    $instanceResults.Add((Get-InstanceInfo -InstanceName $instance -RootPath $DockerRoot))
}

$wrapperRepositories = @(Get-WrapperRepositories -RootPath $GrcRoot)
$historyEvidence = @(Get-PowerShellHistoryEvidence)
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$destination = Join-Path $OutputRoot $timestamp
$exported = Export-ProvenanceReport -InstanceResults @($instanceResults) -WrapperRepositories $wrapperRepositories -HistoryEvidence $historyEvidence -Destination $destination

$instanceResults |
    Select-Object Instance, Status, DirectoryCreated,
        @{Name='Origin';Expression={ if ($null -ne $_.Git) { $_.Git.Origin } else { $null } }},
        @{Name='HEAD';Expression={ if ($null -ne $_.Git -and $_.Git.Head) { $_.Git.Head.Substring(0, [math]::Min(12, $_.Git.Head.Length)) } else { $null } }} |
    Format-Table -AutoSize

Write-Information '' -InformationAction Continue
Write-Information 'Wrapper repositories:' -InformationAction Continue
$wrapperRepositories |
    Select-Object RepositoryPath, Origin, Branch,
        @{Name='HEAD';Expression={ if ($_.Head) { $_.Head.Substring(0, [math]::Min(12, $_.Head.Length)) } else { $null } }} |
    Format-Table -AutoSize

Write-Information '' -InformationAction Continue
Write-Information ('PowerShell history matches: {0}' -f $historyEvidence.Count) -InformationAction Continue
Write-Information ('Markdown: {0}' -f $exported.Markdown) -InformationAction Continue
Write-Information ('JSON:     {0}' -f $exported.Json) -InformationAction Continue
Write-Information ('CSV:      {0}' -f $exported.Csv) -InformationAction Continue
