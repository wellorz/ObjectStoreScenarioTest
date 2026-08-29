using System.Text.Json;
using System.Security.Cryptography;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using ObjectStoreScenarioTest.Mcp.Services;

string repositoryRoot = FindRepositoryRoot(AppContext.BaseDirectory);
string serverProject = Path.Combine(
    repositoryRoot,
    "src",
    "ObjectStoreScenarioTest.Mcp",
    "ObjectStoreScenarioTest.Mcp.csproj");
bool usePackedServer = args.Contains("--package", StringComparer.Ordinal);
string packageDirectory = Path.Combine(
    repositoryRoot,
    "src",
    "ObjectStoreScenarioTest.Mcp",
    "bin",
    "Release");

StdioClientTransport transport = new(new StdioClientTransportOptions
{
    Name = "ObjectStoreScenarioTest.Mcp integration test",
    Command = usePackedServer ? "dnx" : "dotnet",
    Arguments = usePackedServer
        ?
        [
            "Wellorz.ObjectStoreScenarioTest.Mcp@0.1.0-beta",
            "--source",
            packageDirectory,
        ]
        :
        [
            "run",
            "--project",
            serverProject,
            "--configuration",
            "Release",
            "--no-build",
        ],
});

await using McpClient client = await McpClient.CreateAsync(transport);
IList<McpClientTool> tools = await client.ListToolsAsync();
string[] expectedTools =
[
    "get_command_catalog",
    "user_upsert",
    "group_upsert",
    "user_properties_deletion",
    "group_properties_deletion",
    "run_all",
    "get_run_status",
    "resume_run",
    "stop_run",
    "get_timing_report",
];

string[] actualTools = tools.Select(tool => tool.Name).Order().ToArray();
string[] missingTools = expectedTools.Except(actualTools, StringComparer.Ordinal).ToArray();
if (missingTools.Length > 0)
{
    throw new InvalidOperationException($"Missing MCP tools: {string.Join(", ", missingTools)}");
}

McpClientTool startTool = tools.Single(tool => tool.Name == "user_upsert");
string startSchema = startTool.JsonSchema.GetRawText();
foreach (string forbiddenParameter in new[] { "remoteRoot", "compareSetupScript", "runtimeDependencyRoot" })
{
    if (startSchema.Contains(forbiddenParameter, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"Public start schema exposes executable path '{forbiddenParameter}'.");
    }
}

McpClientTool statusTool = tools.Single(tool => tool.Name == "get_run_status");
if (statusTool.JsonSchema.GetRawText().Contains("standardErrorPath", StringComparison.Ordinal))
{
    throw new InvalidOperationException("Public status schema exposes an arbitrary standard-error path.");
}

CallToolResult catalogResult = await client.CallToolAsync("get_command_catalog");
if (catalogResult.IsError == true)
{
    throw new InvalidOperationException("get_command_catalog returned an MCP error.");
}

string catalogText = string.Join(
    Environment.NewLine,
    catalogResult.Content.OfType<TextContentBlock>().Select(content => content.Text));
if (!catalogText.Contains("User-Upsert", StringComparison.Ordinal) ||
    !catalogText.Contains("Group-Properties-Deletion", StringComparison.Ordinal) ||
    !catalogText.Contains("RunAll", StringComparison.Ordinal))
{
    throw new InvalidOperationException($"Command catalog was incomplete: {catalogText}");
}

using JsonDocument catalogDocument = JsonDocument.Parse(catalogText);
if (catalogDocument.RootElement.GetArrayLength() != 5)
{
    throw new InvalidOperationException("Command catalog must contain exactly five commands.");
}

string remoteRoot = ScenarioInputValidator.NormalizeTrustedWindowsPath(
    @"C:\tds\ObjectStoreScenarioTest",
    "remoteRoot");
string runDirectory = ScenarioInputValidator.NormalizeRunDirectory(
    @"C:\tds\ObjectStoreScenarioTest\Runs\test-run",
    remoteRoot);
if (ScenarioInputValidator.NormalizeObjectStoreDestination("canaryint") != "CanaryInt")
{
    throw new InvalidOperationException("Object Store destination normalization is not case-insensitive.");
}
ExpectArgumentException(
    () => ScenarioInputValidator.NormalizeRunDirectory(
        @"C:\tds\ObjectStoreScenarioTest\Runs\..\outside",
        remoteRoot));
