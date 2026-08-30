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
$parametersPath = Join-Path $RunDirectory "parameters.json"

$process = if ($ProcessId -gt 0)
{
    Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
}
else
{
    $null
}
$parameters = if (Test-Path -LiteralPath $parametersPath)
{
    Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
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
$processIdentityVerified = $false
if ($null -ne $process -and
    $ResumeStartedUtc -gt [datetime]::MinValue -and
    $null -ne $parameters -and
    $null -ne $status)
{
    $startTimeMatches =
        [math]::Abs(($process.StartTime.ToUniversalTime() - $ResumeStartedUtc.ToUniversalTime()).TotalSeconds) -le 2
    $statusPidMatches = [int]$status.ProcessId -eq $ProcessId
    $statusTimeMatches = [datetime]$status.UpdatedUtc -ge $ResumeStartedUtc
    $runIdMatches = [string]::Equals(
        [string]$status.RunId,
        (Split-Path -Leaf $RunDirectory),
        [StringComparison]::OrdinalIgnoreCase)
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    $commandLine = if ($null -ne $processInfo) { [string]$processInfo.CommandLine } else { "" }
    $prefix = [string]$parameters.ObjectPrefix
    $commandMatches = -not [string]::IsNullOrWhiteSpace($prefix) -and
        $commandLine -match "Invoke-DirectoryObjectStoreLongevity\.ps1" -and
        $commandLine.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($commandLine -match "(?i)-ResumeRunDirectory")
    {
        $commandMatches = $commandMatches -and
            $commandLine.IndexOf($RunDirectory, [StringComparison]::OrdinalIgnoreCase) -ge 0
    }
    $processIdentityVerified =
        $startTimeMatches -and
        $statusPidMatches -and
        $statusTimeMatches -and
        $runIdMatches -and
        $commandMatches
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
$operatingSystem = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$freePhysicalMemoryBytes = if ($null -ne $operatingSystem)
{
    [long]$operatingSystem.FreePhysicalMemory * 1KB
}
else
{
    $null
}
$largestWinRmShell = Get-Process -Name "wsmprovhost" -ErrorAction SilentlyContinue |
    Sort-Object PrivateMemorySize64 -Descending |
    Select-Object -First 1

[ordered]@{
    UtcNow = $now.ToString("o")
    ProcessRunning = $null -ne $process
    ProcessId = if ($null -ne $process) { $process.Id } else { $ProcessId }
    ProcessIdentityVerified = $processIdentityVerified
    ProcessStartUtc = if ($null -ne $process) { $process.StartTime.ToUniversalTime().ToString("o") } else { $null }
    ProcessEndUtc = if ($null -eq $process -and $null -ne $summary) { [string]$summary.FinishedUtc } else { $null }
    ProcessExitCode = $null
    CpuSeconds = if ($null -ne $process) { $process.CPU } else { $null }
    PrivateMemoryBytes = if ($null -ne $process) { $process.PrivateMemorySize64 } else { $null }
    Status = $status
    StatusIsFresh = $statusIsFresh
    LastSuccessfulStatusUtc = if ($statusIsFresh) { [string]$status.UpdatedUtc } else { $null }
    TerminalSummary = $summary
    StaleSummaryIgnored = $null -ne $summaryCandidate -and -not $summaryIsFresh
    PausedMarkerPresent = Test-Path -LiteralPath $pausedPath
    FreshEvents = $freshEvents
    StandardError = $standardError
    Services = $services
    Port83Listening = $port83Listening
    Port6092Listening = $port6092Listening
    FreePhysicalMemoryBytes = $freePhysicalMemoryBytes
    LargestWinRmShell = if ($null -ne $largestWinRmShell)
    {
        [ordered]@{
            ProcessId = $largestWinRmShell.Id
            PrivateMemoryBytes = $largestWinRmShell.PrivateMemorySize64
        }
    }
    else
    {
        $null
    }
    ArtifactProgress = $artifactProgress
} | ConvertTo-Json -Depth 10 -Compress
