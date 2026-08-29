#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunDirectory,

    [int] $ProcessId,

    [datetime] $ResumeStartedUtc,

    [string] $StandardErrorPath,

    [string] $AllowedRunsRoot,

    [string] $AllowedLaunchRoot,

    [ValidatePattern('^[A-Fa-f0-9]{32}$')]
    [string] $LaunchToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-TrustedStatusPath
{
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path))
    {
        throw "Required status path was not found: $Path"
    }

    $currentPath = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($currentPath))
    {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        {
            throw "Status path traverses a reparse point: $currentPath"
        }

        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or
            [string]::Equals($parentPath, $currentPath, [StringComparison]::OrdinalIgnoreCase))
        {
            break
        }
        $currentPath = $parentPath
    }
}

function Get-BoundedFileTail
{
    param(
        [string] $Path,

        [ValidateRange(1, 1048576)]
        [int] $MaximumBytes = 262144,

        [ValidateRange(1, 100)]
        [int] $MaximumLines = 8
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path))
    {
        return @()
    }

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite)
    try
    {
        $start = [math]::Max(0, $stream.Length - $MaximumBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new(
            $stream,
            [Text.Encoding]::UTF8,
            $true,
            4096,
            $true)
        try
        {
            $text = $reader.ReadToEnd()
        }
        finally
        {
            $reader.Dispose()
        }
    }
    finally
    {
        $stream.Dispose()
    }

    if ($start -gt 0)
    {
        $newline = $text.IndexOf("`n")
        $text = if ($newline -ge 0) { $text.Substring($newline + 1) } else { "" }
    }

    return @($text -split "`r?`n" | Select-Object -Last $MaximumLines)
}

function Assert-BoundedStatusFile
{
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [long] $MaximumBytes
    )

    Assert-TrustedStatusPath -Path $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Length -gt $MaximumBytes)
    {
        throw "Status artifact exceeds its safety limit: $Path"
    }
}

