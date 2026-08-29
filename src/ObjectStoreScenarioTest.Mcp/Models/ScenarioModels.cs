namespace ObjectStoreScenarioTest.Mcp.Models;

internal sealed record ScenarioCommandDefinition(
    string Name,
    int EstimatedMinutes,
    IReadOnlyList<string> Phases,
    int UserCount,
    int GroupCount)
{
    public int BatchCount => Phases.Count * 4;
}

public sealed record ScenarioStartResult(
    string Command,
    int EstimatedMinutes,
    IReadOnlyList<string> Phases,
    int BatchCount,
    string MachineNameOrIp,
    string Organization,
    string ObjectPrefix,
    string RunId,
    string RunDirectory,
    int ProcessId,
    DateTimeOffset ProcessStartUtc,
    string StandardOutputPath,
    string StandardErrorPath,
    string ScriptSha256,
    string LaunchToken,
    int InitialReportIntervalMinutes,
    int SteadyReportIntervalMinutes,
    int SteadyIntervalAfterMinutes,
    string MonitoringInstruction);

public sealed record ScenarioStopResult(
    string RunDirectory,
    int ProcessId,
    bool Stopped,
    string Message);
