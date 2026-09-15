#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only provenance inventory for local CISO Assistant instances.
.DESCRIPTION
    Collects Git, Docker Compose, local wrapper repository and PowerShell history
    evidence for the known CISO Assistant instances. The script does not start,
    stop, update or modify repositories, containers or databases.

    Important: Deploy-Local.ps1 clones the upstream repository
    https://github.com/intuitem/ciso-assistant-community.git into each local
    instance directory. Therefore the Git origin inside a CISO instance normally
    identifies the upstream CISO Assistant project, not the wrapper repository
    (for example MKN1411/ciso-installation or ankbs/ciso-installation) from which
    the deployment script was launched.
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

function Invoke-ReadOnlyCommand {
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

    $result = Invoke-ReadOnlyCommand -FilePath 'git' -Arguments (@('-C', $RepositoryPath) + $Arguments)
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

    $gitPath = Join-Path -Path $RepositoryPath -ChildPath '.git'
    if (-not (Test-Path -LiteralPath $gitPath)) {
        return $null
    }

    $origin = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('config', '--get', 'remote.origin.url')
    $branch = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('branch', '--show-current')
    $head = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('rev-parse', 'HEAD')
    $commitDate = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('log', '-1', '--format=%cI')
    $commitSubject = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('log', '-1', '--format=%s')
    $status = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('status', '--porcelain=v1', '--untracked-files=no')

    $firstReflogEntry = $null
    $reflog = Get-GitValue -RepositoryPath $RepositoryPath -Arguments @('reflog', 'show', '--all', '--reverse', '--date=iso-strict', '--format=%gD|%cI|%gs')
    if (-not [string]::IsNullOrWhiteSpace($reflog)) {
        $firstReflogEntry = @($reflog -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)[0]
    }

    $gitDirectoryItem = Get-Item -LiteralPath $gitPath -Force -ErrorAction SilentlyContinue
    $configPath = Join-Path -Path $gitPath -ChildPath 'config'
    $configItem = Get-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        RepositoryPath      = $RepositoryPath
        Origin              = $origin
        Branch              = $branch
        Head                = $head
        LatestCommitDate    = $commitDate
        LatestCommitSubject = $commitSubject
        FirstReflogEntry    = $firstReflogEntry
        HasTrackedChanges   = -not [string]::IsNullOrWhiteSpace($status)
        GitDirectoryCreated = if ($null -ne $gitDirectoryItem) { $gitDirectoryItem.CreationTime.ToString('o') } else { $null }
        GitConfigModified   = if ($null -ne $configItem) { $configItem.LastWriteTime.ToString('o') } else { $null }
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
        return @()
    }

    $containerList = Invoke-ReadOnlyCommand -FilePath 'docker' -Arguments @(
        'ps', '-a', '--filter', ('label=com.docker.compose.project={0}' -f $ProjectName), '--format', '{{.ID}}'
    )

    if ($containerList.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($containerList.StdOut)) {
        return @()
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($containerId in @($containerList.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $inspect = Invoke-ReadOnlyCommand -FilePath 'docker' -Arguments @(
            'inspect',
            '--format', '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{.State.Status}}|{{.Created}}',
            $containerId
        )

        if ($inspect.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($inspect.StdOut)) {
            $parts = $inspect.StdOut -split '\|', 6
            $rows.Add([pscustomobject]@{
                Container   = if ($parts.Count -gt 0) { $parts[0].TrimStart('/') } else { $null }
                Project     = if ($parts.Count -gt 1) { $parts[1] } else { $null }
                WorkingDir  = if ($parts.Count -gt 2) { $parts[2] } else { $null }
                ConfigFiles = if ($parts.Count -gt 3) { $parts[3] } else { $null }
                Status      = if ($parts.Count -gt 4) { $parts[4] } else { $null }
                Created     = if ($parts.Count -gt 5) { $parts[5] } else { $null }
            })
        }
    }

    return @($rows)
}

function Get-WrapperRepositoryInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return @()
    }

    $repositories = [System.Collections.Generic.List[object]]::new()
    $gitDirectories = @(
        Get-ChildItem -LiteralPath $RootPath -Directory -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '.git' }
    )

    foreach ($gitDirectory in $gitDirectories) {
        $repositoryPath = $gitDirectory.Parent.FullName
        $info = Get-GitRepositoryInfo -RepositoryPath $repositoryPath
        if ($null -ne $info) {
            $repositories.Add($info)
        }
    }

    return @($repositories | Sort-Object -Property RepositoryPath -Unique)
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

    $historyFiles = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $candidateRoots = @(
            (Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\PowerShell\PSReadLine'),
            (Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\PowerShell\PSReadLine')
        )

        foreach ($candidateRoot in $candidateRoots) {
            if (Test-Path -LiteralPath $candidateRoot -PathType Container) {
                foreach ($file in @(Get-ChildItem -LiteralPath $candidateRoot -File -Filter '*_history.txt' -ErrorAction SilentlyContinue)) {
                    $historyFiles.Add($file.FullName)
                }
            }
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($historyFile in @($historyFiles | Sort-Object -Unique)) {
        $lineNumber = 0
        foreach ($line in @(Get-Content -LiteralPath $historyFile -ErrorAction SilentlyContinue)) {
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

function Get-InstanceProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$InstanceName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RootPath
    )

    $instancePath = Join-Path -Path $RootPath -ChildPath $InstanceName
    if (-not (Test-Path -LiteralPath $instancePath -PathType Container)) {
        return [pscustomobject]@{
            Instance = $InstanceName
            Status   = 'MISSING'
            Path     = $instancePath
        }
    }

    $directory = Get-Item -LiteralPath $instancePath
    $composePath = Join-Path -Path $instancePath -ChildPath 'docker-compose.yml'
    $composeHash = $null
    if (Test-Path -LiteralPath $composePath -PathType Leaf) {
        $composeHash = (Get-FileHash -LiteralPath $composePath -Algorithm SHA256).Hash
    }

    return [pscustomobject]@{
        Instance         = $InstanceName
        Status           = 'OK'
        Path             = $instancePath
        DirectoryCreated = $directory.CreationTime.ToString('o')
        DirectoryUpdated = $directory.LastWriteTime.ToString('o')
        Git              = Get-GitRepositoryInfo -RepositoryPath $instancePath
        ComposeSha256    = $composeHash
        DockerCompose    = @(Get-ComposeEvidence -ProjectName $InstanceName)
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

    $jsonPath = Join-Path -Path $Destination -ChildPath 'ciso-instance-provenance-v2.json'
    $csvPath = Join-Path -Path $Destination -ChildPath 'ciso-instance-provenance-v2.csv'
    $markdownPath = Join-Path -Path $Destination -ChildPath 'ciso-instance-provenance-v2.md'

    $summary = @(
        foreach ($item in $InstanceResults) {
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
                ComposeWorkingDirs = if ($item.Status -eq 'OK' -and @($item.DockerCompose).Count -gt 0) { (@($item.DockerCompose.WorkingDir | Sort-Object -Unique) -join '; ') } else { $null }
                ContainerCreated   = if ($item.Status -eq 'OK' -and @($item.DockerCompose).Count -gt 0) { (@($item.DockerCompose.Created | Sort-Object -Unique) -join '; ') } else { $null }
            }
        }
    )

    $payload = [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('o')
        Note = 'Instance Git origins normally point to intuitem/ciso-assistant-community. Wrapper provenance is reconstructed from local wrapper repositories, history and timeline evidence.'
        Instances = $InstanceResults
        WrapperRepositories = $WrapperRepositories
        PowerShellHistory = $HistoryEvidence
    }

    $payload | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $jsonPath -Encoding utf8NoBOM
    $summary | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8BOM

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# CISO Assistant Instance Provenance V2')
    $lines.Add('')
    $lines.Add('> Instance origins are expected to point to `intuitem/ciso-assistant-community`; use wrapper repositories, PowerShell history and timeline evidence to identify the launcher.')
    $lines.Add('')
    $lines.Add('## Instances')
    $lines.Add('')
    $lines.Add('| Instance | Created | Origin | Branch | HEAD | Tracked changes | Compose working dir | Container created |')
    $lines.Add('|---|---|---|---|---|---:|---|---|')

    foreach ($row in $summary) {
        $headShort = if (-not [string]::IsNullOrWhiteSpace($row.Head)) { $row.Head.Substring(0, [math]::Min(12, $row.Head.Length)) } else { '' }
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f $row.Instance, $row.DirectoryCreated, $row.Origin, $row.Branch, $headShort, $row.HasTrackedChanges, $row.ComposeWorkingDirs, $row.ContainerCreated))
    }

    $lines.Add('')
    $lines.Add('## Wrapper repositories under GRC root')
    $lines.Add('')
    if ($WrapperRepositories.Count -eq 0) {
        $lines.Add('No Git repositories found under the configured GRC root.')
    }
    else {
        $lines.Add('| Path | Origin | Branch | HEAD | First reflog |')
        $lines.Add('|---|---|---|---|---|')
        foreach ($repo in $WrapperRepositories) {
            $headShort = if (-not [string]::IsNullOrWhiteSpace($repo.Head)) { $repo.Head.Substring(0, [math]::Min(12, $repo.Head.Length)) } else { '' }
            $lines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $repo.RepositoryPath, $repo.Origin, $repo.Branch, $headShort, $repo.FirstReflogEntry))
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
            $safeCommand = [string]$entry.Command
            $safeCommand = $safeCommand.Replace('|', '\|')
            $lines.Add(('- `{0}:{1}` [{2}] `{3}`' -f $entry.HistoryFile, $entry.LineNumber, $entry.Matched, $safeCommand))
        }
    }

    [System.IO.File]::WriteAllLines($markdownPath, $lines, [System.Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{
        Json = $jsonPath
        Csv = $csvPath
        Markdown = $markdownPath
    }
}

if ($null -eq (Get-Command -Name 'git' -ErrorAction SilentlyContinue)) {
    throw 'Git CLI was not found in PATH.'
}

$instanceResults = [System.Collections.Generic.List[object]]::new()
foreach ($instance in $Instances) {
    $instanceResults.Add((Get-InstanceProvenance -InstanceName $instance -RootPath $DockerRoot))
}

$wrapperRepositories = @(Get-WrapperRepositoryInfo -RootPath $GrcRoot)
$historyEvidence = @(Get-PowerShellHistoryEvidence)
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$destination = Join-Path -Path $OutputRoot -ChildPath $timestamp
$exported = Export-ProvenanceReport -InstanceResults @($instanceResults) -WrapperRepositories $wrapperRepositories -HistoryEvidence $historyEvidence -Destination $destination

$summaryForConsole = @(
    foreach ($item in $instanceResults) {
        [pscustomobject]@{
            Instance = $item.Instance
            Status = $item.Status
            Created = if ($item.Status -eq 'OK') { $item.DirectoryCreated } else { $null }
            Origin = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.Origin } else { $null }
            Branch = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.Branch } else { $null }
            FirstReflog = if ($item.Status -eq 'OK' -and $null -ne $item.Git) { $item.Git.FirstReflogEntry } else { $null }
        }
    }
)

$summaryForConsole | Format-Table -AutoSize

Write-Information '' -InformationAction Continue
Write-Information ('Wrapper repositories found: {0}' -f $wrapperRepositories.Count) -InformationAction Continue
foreach ($repo in $wrapperRepositories) {
    Write-Information ('  {0} -> {1}' -f $repo.RepositoryPath, $repo.Origin) -InformationAction Continue
}

Write-Information '' -InformationAction Continue
Write-Information ('PowerShell history matches: {0}' -f $historyEvidence.Count) -InformationAction Continue
Write-Information ('JSON: {0}' -f $exported.Json) -InformationAction Continue
Write-Information ('CSV:  {0}' -f $exported.Csv) -InformationAction Continue
Write-Information ('MD:   {0}' -f $exported.Markdown) -InformationAction Continue
