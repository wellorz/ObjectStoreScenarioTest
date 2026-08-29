#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [int] $ProcessId,

    [datetime] $ResumeStartedUtc,

    [string] $StandardErrorPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$now = [datetime]::UtcNow
$statusPath = Join-Path $RunDirectory "status.json"
$summaryPath = Join-Path $RunDirectory "summary.json"
$eventPath = Join-Path $RunDirectory "events.jsonl"
$pausedPath = Join-Path $RunDirectory "PAUSED"

$process = if ($ProcessId -gt 0)
{
    Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
}
else
{
    $null
}
$status = if (Test-Path -LiteralPath $statusPath)
{
    Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
}
else
{
    $null
}
$summaryCandidate = if ($null -eq $process -and (Test-Path -LiteralPath $summaryPath))
{
    Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
}
else
{
    $null
}
$summaryIsFresh = $null -ne $summaryCandidate -and
    ($ResumeStartedUtc -le [datetime]::MinValue -or [datetime]$summaryCandidate.FinishedUtc -ge $ResumeStartedUtc)
$summary = if ($summaryIsFresh)
{
    [ordered]@{
        Status = $summaryCandidate.Status
        StartedUtc = $summaryCandidate.StartedUtc
        FinishedUtc = $summaryCandidate.FinishedUtc
        Counters = $summaryCandidate.Counters
        PendingValidations = $summaryCandidate.PendingValidations
        ScenarioState = $summaryCandidate.ScenarioState
        Failure = $summaryCandidate.Failure
    }
}
else
{
    $null
}
$events = if (Test-Path -LiteralPath $eventPath)
{
    @(
        Get-Content -LiteralPath $eventPath -Tail 8 |
            ForEach-Object {
                $line = $_.Trim()
                if ([string]::IsNullOrWhiteSpace($line) -or -not $line.EndsWith("}"))
                {
                    return
                }
                try
                {
                    $line | ConvertFrom-Json
                }
                catch
                {
                }
            }
    )
}
else
{
    @()
}
$freshEvents = if ($ResumeStartedUtc -gt [datetime]::MinValue)
{
    @($events | Where-Object { [datetime]$_.TimestampUtc -ge $ResumeStartedUtc })
}
else
{
    $events
}
$standardError = if (-not [string]::IsNullOrWhiteSpace($StandardErrorPath) -and
    (Test-Path -LiteralPath $StandardErrorPath) -and
    (Get-Item -LiteralPath $StandardErrorPath).Length -gt 0)
{
    @(Get-Content -LiteralPath $StandardErrorPath -Tail 8)
}
else
{
    @()
}
$services = @(
    foreach ($serviceName in @("MSExchangeDirCacheService", "OLS Service", "M365DirectoryProxyService"))
    {
        $service = Get-Service $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service)
        {
            [ordered]@{
                Name = $serviceName
                Status = "Missing"
            }
        }
        else
        {
            [ordered]@{
                Name = $service.Name
                Status = $service.Status.ToString()
            }
        }
    }
)
$listeners = try
{
    @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners())
}
catch
{
    @()
}
$port83Listening = if ($listeners.Count -gt 0) { @($listeners | Where-Object { $_.Port -eq 83 }).Count -gt 0 } else { $null }
$port6092Listening = if ($listeners.Count -gt 0) { @($listeners | Where-Object { $_.Port -eq 6092 }).Count -gt 0 } else { $null }
$artifactProgress = @(
    foreach ($name in @("status.json", "checkpoint.json", "events.jsonl", "operations.jsonl", "validations.jsonl"))
    {
        $path = Join-Path $RunDirectory $name
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        [ordered]@{
            Name = $name
            Exists = $null -ne $item
            Length = if ($null -ne $item) { $item.Length } else { 0 }
            LastWriteTimeUtc = if ($null -ne $item) { $item.LastWriteTimeUtc.ToString("o") } else { $null }
        }
    }
)
$statusIsFresh = $null -ne $status -and
    ($ResumeStartedUtc -le [datetime]::MinValue -or [datetime]$status.UpdatedUtc -ge $ResumeStartedUtc)

[ordered]@{
    UtcNow = $now.ToString("o")
    ProcessRunning = $null -ne $process
    ProcessId = if ($null -ne $process) { $process.Id } else { $ProcessId }
    CpuSeconds = if ($null -ne $process) { $process.CPU } else { $null }
    Status = $status
    StatusIsFresh = $statusIsFresh
    TerminalSummary = $summary
    StaleSummaryIgnored = $null -ne $summaryCandidate -and -not $summaryIsFresh
    PausedMarkerPresent = Test-Path -LiteralPath $pausedPath
    FreshEvents = $freshEvents
    StandardError = $standardError
    Services = $services
    Port83Listening = $port83Listening
    Port6092Listening = $port6092Listening
    ArtifactProgress = $artifactProgress
} | ConvertTo-Json -Depth 10 -Compress