$RunDirectory = [IO.Path]::GetFullPath($RunDirectory)
Assert-TrustedStatusPath -Path $RunDirectory
if (-not [string]::IsNullOrWhiteSpace($AllowedRunsRoot))
{
    $AllowedRunsRoot = [IO.Path]::GetFullPath($AllowedRunsRoot).TrimEnd("\")
    Assert-TrustedStatusPath -Path $AllowedRunsRoot
    $runParent = (Split-Path -Parent $RunDirectory).TrimEnd("\")
    if (-not [string]::Equals($runParent, $AllowedRunsRoot, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Run directory is outside the allowed Runs root."
    }
}

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
$processIdentityValid = $null
$processIdentityFailure = $null
if ($null -ne $process -and $ResumeStartedUtc -gt [datetime]::MinValue)
{
    if ([math]::Abs(($process.StartTime.ToUniversalTime() - $ResumeStartedUtc.ToUniversalTime()).TotalSeconds) -gt 2)
    {
        $processIdentityValid = $false
        $processIdentityFailure = "Process start time does not match the requested ScenarioTest process."
        $process = $null
    }
    else
    {
        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
        $commandLine = [string]$processInfo.CommandLine
        if ($commandLine.IndexOf(
                "Invoke-DirectoryObjectStoreLongevity.ps1",
                [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            [string]::IsNullOrWhiteSpace($LaunchToken) -or
            $commandLine.IndexOf($LaunchToken, [StringComparison]::OrdinalIgnoreCase) -lt 0)
        {
            $processIdentityValid = $false
            $processIdentityFailure = "PID is active but does not belong to the requested ScenarioTest run."
            $process = $null
        }
        else
        {
            $processIdentityValid = $true
        }
    }
}
elseif ($null -ne $process)
{
    $processIdentityValid = $null
    $processIdentityFailure = "Process start time was not supplied; PID reuse could not be verified."
}

$status = if (Test-Path -LiteralPath $statusPath)
{
    Assert-BoundedStatusFile -Path $statusPath -MaximumBytes 8388608
    Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
}
else
{
    $null
}
$summaryCandidate = if ($null -eq $process -and (Test-Path -LiteralPath $summaryPath))
{
    Assert-BoundedStatusFile -Path $summaryPath -MaximumBytes 16777216
    Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
}
else
{
    $null
}
$summaryIsFresh = $null -ne $summaryCandidate -and
    ($ResumeStartedUtc -le [datetime]::MinValue -or
        [datetime]$summaryCandidate.FinishedUtc -ge $ResumeStartedUtc)
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

$events = @(
    if (Test-Path -LiteralPath $eventPath)
    {
        Assert-TrustedStatusPath -Path $eventPath
    }
    foreach ($line in @(Get-BoundedFileTail -Path $eventPath))
    {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or -not $line.EndsWith("}"))
        {
            continue
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
$freshEvents = if ($ResumeStartedUtc -gt [datetime]::MinValue)
{
    @($events | Where-Object { [datetime]$_.TimestampUtc -ge $ResumeStartedUtc })
}
else
{
    $events
}

if ([string]::IsNullOrWhiteSpace($StandardErrorPath))
{
    $launchMetadata = @(
        Get-ChildItem -LiteralPath $RunDirectory -Filter "mcp-*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )
    foreach ($metadataFile in $launchMetadata)
    {
        try
        {
            Assert-BoundedStatusFile -Path $metadataFile.FullName -MaximumBytes 1048576
            $metadata = Get-Content -LiteralPath $metadataFile.FullName -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$metadata.StandardErrorPath))
            {
                $StandardErrorPath = [string]$metadata.StandardErrorPath
                break
            }
        }
        catch
        {
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($StandardErrorPath))
{
    $StandardErrorPath = [IO.Path]::GetFullPath($StandardErrorPath)
    if ([string]::IsNullOrWhiteSpace($AllowedLaunchRoot))
    {
        throw "AllowedLaunchRoot is required before reading a standard-error path."
    }
    $AllowedLaunchRoot = [IO.Path]::GetFullPath($AllowedLaunchRoot).TrimEnd("\")
    Assert-TrustedStatusPath -Path $AllowedLaunchRoot
    $allowedLaunchPrefix = $AllowedLaunchRoot + "\"
    if (-not $StandardErrorPath.StartsWith(
            $allowedLaunchPrefix,
            [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Standard-error path is outside the allowed launch-log root."
    }
    if (Test-Path -LiteralPath $StandardErrorPath)
    {
        Assert-TrustedStatusPath -Path $StandardErrorPath
    }
}
$standardError = @(Get-BoundedFileTail -Path $StandardErrorPath)

$services = @(
    foreach ($serviceName in @(
            "MSExchangeDirCacheService",
            "OLS Service",
            "M365DirectoryProxyService"))
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
$port83Listening = if ($listeners.Count -gt 0)
{
    @($listeners | Where-Object { $_.Port -eq 83 }).Count -gt 0
}
else
{
    $null
}
$port6092Listening = if ($listeners.Count -gt 0)
{
    @($listeners | Where-Object { $_.Port -eq 6092 }).Count -gt 0
}
else
{
    $null
}
$artifactProgress = @(
    foreach ($name in @(
            "status.json",
            "checkpoint.json",
            "events.jsonl",
            "operations.jsonl",
            "validations.jsonl"))
    {
        $path = Join-Path $RunDirectory $name
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -ne $item)
        {
            Assert-TrustedStatusPath -Path $path
        }
        [ordered]@{
            Name = $name
            Exists = $null -ne $item
            Length = if ($null -ne $item) { $item.Length } else { 0 }
            LastWriteTimeUtc = if ($null -ne $item)
            {
                $item.LastWriteTimeUtc.ToString("o")
            }
            else
            {
                $null
            }
        }
    }
)
$statusIsFresh = $null -ne $status -and
    ($ResumeStartedUtc -le [datetime]::MinValue -or
        [datetime]$status.UpdatedUtc -ge $ResumeStartedUtc)

[ordered]@{
    UtcNow = $now.ToString("o")
    ProcessRunning = $null -ne $process
    ProcessIdentityValid = $processIdentityValid
    ProcessIdentityFailure = $processIdentityFailure
    ProcessId = if ($null -ne $process) { $process.Id } else { $ProcessId }
    ProcessStartUtc = if ($null -ne $process)
    {
        $process.StartTime.ToUniversalTime().ToString("o")
    }
    else
    {
        $null
    }
    CpuSeconds = if ($null -ne $process) { $process.CPU } else { $null }
    PrivateMemoryBytes = if ($null -ne $process) { $process.PrivateMemorySize64 } else { $null }
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
