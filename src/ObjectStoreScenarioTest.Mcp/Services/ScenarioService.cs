using System.Security.Cryptography;
using System.Text.Json;
using ObjectStoreScenarioTest.Mcp.Models;

namespace ObjectStoreScenarioTest.Mcp.Services;

internal sealed class ScenarioService(
    SubstrateMcpClient substrateMcpClient,
    ScenarioRemoteOptions remoteOptions)
{
    public IReadOnlyCollection<ScenarioCommandDefinition> GetCatalog() => ScenarioCatalog.All;

    public async Task<ScenarioStartResult> StartAsync(
        string command,
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side,
        string objectStoreDestination,
        int randomSeed,
        int initialReportIntervalMinutes,
        int steadyReportIntervalMinutes,
        int steadyIntervalAfterMinutes,
        CancellationToken cancellationToken)
    {
        ScenarioCommandDefinition definition = ScenarioCatalog.Get(command);
        ScenarioInputValidator.ValidateStart(
            machineNameOrIp,
            organization,
            objectPrefix,
            side,
            objectStoreDestination,
            randomSeed,
            initialReportIntervalMinutes,
            steadyReportIntervalMinutes,
            steadyIntervalAfterMinutes);
        objectStoreDestination = ScenarioInputValidator.NormalizeObjectStoreDestination(objectStoreDestination);

        VerifiedScripts scripts = await CopyAndVerifyScriptsAsync(
            machineNameOrIp,
            cancellationToken).ConfigureAwait(false);
        string message = await ExecutePowerShellAsync(
            machineNameOrIp,
            BuildStartScript(
                definition,
                organization,
                objectPrefix,
                side.ToUpperInvariant(),
                objectStoreDestination,
                randomSeed,
                scripts),
            cancellationToken).ConfigureAwait(false);
        RemoteStartResult remoteResult = DeserializeMessage<RemoteStartResult>(message);
        string monitoringInstruction =
            $"Monitor every {initialReportIntervalMinutes} minute(s) for the first " +
            $"{steadyIntervalAfterMinutes} traffic minute(s), then every {steadyReportIntervalMinutes} " +
            "minute(s) while healthy. Return to the initial interval after a failure, repair, resume, or regression.";

        return new(
            definition.Name,
            definition.EstimatedMinutes,
            definition.Phases,
            definition.BatchCount,
            machineNameOrIp,
            organization,
            objectPrefix,
            remoteResult.RunId,
            remoteResult.RunDirectory,
            remoteResult.ProcessId,
            remoteResult.ProcessStartUtc,
            remoteResult.StandardOutputPath,
            remoteResult.StandardErrorPath,
            remoteResult.ScriptSha256,
            remoteResult.LaunchToken,
            initialReportIntervalMinutes,
            steadyReportIntervalMinutes,
            steadyIntervalAfterMinutes,
            monitoringInstruction);
    }

    public async Task<ScenarioStartResult> ResumeAsync(
        string machineNameOrIp,
        string runDirectory,
        int initialReportIntervalMinutes,
        int steadyReportIntervalMinutes,
        int steadyIntervalAfterMinutes,
        CancellationToken cancellationToken)
    {
        ScenarioInputValidator.ValidateMachine(machineNameOrIp);
        ScenarioInputValidator.ValidateReportingIntervals(
            initialReportIntervalMinutes,
            steadyReportIntervalMinutes,
            steadyIntervalAfterMinutes);
        runDirectory = ScenarioInputValidator.NormalizeRunDirectory(runDirectory, remoteOptions.RemoteRoot);

        VerifiedScripts scripts = await CopyAndVerifyScriptsAsync(
            machineNameOrIp,
            cancellationToken).ConfigureAwait(false);
        string message = await ExecutePowerShellAsync(
            machineNameOrIp,
            BuildResumeScript(runDirectory, scripts),
            cancellationToken).ConfigureAwait(false);
        RemoteResumeResult remoteResult = DeserializeMessage<RemoteResumeResult>(message);
        ScenarioCommandDefinition definition = ScenarioCatalog.Get(remoteResult.Command);
        string monitoringInstruction =
            $"Monitor every {initialReportIntervalMinutes} minute(s) for the first " +
            $"{steadyIntervalAfterMinutes} stable traffic minute(s) after resume, then every " +
            $"{steadyReportIntervalMinutes} minute(s) while healthy.";

        return new(
            definition.Name,
            definition.EstimatedMinutes,
            definition.Phases,
            definition.BatchCount,
            machineNameOrIp,
            remoteResult.Organization,
            remoteResult.ObjectPrefix,
            remoteResult.RunId,
            runDirectory,
            remoteResult.ProcessId,
            remoteResult.ProcessStartUtc,
            remoteResult.StandardOutputPath,
            remoteResult.StandardErrorPath,
            remoteResult.ScriptSha256,
            remoteResult.LaunchToken,
            initialReportIntervalMinutes,
            steadyReportIntervalMinutes,
            steadyIntervalAfterMinutes,
            monitoringInstruction);
    }

    public async Task<JsonElement> GetStatusAsync(
        string machineNameOrIp,
        string runDirectory,
        int processId,
        DateTimeOffset? processStartUtc,
        string? launchToken,
        CancellationToken cancellationToken)
    {
        ScenarioInputValidator.ValidateMachine(machineNameOrIp);
        runDirectory = ScenarioInputValidator.NormalizeRunDirectory(runDirectory, remoteOptions.RemoteRoot);
        if (processId < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(processId));
        }
        if (processId > 0 && processStartUtc is null)
        {
            throw new ArgumentException(
                "processStartUtc is required when processId is supplied so PID reuse can be detected.",
                nameof(processStartUtc));
        }
        if (processId > 0 && string.IsNullOrWhiteSpace(launchToken))
        {
            throw new ArgumentException(
                "launchToken is required when processId is supplied so the exact process can be verified.",
                nameof(launchToken));
        }
        if (!string.IsNullOrWhiteSpace(launchToken))
        {
            ScenarioInputValidator.ValidateLaunchToken(launchToken);
        }

        VerifiedScripts scripts = await VerifyRemoteScriptsAsync(
            machineNameOrIp,
            cancellationToken).ConfigureAwait(false);
        string command =
            $"& {ScenarioInputValidator.QuotePowerShell(scripts.StatusScriptPath)} " +
            $"-RunDirectory {ScenarioInputValidator.QuotePowerShell(runDirectory)} " +
            $"-AllowedRunsRoot {ScenarioInputValidator.QuotePowerShell(remoteOptions.RunsRoot)} " +
            $"-AllowedLaunchRoot {ScenarioInputValidator.QuotePowerShell(remoteOptions.LaunchLogsRoot)} " +
            $"-ProcessId {processId}" +
            (string.IsNullOrWhiteSpace(launchToken)
                ? string.Empty
                : $" -LaunchToken {ScenarioInputValidator.QuotePowerShell(launchToken)}") +
            (processStartUtc is null
                ? string.Empty
                : $" -ResumeStartedUtc {ScenarioInputValidator.QuotePowerShell(processStartUtc.Value.UtcDateTime.ToString("o"))}");
        string message = await ExecutePowerShellAsync(machineNameOrIp, command, cancellationToken).ConfigureAwait(false);
        return ParseJsonMessage(message);
    }

    public async Task<ScenarioStopResult> StopAsync(
        string machineNameOrIp,
        string runDirectory,
        int processId,
        DateTimeOffset processStartUtc,
        string launchToken,
        CancellationToken cancellationToken)
    {
        ScenarioInputValidator.ValidateMachine(machineNameOrIp);
        runDirectory = ScenarioInputValidator.NormalizeRunDirectory(runDirectory, remoteOptions.RemoteRoot);
        if (processId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(processId));
        }
        ScenarioInputValidator.ValidateLaunchToken(launchToken);

        string command = BuildStopScript(runDirectory, processId, processStartUtc, launchToken);
        string message = await ExecutePowerShellAsync(machineNameOrIp, command, cancellationToken).ConfigureAwait(false);
        RemoteStopResult result = DeserializeMessage<RemoteStopResult>(message);
        return new(runDirectory, processId, result.Stopped, result.Message);
    }

    internal static string BuildStopScript(
        string runDirectory,
        int processId,
        DateTimeOffset processStartUtc,
        string launchToken)
    {
        return $$"""
            $process = Get-Process -Id {{processId}} -ErrorAction SilentlyContinue
            if ($null -eq $process) {
                [ordered]@{ Stopped = $false; Message = 'Process was not running.' } | ConvertTo-Json -Compress
                return
            }
            $expectedStart = [datetimeoffset]{{ScenarioInputValidator.QuotePowerShell(processStartUtc.UtcDateTime.ToString("o"))}}
            if ([math]::Abs(($process.StartTime.ToUniversalTime() - $expectedStart.UtcDateTime).TotalSeconds) -gt 2) {
                throw 'Process identity mismatch; refusing to stop a reused PID.'
            }
            $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId={{processId}}"
            $commandLine = [string]$processInfo.CommandLine
            if ($commandLine.IndexOf('Invoke-DirectoryObjectStoreLongevity.ps1', [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
                $commandLine.IndexOf({{ScenarioInputValidator.QuotePowerShell(launchToken)}}, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw 'Process command line does not belong to the requested ScenarioTest run.'
            }
            Stop-Process -Id {{processId}} -Force -ErrorAction Stop
            [ordered]@{ Stopped = $true; Message = 'Scenario process stopped.' } | ConvertTo-Json -Compress
            """;
    }

    public async Task<JsonElement> GetTimingReportAsync(
        string machineNameOrIp,
        string runDirectory,
        CancellationToken cancellationToken)
    {
        ScenarioInputValidator.ValidateMachine(machineNameOrIp);
        runDirectory = ScenarioInputValidator.NormalizeRunDirectory(runDirectory, remoteOptions.RemoteRoot);
        string command = $$"""
            {{GetTrustedPathFunction()}}
            $runDirectory = {{ScenarioInputValidator.QuotePowerShell(runDirectory)}}
            $allowedRunsRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RunsRoot)}}
            Assert-TrustedScenarioPath -Path $allowedRunsRoot
            Assert-TrustedScenarioPath -Path $runDirectory
            $checkpointPath = Join-Path $runDirectory 'checkpoint.json'
            if (-not (Test-Path -LiteralPath $checkpointPath)) { throw 'checkpoint.json was not found.' }
            Assert-TrustedScenarioPath -Path $checkpointPath
            if ((Get-Item -LiteralPath $checkpointPath).Length -gt 134217728) { throw 'checkpoint.json exceeds the 128-MB safety limit.' }
            $checkpoint = Get-Content -LiteralPath $checkpointPath -Raw | ConvertFrom-Json
            $phases = @(
                foreach ($phase in @($checkpoint.ScenarioPhaseSummaries | Sort-Object PhaseIndex)) {
                    $batches = @($phase.Batches | Sort-Object Batch)
                    [ordered]@{
                        PhaseIndex = [int]$phase.PhaseIndex
                        Phase = [string]$phase.Phase
                        ElapsedSeconds = [math]::Round([double](($batches | Measure-Object ElapsedSeconds -Sum).Sum), 2)
                        Batches = @($batches | ForEach-Object {
                            [ordered]@{ Batch = [int]$_.Batch; ElapsedSeconds = [double]$_.ElapsedSeconds }
                        })
                    }
                }
            )
            [ordered]@{
                ScenarioCommand = if ($checkpoint.PSObject.Properties.Name -contains 'ScenarioCommand') { [string]$checkpoint.ScenarioCommand } else { 'RunAll' }
                CompletedBatches = [int]$checkpoint.Counters.ScenarioBatchesCompleted
                ValidationPassed = [long]$checkpoint.Counters.ValidationsPassed
                ValidationFailed = [long]$checkpoint.Counters.ValidationsFailed
                Phases = $phases
                TotalElapsedSeconds = [math]::Round([double](($phases | Measure-Object ElapsedSeconds -Sum).Sum), 2)
            } | ConvertTo-Json -Depth 8 -Compress
            """;
        string message = await ExecutePowerShellAsync(machineNameOrIp, command, cancellationToken).ConfigureAwait(false);
        return ParseJsonMessage(message);
    }

    private async Task<VerifiedScripts> CopyAndVerifyScriptsAsync(
        string machineNameOrIp,
        CancellationToken cancellationToken)
    {
        Dictionary<string, object?> arguments = new()
        {
            ["sourcePaths"] = new[]
            {
                ScenarioResourceLocator.HarnessPath,
                ScenarioResourceLocator.StatusScriptPath,
            },
            ["targetDirectory"] = remoteOptions.RemoteRoot,
            ["machineNameOrIp"] = machineNameOrIp,
            ["mode"] = "simple",
        };
        _ = await substrateMcpClient.CallToolAsync(
            "tds_copy_files",
            arguments,
            cancellationToken).ConfigureAwait(false);
        return await VerifyRemoteScriptsAsync(machineNameOrIp, cancellationToken).ConfigureAwait(false);
    }

    private async Task<VerifiedScripts> VerifyRemoteScriptsAsync(
        string machineNameOrIp,
        CancellationToken cancellationToken)
    {
        string harnessSha256 = ComputeSha256(ScenarioResourceLocator.HarnessPath);
        string statusScriptSha256 = ComputeSha256(ScenarioResourceLocator.StatusScriptPath);
        string command = $$"""
            $ErrorActionPreference = 'Stop'
            {{GetTrustedPathFunction()}}
            {{GetSha256Function()}}
            Assert-TrustedScenarioPath -Path {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RemoteRoot)}}
            Assert-TrustedScenarioPath -Path {{ScenarioInputValidator.QuotePowerShell(remoteOptions.HarnessPath)}}
            Assert-TrustedScenarioPath -Path {{ScenarioInputValidator.QuotePowerShell(remoteOptions.StatusScriptPath)}}
            $harnessHash = Get-ScenarioSha256 -Path {{ScenarioInputValidator.QuotePowerShell(remoteOptions.HarnessPath)}}
            $statusHash = Get-ScenarioSha256 -Path {{ScenarioInputValidator.QuotePowerShell(remoteOptions.StatusScriptPath)}}
            if (-not [string]::Equals($harnessHash, {{ScenarioInputValidator.QuotePowerShell(harnessSha256)}}, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Copied ScenarioTest harness hash mismatch. Expected {{harnessSha256}} but found $harnessHash."
            }
            if (-not [string]::Equals($statusHash, {{ScenarioInputValidator.QuotePowerShell(statusScriptSha256)}}, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Copied ScenarioTest status-script hash mismatch. Expected {{statusScriptSha256}} but found $statusHash."
            }
            [ordered]@{ HarnessSha256 = $harnessHash; StatusScriptSha256 = $statusHash } | ConvertTo-Json -Compress
            """;
        _ = await ExecutePowerShellAsync(machineNameOrIp, command, cancellationToken).ConfigureAwait(false);
        return new(
            remoteOptions.HarnessPath,
            remoteOptions.StatusScriptPath,
            harnessSha256,
            statusScriptSha256);
    }

    private async Task<string> ExecutePowerShellAsync(
        string machineNameOrIp,
        string command,
        CancellationToken cancellationToken)
    {
        Dictionary<string, object?> arguments = new()
        {
            ["machineNameOrIp"] = machineNameOrIp,
            ["command"] = command,
            ["useExchangeModule"] = false,
            ["timeoutSeconds"] = 60,
        };
        JsonElement response = await substrateMcpClient.CallToolAsync(
            "tds_execute_powershell",
            arguments,
            cancellationToken).ConfigureAwait(false);
        if (!response.TryGetProperty("message", out JsonElement messageElement))
        {
            throw new InvalidOperationException("SubstrateMCP response did not contain a message.");
        }

        return messageElement.GetString()
            ?? throw new InvalidOperationException("SubstrateMCP response message was empty.");
    }

    internal string BuildStartScript(
        ScenarioCommandDefinition definition,
        string organization,
        string objectPrefix,
        string side,
        string objectStoreDestination,
        int randomSeed,
        VerifiedScripts scripts)
    {
        return $$"""
            $ErrorActionPreference = 'Stop'
            {{GetTrustedPathFunction()}}
            {{GetSha256Function()}}
            {{GetNativeArgumentFunction()}}
            {{GetBoundedTailFunction()}}
            $remoteRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RemoteRoot)}}
            $outputRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RunsRoot)}}
            $launchRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.LaunchLogsRoot)}}
            $harnessPath = {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessPath)}}
            $compareSetupScript = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.CompareSetupScript)}}
            $runtimeDependencyRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RuntimeDependencyRoot)}}
            New-Item -Path $outputRoot -ItemType Directory -Force | Out-Null
            New-Item -Path $launchRoot -ItemType Directory -Force | Out-Null
            foreach ($trustedPath in @($remoteRoot, $outputRoot, $launchRoot, $harnessPath, $compareSetupScript, $runtimeDependencyRoot)) {
                Assert-TrustedScenarioPath -Path $trustedPath
            }
            $launchHash = Get-ScenarioSha256 -Path $harnessPath
            if (-not [string]::Equals($launchHash, {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessSha256)}}, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ScenarioTest harness changed after deployment verification; refusing to start it.'
            }
            $mutexName = 'Global\ObjectStoreScenarioTest-Start-' + ({{ScenarioInputValidator.QuotePowerShell(organization)}}.ToUpperInvariant() -replace '[^A-Z0-9_-]', '_')
            $mutex = [Threading.Mutex]::new($false, $mutexName)
            $lockTaken = $false
            try {
                try {
                    $lockTaken = $mutex.WaitOne(0)
                }
                catch [Threading.AbandonedMutexException] {
                    $lockTaken = $true
                }
                if (-not $lockTaken) { throw 'Another ScenarioTest start is already in progress for this organization.' }
                $organizationPattern = '(?i)(?:^|\s)-Organization\s+"?' + [regex]::Escape({{ScenarioInputValidator.QuotePowerShell(organization)}}) + '"?(?:\s|$)'
                $active = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
                    Where-Object {
                        $commandLine = [string]$_.CommandLine
                        [int]$_.ProcessId -ne $PID -and
                        $commandLine.IndexOf('Invoke-DirectoryObjectStoreLongevity.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                        [regex]::IsMatch($commandLine, $organizationPattern)
                    })
                if ($active.Count -gt 0) { throw 'A ScenarioTest process is already active for this organization.' }
                $startedUtc = [datetime]::UtcNow
                $stamp = $startedUtc.ToString('yyyyMMdd-HHmmssfff')
                $launchToken = [guid]::NewGuid().ToString('N')
                $nonce = $launchToken.Substring(0, 8)
                $stdout = Join-Path $launchRoot "$stamp-$nonce.stdout.log"
                $stderr = Join-Path $launchRoot "$stamp-$nonce.stderr.log"
                $arguments = @(
                    '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
                    '-File', $harnessPath,
                    '-LaunchToken', $launchToken,
                    '-WorkloadMode', 'ScenarioTest',
                    '-ScenarioCommand', {{ScenarioInputValidator.QuotePowerShell(definition.Name)}},
                    '-Organization', {{ScenarioInputValidator.QuotePowerShell(organization)}},
                    '-ObjectPrefix', {{ScenarioInputValidator.QuotePowerShell(objectPrefix)}},
                    '-Side', {{ScenarioInputValidator.QuotePowerShell(side)}},
                    '-ObjectStoreDestination', {{ScenarioInputValidator.QuotePowerShell(objectStoreDestination)}},
                    '-RandomSeed', '{{randomSeed}}',
                    '-CompareSetupScript', $compareSetupScript,
                    '-ScenarioRuntimeDependencyRoot', $runtimeDependencyRoot,
                    '-OutputRoot', $outputRoot
                )
                $argumentLine = @($arguments | ForEach-Object { ConvertTo-NativeScenarioArgument -Value ([string]$_) }) -join ' '
                $process = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                    -ArgumentList $argumentLine -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
                $deadline = [datetime]::UtcNow.AddSeconds(20)
                $run = $null
                do {
                    Start-Sleep -Milliseconds 250
                    $run = Get-ChildItem -LiteralPath $outputRoot -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.CreationTimeUtc -ge $startedUtc.AddSeconds(-2) } |
                        Sort-Object CreationTimeUtc -Descending |
                        Where-Object {
                            try {
                                $parametersPath = Join-Path $_.FullName 'parameters.json'
                                if (-not (Test-Path -LiteralPath $parametersPath)) { return $false }
                                $parameters = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
                                return [string]$parameters.ObjectPrefix -ceq {{ScenarioInputValidator.QuotePowerShell(objectPrefix)}} -and
                                    [string]$parameters.Organization -ieq {{ScenarioInputValidator.QuotePowerShell(organization)}} -and
                                    [string]$parameters.ScenarioCommand -ieq {{ScenarioInputValidator.QuotePowerShell(definition.Name)}} -and
                                    [int]$parameters.RandomSeed -eq {{randomSeed}}
                            }
                            catch {
                                return $false
                            }
                        } |
                        Select-Object -First 1
                } while ($null -eq $run -and [datetime]::UtcNow -lt $deadline)
                if ($null -eq $run) {
                    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                    if ($null -ne $live -and
                        [math]::Abs(($live.StartTime.ToUniversalTime() - $startedUtc).TotalSeconds) -lt 5) {
                        Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue
                    }
                    $errorTail = Get-BoundedFileTail -Path $stderr
                    throw "Scenario process $($process.Id) did not publish a matching run directory. $errorTail"
                }
                $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                if ($null -eq $live) {
                    $errorTail = Get-BoundedFileTail -Path $stderr
                    throw "Scenario process exited during startup. $errorTail"
                }
                $metadata = [ordered]@{
                    ProcessId = $live.Id
                    ProcessStartUtc = $live.StartTime.ToUniversalTime().ToString('o')
                    StandardOutputPath = $stdout
                    StandardErrorPath = $stderr
                    ScriptSha256 = {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessSha256)}}
                    LaunchToken = $launchToken
                }
                $metadataPath = Join-Path $run.FullName "mcp-launch-$stamp-$nonce.json"
                $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
                [ordered]@{
                    RunId = $run.Name
                    RunDirectory = $run.FullName
                    ProcessId = $live.Id
                    ProcessStartUtc = $live.StartTime.ToUniversalTime().ToString('o')
                    StandardOutputPath = $stdout
                    StandardErrorPath = $stderr
                    ScriptSha256 = {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessSha256)}}
                    LaunchToken = $launchToken
                } | ConvertTo-Json -Compress
            }
            finally {
                if ($lockTaken) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
            """;
    }

    internal string BuildResumeScript(string runDirectory, VerifiedScripts scripts)
    {
        return $$"""
            $ErrorActionPreference = 'Stop'
            {{GetTrustedPathFunction()}}
            {{GetSha256Function()}}
            {{GetNativeArgumentFunction()}}
            {{GetBoundedTailFunction()}}
            $runDirectory = {{ScenarioInputValidator.QuotePowerShell(runDirectory)}}
            $launchRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.LaunchLogsRoot)}}
            $harnessPath = {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessPath)}}
            foreach ($trustedPath in @({{ScenarioInputValidator.QuotePowerShell(remoteOptions.RemoteRoot)}}, {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RunsRoot)}}, $runDirectory, $launchRoot, $harnessPath)) {
                Assert-TrustedScenarioPath -Path $trustedPath
            }
            $parametersPath = Join-Path $runDirectory 'parameters.json'
            $checkpointPath = Join-Path $runDirectory 'checkpoint.json'
            $paused = Join-Path $runDirectory 'PAUSED'
            if (-not (Test-Path -LiteralPath $parametersPath)) { throw 'parameters.json was not found.' }
            if (-not (Test-Path -LiteralPath $checkpointPath)) { throw 'checkpoint.json was not found.' }
            if (-not (Test-Path -LiteralPath $paused)) { throw 'The run is not paused; refusing to start a duplicate resume process.' }
            foreach ($artifactPath in @($parametersPath, $checkpointPath, $paused)) {
                Assert-TrustedScenarioPath -Path $artifactPath
            }
            if ((Get-Item -LiteralPath $parametersPath).Length -gt 4194304) { throw 'parameters.json exceeds the 4-MB safety limit.' }
            if ((Get-Item -LiteralPath $checkpointPath).Length -gt 134217728) { throw 'checkpoint.json exceeds the 128-MB safety limit.' }
            $parameters = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
            $parameterNames = @($parameters.PSObject.Properties.Name)
            $command = if ($parameterNames -contains 'ScenarioCommand' -and -not [string]::IsNullOrWhiteSpace([string]$parameters.ScenarioCommand)) { [string]$parameters.ScenarioCommand } else { 'RunAll' }
            $workload = if ($parameterNames -contains 'WorkloadMode' -and -not [string]::IsNullOrWhiteSpace([string]$parameters.WorkloadMode)) { [string]$parameters.WorkloadMode } else { 'ScenarioTest' }
            if ($workload -ine 'ScenarioTest') { throw "Run workload '$workload' is not ScenarioTest." }
            $organization = [string]$parameters.Organization
            $objectPrefix = [string]$parameters.ObjectPrefix
            if ([string]::IsNullOrWhiteSpace($organization) -or [string]::IsNullOrWhiteSpace($objectPrefix)) {
                throw 'The saved organization or object prefix is missing.'
            }
            $side = if ($parameterNames -contains 'Side' -and -not [string]::IsNullOrWhiteSpace([string]$parameters.Side)) { [string]$parameters.Side } else { 'A' }
            $destination = if ($parameterNames -contains 'ObjectStoreDestination' -and -not [string]::IsNullOrWhiteSpace([string]$parameters.ObjectStoreDestination)) { [string]$parameters.ObjectStoreDestination } else { 'Test' }
            $randomSeed = if ($parameterNames -contains 'RandomSeed' -and $null -ne $parameters.RandomSeed) { [int]$parameters.RandomSeed } else { 1729 }
            $compareSetupScript = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.CompareSetupScript)}}
            if ($parameterNames -contains 'CompareSetupScript' -and
                -not [string]::IsNullOrWhiteSpace([string]$parameters.CompareSetupScript) -and
                -not [string]::Equals([string]$parameters.CompareSetupScript, $compareSetupScript, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The saved comparison setup path does not match the administrator-configured trusted path.'
            }
            $runtimeDependencyRoot = {{ScenarioInputValidator.QuotePowerShell(remoteOptions.RuntimeDependencyRoot)}}
            if ($parameterNames -contains 'ScenarioRuntimeDependencyRoot' -and
                -not [string]::IsNullOrWhiteSpace([string]$parameters.ScenarioRuntimeDependencyRoot) -and
                -not [string]::Equals([string]$parameters.ScenarioRuntimeDependencyRoot, $runtimeDependencyRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The saved runtime dependency path does not match the administrator-configured trusted path.'
            }
            foreach ($trustedPath in @($compareSetupScript, $runtimeDependencyRoot)) {
                Assert-TrustedScenarioPath -Path $trustedPath
            }
            $launchHash = Get-ScenarioSha256 -Path $harnessPath
            if (-not [string]::Equals($launchHash, {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessSha256)}}, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ScenarioTest harness changed after deployment verification; refusing to resume it.'
            }
            $runId = Split-Path -Leaf $runDirectory
            $mutexName = 'Global\ObjectStoreScenarioTest-Start-' + ($organization.ToUpperInvariant() -replace '[^A-Z0-9_-]', '_')
            $mutex = [Threading.Mutex]::new($false, $mutexName)
            $lockTaken = $false
            $pausedBackup = $null
            $readyPath = $null
            $process = $null
            try {
                try {
                    $lockTaken = $mutex.WaitOne(0)
                }
                catch [Threading.AbandonedMutexException] {
                    $lockTaken = $true
                }
                if (-not $lockTaken) { throw 'Another ScenarioTest start or resume is already in progress for this organization.' }
                $organizationPattern = '(?i)(?:^|\s)-Organization\s+"?' + [regex]::Escape($organization) + '"?(?:\s|$)'
                $active = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
                    Where-Object {
                        $commandLine = [string]$_.CommandLine
                        [int]$_.ProcessId -ne $PID -and
                        $commandLine.IndexOf('Invoke-DirectoryObjectStoreLongevity.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                        [regex]::IsMatch($commandLine, $organizationPattern)
                    })
                if ($active.Count -gt 0) { throw 'A ScenarioTest process is already active for this organization.' }
                $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmssfff')
                $launchToken = [guid]::NewGuid().ToString('N')
                $nonce = $launchToken.Substring(0, 8)
                New-Item -Path $launchRoot -ItemType Directory -Force | Out-Null
                $stdout = Join-Path $launchRoot "$stamp-$nonce-resume.stdout.log"
                $stderr = Join-Path $launchRoot "$stamp-$nonce-resume.stderr.log"
                $readyPath = Join-Path $runDirectory "mcp-ready-$launchToken.json"
                $pausedBackup = Join-Path $runDirectory "PAUSED.before-$stamp-$nonce"
                Move-Item -LiteralPath $paused -Destination $pausedBackup
                $arguments = @(
                    '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass',
                    '-File', $harnessPath,
                    '-LaunchToken', $launchToken,
                    '-WorkloadMode', 'ScenarioTest',
                    '-ScenarioCommand', $command,
                    '-Organization', $organization,
                    '-ObjectPrefix', $objectPrefix,
                    '-Side', $side,
                    '-ObjectStoreDestination', $destination,
                    '-RandomSeed', [string]$randomSeed,
                    '-CompareSetupScript', $compareSetupScript,
                    '-ScenarioRuntimeDependencyRoot', $runtimeDependencyRoot,
                    '-ResumeRunDirectory', $runDirectory,
                    '-McpReadyPath', $readyPath
                )
                if ($parameterNames -contains 'WhatIfTraffic' -and [bool]$parameters.WhatIfTraffic) { $arguments += '-WhatIfTraffic' }
                $argumentLine = @($arguments | ForEach-Object { ConvertTo-NativeScenarioArgument -Value ([string]$_) }) -join ' '
                $process = Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                    -ArgumentList $argumentLine -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
                $deadline = [datetime]::UtcNow.AddSeconds(30)
                $ready = $false
                do {
                    Start-Sleep -Milliseconds 250
                    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                    if ($null -eq $live) {
                        $errorTail = Get-BoundedFileTail -Path $stderr
                        throw "Scenario process exited before adopting the checkpoint. $errorTail"
                    }
                    if (Test-Path -LiteralPath $readyPath) {
                        try {
                            Assert-TrustedScenarioPath -Path $readyPath
                            if ((Get-Item -LiteralPath $readyPath).Length -gt 1048576) { throw 'MCP readiness file exceeds the 1-MB safety limit.' }
                            $readyState = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                            $ready = [int]$readyState.ProcessId -eq $live.Id -and
                                [string]$readyState.LaunchToken -ceq $launchToken -and
                                [string]$readyState.RunDirectory -ieq $runDirectory
                        }
                        catch {
                            $ready = $false
                        }
                    }
                } while (-not $ready -and [datetime]::UtcNow -lt $deadline)
                if (-not $ready) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    $errorTail = Get-BoundedFileTail -Path $stderr
                    throw "Scenario process did not adopt the checkpoint within 30 seconds. $errorTail"
                }
                Remove-Item -LiteralPath $readyPath -Force
                $metadata = [ordered]@{
                    ProcessId = $live.Id
                    ProcessStartUtc = $live.StartTime.ToUniversalTime().ToString('o')
                    StandardOutputPath = $stdout
                    StandardErrorPath = $stderr
                    ScriptSha256 = {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessSha256)}}
                    LaunchToken = $launchToken
                }
                $metadataPath = Join-Path $runDirectory "mcp-resume-$stamp-$nonce.json"
                $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
                [ordered]@{
                    Command = $command
                    Organization = $organization
                    ObjectPrefix = $objectPrefix
                    RunId = $runId
                    ProcessId = $live.Id
                    ProcessStartUtc = $live.StartTime.ToUniversalTime().ToString('o')
                    StandardOutputPath = $stdout
                    StandardErrorPath = $stderr
                    ScriptSha256 = {{ScenarioInputValidator.QuotePowerShell(scripts.HarnessSha256)}}
                    LaunchToken = $launchToken
                } | ConvertTo-Json -Compress
            }
            catch {
                if ($null -ne $process) {
                    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
                    if ($null -ne $live) {
                        $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" -ErrorAction SilentlyContinue
                        $commandLine = [string]$processInfo.CommandLine
                        if ($commandLine.IndexOf($launchToken, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            [void]$process.WaitForExit(5000)
                        }
                    }
                }
                if ($null -ne $readyPath -and (Test-Path -LiteralPath $readyPath)) {
                    Remove-Item -LiteralPath $readyPath -Force -ErrorAction SilentlyContinue
                }
                if ($null -ne $pausedBackup -and
                    (Test-Path -LiteralPath $pausedBackup) -and
                    -not (Test-Path -LiteralPath $paused)) {
                    Move-Item -LiteralPath $pausedBackup -Destination $paused
                }
                throw
            }
            finally {
                if ($lockTaken) { $mutex.ReleaseMutex() }
                $mutex.Dispose()
            }
            """;
    }

    private static string ComputeSha256(string path)
    {
        using FileStream stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream));
    }

    private static string GetTrustedPathFunction()
    {
        return """
            function Assert-TrustedScenarioPath {
                param([Parameter(Mandatory)][string] $Path)
                if (-not (Test-Path -LiteralPath $Path)) {
                    throw "Required trusted path was not found: $Path"
                }
                $currentPath = [IO.Path]::GetFullPath($Path)
                while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
                    $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw "Trusted ScenarioTest path traverses a reparse point: $currentPath"
                    }
                    $parentPath = Split-Path -Parent $currentPath
                    if ([string]::IsNullOrWhiteSpace($parentPath) -or
                        [string]::Equals($parentPath, $currentPath, [StringComparison]::OrdinalIgnoreCase)) {
                        break
                    }
                    $currentPath = $parentPath
                }
            }
            """;
    }

    private static string GetBoundedTailFunction()
    {
        return """
            function Get-BoundedFileTail {
                param([string] $Path, [int] $MaximumBytes = 262144, [int] $MaximumLines = 20)
                if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
                    return ''
                }
                $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                try {
                    $length = $stream.Length
                    $start = [math]::Max(0, $length - $MaximumBytes)
                    [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
                    $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
                    try {
                        $text = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
                finally {
                    $stream.Dispose()
                }
                if ($start -gt 0) {
                    $newline = $text.IndexOf("`n")
                    $text = if ($newline -ge 0) { $text.Substring($newline + 1) } else { '' }
                }
                return (@($text -split "`r?`n" | Select-Object -Last $MaximumLines) -join [Environment]::NewLine)
            }
            """;
    }

    private static string GetSha256Function()
    {
        return """
            function Get-ScenarioSha256 {
                param([Parameter(Mandatory)][string] $Path)
                $stream = [IO.File]::OpenRead($Path)
                try {
                    $algorithm = [Security.Cryptography.SHA256]::Create()
                    try {
                        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
                    }
                    finally {
                        $algorithm.Dispose()
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
            """;
    }

    private static string GetNativeArgumentFunction()
    {
        return """
            function ConvertTo-NativeScenarioArgument {
                param([Parameter(Mandatory)][AllowEmptyString()][string] $Value)
                if ($Value.IndexOf('"') -ge 0) {
                    throw 'Native process arguments cannot contain double quotes.'
                }
                if ($Value.Length -eq 0) {
                    return '""'
                }
                if ($Value -notmatch '\s') {
                    return $Value
                }
                return '"' + $Value + '"'
            }
            """;
    }

    private static T DeserializeMessage<T>(string message)
    {
        return JsonSerializer.Deserialize<T>(
            message,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("Remote command returned an empty result.");
    }

    private static JsonElement ParseJsonMessage(string message)
    {
        using JsonDocument document = JsonDocument.Parse(message);
        return document.RootElement.Clone();
    }

    internal sealed record VerifiedScripts(
        string HarnessPath,
        string StatusScriptPath,
        string HarnessSha256,
        string StatusScriptSha256);

    private sealed record RemoteStartResult(
        string RunId,
        string RunDirectory,
        int ProcessId,
        DateTimeOffset ProcessStartUtc,
        string StandardOutputPath,
        string StandardErrorPath,
        string ScriptSha256,
        string LaunchToken);

    private sealed record RemoteResumeResult(
        string Command,
        string Organization,
        string ObjectPrefix,
        string RunId,
        int ProcessId,
        DateTimeOffset ProcessStartUtc,
        string StandardOutputPath,
        string StandardErrorPath,
        string ScriptSha256,
        string LaunchToken);

    private sealed record RemoteStopResult(bool Stopped, string Message);
}
