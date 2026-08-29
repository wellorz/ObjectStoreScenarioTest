namespace ObjectStoreScenarioTest.Mcp.Services;

internal sealed record ScenarioRemoteOptions(
    string RemoteRoot,
    string CompareSetupScript,
    string RuntimeDependencyRoot)
{
    private const string RemoteRootVariable = "OBJECTSTORE_SCENARIO_REMOTE_ROOT";
    private const string CompareSetupScriptVariable = "OBJECTSTORE_SCENARIO_COMPARE_SETUP_SCRIPT";
    private const string RuntimeDependencyRootVariable = "OBJECTSTORE_SCENARIO_RUNTIME_DEPENDENCY_ROOT";

    public string RunsRoot => Path.Combine(RemoteRoot, "Runs");

    public string LaunchLogsRoot => Path.Combine(RemoteRoot, "LaunchLogs");

    public string HarnessPath => Path.Combine(RemoteRoot, "Invoke-DirectoryObjectStoreLongevity.ps1");

    public string StatusScriptPath => Path.Combine(RemoteRoot, "Get-DirectoryObjectStoreScenarioStatus.ps1");

    public static ScenarioRemoteOptions FromEnvironment()
    {
        return new(
            ScenarioInputValidator.NormalizeTrustedWindowsPath(
                Environment.GetEnvironmentVariable(RemoteRootVariable) ?? @"C:\tds\ObjectStoreScenarioTest",
                RemoteRootVariable),
            ScenarioInputValidator.NormalizeTrustedWindowsPath(
                Environment.GetEnvironmentVariable(CompareSetupScriptVariable) ?? @"C:\tds\CompareAndRepairSetup.ps1",
                CompareSetupScriptVariable),
            ScenarioInputValidator.NormalizeTrustedWindowsPath(
                Environment.GetEnvironmentVariable(RuntimeDependencyRootVariable) ?? @"C:\tds\RuntimeDependencies\net472",
                RuntimeDependencyRootVariable));
    }
}