ExpectArgumentException(
    () => ScenarioInputValidator.NormalizeRunDirectory(
        @"C:\other\Runs\test-run",
        remoteRoot));
ExpectArgumentException(
    () => ScenarioInputValidator.NormalizeTrustedWindowsPath(
        @"\\server\share\test",
        "path"));
ExpectArgumentException(
    () => ScenarioInputValidator.NormalizeTrustedWindowsPath(
        @"C:\tds\file.txt:stream",
        "path"));

ScenarioRemoteOptions remoteOptions = new(
    remoteRoot,
    @"C:\tds\CompareAndRepairSetup.ps1",
    @"C:\tds\RuntimeDependencies\net472");
AssertFilesEqual(
    Path.Combine(repositoryRoot, "Invoke-DirectoryObjectStoreLongevity.ps1"),
    ScenarioResourceLocator.HarnessPath);
AssertFilesEqual(
    Path.Combine(repositoryRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1"),
    ScenarioResourceLocator.StatusScriptPath);
ScenarioService service = new(null!, remoteOptions);
ScenarioService.VerifiedScripts scripts = new(
    remoteOptions.HarnessPath,
    remoteOptions.StatusScriptPath,
    new string('A', 64),
    new string('B', 64));
string startPowerShell = service.BuildStartScript(
    ScenarioCatalog.Get("User-Upsert"),
    "contoso.com",
    "DOSUserUpsert",
    "A",
    "Test",
    1729,
    scripts);
string resumePowerShell = service.BuildResumeScript(runDirectory, scripts);
foreach (string requiredSafeguard in new[]
{
    "ObjectStoreScenarioTest-Start-",
    "Get-ScenarioSha256",
    "mcp-launch-",
    "Stop-Process",
    "'-LaunchToken', $launchToken",
    ".ToUpperInvariant() -replace '[^A-Z0-9_-]'",
})
{
    if (!startPowerShell.Contains(requiredSafeguard, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"Start script is missing safeguard '{requiredSafeguard}'.");
    }
    if (!resumePowerShell.Contains(
            "saved comparison setup path does not match the administrator-configured trusted path",
            StringComparison.Ordinal) ||
        !resumePowerShell.Contains(
            "saved runtime dependency path does not match the administrator-configured trusted path",
            StringComparison.Ordinal))
    {
        throw new InvalidOperationException("Resume script does not pin executable paths to administrator configuration.");
    }

    AssertFilesEqual(
        Path.Combine(repositoryRoot, "Invoke-DirectoryObjectStoreLongevity.ps1"),
        Path.Combine(repositoryRoot, ".github", "skills", "scenario-test-runner", "Invoke-DirectoryObjectStoreLongevity.ps1"));
    AssertFilesEqual(
        Path.Combine(repositoryRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1"),
        Path.Combine(repositoryRoot, ".github", "skills", "scenario-test-runner", "Get-DirectoryObjectStoreScenarioStatus.ps1"));
    AssertFilesEqual(
        Path.Combine(repositoryRoot, "README.md"),
        Path.Combine(repositoryRoot, ".github", "skills", "scenario-test-runner", "README.md"));
    AssertFilesEqual(
        Path.Combine(repositoryRoot, "SKILL.md"),
        Path.Combine(repositoryRoot, ".github", "skills", "scenario-test-runner", "SKILL.md"));
}
foreach (string requiredSafeguard in new[]
{
    "ObjectStoreScenarioTest-Start-",
    "A ScenarioTest process is already active for this organization.",
    "Move-Item -LiteralPath $pausedBackup -Destination $paused",
    "mcp-resume-",
    "'-McpReadyPath', $readyPath",
    "did not adopt the checkpoint within 30 seconds",
})
{
    if (!resumePowerShell.Contains(requiredSafeguard, StringComparison.Ordinal))
    {
        throw new InvalidOperationException($"Resume script is missing safeguard '{requiredSafeguard}'.");
    }
}

string temporaryDirectory = Path.Combine(Path.GetTempPath(), $"ObjectStoreScenarioTest-Mcp-{Guid.NewGuid():N}");
Directory.CreateDirectory(temporaryDirectory);
try
{
    string startScriptPath = Path.Combine(temporaryDirectory, "start.ps1");
    string resumeScriptPath = Path.Combine(temporaryDirectory, "resume.ps1");
    await File.WriteAllTextAsync(startScriptPath, startPowerShell);
    await File.WriteAllTextAsync(resumeScriptPath, resumePowerShell);
    ParsePowerShell(
        startScriptPath,
        resumeScriptPath,
        Path.Combine(repositoryRoot, "Invoke-DirectoryObjectStoreLongevity.ps1"),
        Path.Combine(repositoryRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1"));

    string runsRoot = Path.Combine(temporaryDirectory, "Runs");
    string localRunDirectory = Path.Combine(runsRoot, "identity-test");
    string launchRoot = Path.Combine(temporaryDirectory, "LaunchLogs");
    Directory.CreateDirectory(localRunDirectory);
    Directory.CreateDirectory(launchRoot);
    await File.WriteAllTextAsync(
        Path.Combine(localRunDirectory, "status.json"),
        JsonSerializer.Serialize(new { UpdatedUtc = DateTimeOffset.UtcNow }));
    string fakeHarnessPath = Path.Combine(temporaryDirectory, "Invoke-DirectoryObjectStoreLongevity.ps1");
    await File.WriteAllTextAsync(
        fakeHarnessPath,
        "param([string]$LaunchToken)\nStart-Sleep -Seconds 60\n");
    string launchToken = Guid.NewGuid().ToString("N");
    using System.Diagnostics.Process fakeHarness = new();
    fakeHarness.StartInfo = new()
    {
        FileName = "powershell.exe",
        UseShellExecute = false,
        CreateNoWindow = true,
    };
    fakeHarness.StartInfo.ArgumentList.Add("-NoProfile");
    fakeHarness.StartInfo.ArgumentList.Add("-NonInteractive");
    fakeHarness.StartInfo.ArgumentList.Add("-File");
    fakeHarness.StartInfo.ArgumentList.Add(fakeHarnessPath);
    fakeHarness.StartInfo.ArgumentList.Add("-LaunchToken");
    fakeHarness.StartInfo.ArgumentList.Add(launchToken);
    fakeHarness.Start();
    try
    {
        DateTimeOffset fakeHarnessStartUtc = fakeHarness.StartTime.ToUniversalTime();
        string statusOutput = ExecutePowerShell(
            $"& '{Path.Combine(repositoryRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1").Replace("'", "''")}' " +
            $"-RunDirectory '{localRunDirectory.Replace("'", "''")}' " +
            $"-AllowedRunsRoot '{runsRoot.Replace("'", "''")}' " +
            $"-AllowedLaunchRoot '{launchRoot.Replace("'", "''")}' " +
            $"-ProcessId {fakeHarness.Id} " +
            $"-ResumeStartedUtc '{fakeHarnessStartUtc:O}' " +
            $"-LaunchToken '{launchToken}'");
        using JsonDocument statusDocument = JsonDocument.Parse(statusOutput);
        if (!statusDocument.RootElement.GetProperty("ProcessRunning").GetBoolean() ||
            !statusDocument.RootElement.GetProperty("ProcessIdentityValid").GetBoolean())
        {
            throw new InvalidOperationException("Live status did not recognize the launch-token process identity.");
        }

        string stopOutput = ExecutePowerShell(
            ScenarioService.BuildStopScript(
                localRunDirectory,
                fakeHarness.Id,
                fakeHarnessStartUtc,
                launchToken));
        using JsonDocument stopDocument = JsonDocument.Parse(stopOutput);
        if (!stopDocument.RootElement.GetProperty("Stopped").GetBoolean())
        {
            throw new InvalidOperationException("Exact launch-token stop safeguard did not stop the test process.");
        }
        fakeHarness.WaitForExit(5000);
    }
    finally
    {
        if (!fakeHarness.HasExited)
        {
            fakeHarness.Kill(entireProcessTree: true);
            fakeHarness.WaitForExit();
        }
    }

    string resumeRemoteRoot = Path.Combine(temporaryDirectory, "Resume Remote");
    string resumeRunsRoot = Path.Combine(resumeRemoteRoot, "Runs");
    string resumeLaunchRoot = Path.Combine(resumeRemoteRoot, "LaunchLogs");
    string resumeCompareSetup = Path.Combine(resumeRemoteRoot, "CompareAndRepairSetup.ps1");
    string resumeRuntimeRoot = Path.Combine(resumeRemoteRoot, "RuntimeDependencies", "net472");
    string resumeHarnessPath = Path.Combine(resumeRemoteRoot, "Invoke-DirectoryObjectStoreLongevity.ps1");
    Directory.CreateDirectory(resumeRunsRoot);
    Directory.CreateDirectory(resumeLaunchRoot);
    Directory.CreateDirectory(resumeRuntimeRoot);
    await File.WriteAllTextAsync(resumeCompareSetup, string.Empty);
    string successfulFakeHarness = """
        param(
            [string]$LaunchToken,
            [string]$WorkloadMode,
            [string]$ScenarioCommand,
            [string]$Organization,
            [string]$ObjectPrefix,
            [string]$Side,
            [string]$ObjectStoreDestination,
            [string]$RandomSeed,
            [string]$CompareSetupScript,
            [string]$ScenarioRuntimeDependencyRoot,
            [string]$ResumeRunDirectory,
            [string]$McpReadyPath,
            [switch]$WhatIfTraffic
        )
        [ordered]@{
            ProcessId = $PID
            LaunchToken = $LaunchToken
            RunDirectory = $ResumeRunDirectory
            ReadyUtc = [datetime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $McpReadyPath -Encoding UTF8
        Start-Sleep -Seconds 60
        """;
    await File.WriteAllTextAsync(resumeHarnessPath, successfulFakeHarness);
    ScenarioRemoteOptions resumeOptions = new(
        resumeRemoteRoot,
        resumeCompareSetup,
        resumeRuntimeRoot);
    ScenarioService resumeService = new(null!, resumeOptions);

    string successfulRunDirectory = Path.Combine(resumeRunsRoot, "successful-resume");
    CreateResumeArtifacts(
        successfulRunDirectory,
        resumeCompareSetup,
        resumeRuntimeRoot);
    ScenarioService.VerifiedScripts successfulScripts = new(
        resumeHarnessPath,
        Path.Combine(resumeRemoteRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1"),
        ComputeSha256(resumeHarnessPath),
        new string('B', 64));
    string resumeOutput = ExecutePowerShell(
        resumeService.BuildResumeScript(successfulRunDirectory, successfulScripts));
    using JsonDocument resumeDocument = JsonDocument.Parse(resumeOutput);
    int resumedProcessId = resumeDocument.RootElement.GetProperty("ProcessId").GetInt32();
    DateTimeOffset resumedStartUtc = resumeDocument.RootElement.GetProperty("ProcessStartUtc").GetDateTimeOffset();
    string resumedLaunchToken = resumeDocument.RootElement.GetProperty("LaunchToken").GetString()!;
    if (File.Exists(Path.Combine(successfulRunDirectory, "PAUSED")) ||
        !Directory.EnumerateFiles(successfulRunDirectory, "PAUSED.before-*").Any() ||
        Directory.EnumerateFiles(successfulRunDirectory, "mcp-ready-*").Any())
    {
        throw new InvalidOperationException("Successful resume did not complete the PAUSED/readiness transition.");
    }
    _ = ExecutePowerShell(
        ScenarioService.BuildStopScript(
            successfulRunDirectory,
            resumedProcessId,
            resumedStartUtc,
            resumedLaunchToken));

    await File.WriteAllTextAsync(
        resumeHarnessPath,
        "param([Parameter(ValueFromRemainingArguments=$true)]$Remaining)\nexit 7\n");
    string failedRunDirectory = Path.Combine(resumeRunsRoot, "failed-resume");
    CreateResumeArtifacts(
        failedRunDirectory,
        resumeCompareSetup,
        resumeRuntimeRoot);
    ScenarioService.VerifiedScripts failedScripts = new(
        resumeHarnessPath,
        Path.Combine(resumeRemoteRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1"),
        ComputeSha256(resumeHarnessPath),
        new string('B', 64));
    ExpectPowerShellFailure(
        resumeService.BuildResumeScript(failedRunDirectory, failedScripts));
    if (!File.Exists(Path.Combine(failedRunDirectory, "PAUSED")))
    {
        throw new InvalidOperationException("Failed pre-readiness resume did not restore PAUSED.");
    }
}
finally
{
    Directory.Delete(temporaryDirectory, recursive: true);
}

Console.WriteLine(
    $"PASS: {(usePackedServer ? "package" : "source")} server, {actualTools.Length} MCP tools, " +
    "5 commands, schemas, validation, and PowerShell syntax.");

static string FindRepositoryRoot(string startDirectory)
{
    DirectoryInfo? directory = new(startDirectory);
    while (directory is not null)
    {
        if (File.Exists(Path.Combine(directory.FullName, "Invoke-DirectoryObjectStoreLongevity.ps1")) &&
            Directory.Exists(Path.Combine(directory.FullName, "src", "ObjectStoreScenarioTest.Mcp")))
        {
            return directory.FullName;
        }

        directory = directory.Parent;
    }

    throw new DirectoryNotFoundException("Could not locate the ObjectStoreScenarioTest repository root.");
}

static void ExpectArgumentException(Action action)
{
    try
    {
        action();
    }
    catch (ArgumentException)
    {
        return;
    }

    throw new InvalidOperationException("Expected path validation to reject unsafe input.");
}

static void ParsePowerShell(params string[] paths)
{
    foreach (string path in paths)
    {
        using System.Diagnostics.Process process = new();
        process.StartInfo = new()
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        process.StartInfo.ArgumentList.Add("-NoProfile");
        process.StartInfo.ArgumentList.Add("-NonInteractive");
        process.StartInfo.ArgumentList.Add("-Command");
        process.StartInfo.ArgumentList.Add(
            "$tokens=$null;$errors=$null;" +
            "[Management.Automation.Language.Parser]::ParseFile($env:SCENARIO_SCRIPT_TO_PARSE,[ref]$tokens,[ref]$errors)|Out-Null;" +
            "if($errors.Count -gt 0){$errors|ForEach-Object{$_.Message};exit 1}");
        process.StartInfo.Environment["SCENARIO_SCRIPT_TO_PARSE"] = path;
        process.Start();
        string standardOutput = process.StandardOutput.ReadToEnd();
        string standardError = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"PowerShell syntax validation failed for {path}:{Environment.NewLine}{standardOutput}{standardError}");
        }
    }

}

static void AssertFilesEqual(string expectedPath, string actualPath)
{
    byte[] expected = File.ReadAllBytes(expectedPath);
    byte[] actual = File.ReadAllBytes(actualPath);
    if (!expected.AsSpan().SequenceEqual(actual))
    {
        throw new InvalidOperationException($"Self-contained skill copy is out of sync: {actualPath}");
    }
}

static string ExecutePowerShell(string command)
{
    using System.Diagnostics.Process process = new();
    process.StartInfo = new()
    {
        FileName = "powershell.exe",
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true,
    };
    process.StartInfo.ArgumentList.Add("-NoProfile");
    process.StartInfo.ArgumentList.Add("-NonInteractive");
    process.StartInfo.ArgumentList.Add("-Command");
    process.StartInfo.ArgumentList.Add(command);
    process.Start();
    string standardOutput = process.StandardOutput.ReadToEnd();
    string standardError = process.StandardError.ReadToEnd();
    process.WaitForExit();
    if (process.ExitCode != 0)
    {
        throw new InvalidOperationException(
            $"PowerShell command failed:{Environment.NewLine}{standardOutput}{standardError}");
    }

    return standardOutput.Trim();
}

static void ExpectPowerShellFailure(string command)
{
    try
    {
        _ = ExecutePowerShell(command);
    }
    catch (InvalidOperationException)
    {
        return;
    }

    throw new InvalidOperationException("Expected PowerShell command to fail.");
}

static void CreateResumeArtifacts(
    string runDirectory,
    string compareSetupScript,
    string runtimeDependencyRoot)
{
    Directory.CreateDirectory(runDirectory);
    File.WriteAllText(
        Path.Combine(runDirectory, "parameters.json"),
        JsonSerializer.Serialize(new
        {
            WorkloadMode = "ScenarioTest",
            ScenarioCommand = "User-Upsert",
            Organization = "contoso.com",
            ObjectPrefix = "DOSResumeTest",
            Side = "A",
            ObjectStoreDestination = "Test",
            RandomSeed = 1729,
            CompareSetupScript = compareSetupScript,
            ScenarioRuntimeDependencyRoot = runtimeDependencyRoot,
            WhatIfTraffic = false,
        }));
    File.WriteAllText(Path.Combine(runDirectory, "checkpoint.json"), "{}");
    File.WriteAllText(Path.Combine(runDirectory, "PAUSED"), "paused");
}

static string ComputeSha256(string path)
{
    return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path)));
}
