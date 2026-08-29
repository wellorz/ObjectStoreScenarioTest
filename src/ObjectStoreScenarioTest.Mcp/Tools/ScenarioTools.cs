using System.ComponentModel;
using System.Text.Json;
using ModelContextProtocol.Server;
using ObjectStoreScenarioTest.Mcp.Models;
using ObjectStoreScenarioTest.Mcp.Services;

namespace ObjectStoreScenarioTest.Mcp.Tools;

internal sealed class ScenarioTools(ScenarioService scenarioService)
{
    [McpServerTool(Name = "get_command_catalog", ReadOnly = true, Idempotent = true, UseStructuredContent = true)]
    [Description("Lists the available Object Store ScenarioTest commands, phases, estimates, populations, and batch counts.")]
    public object GetCommandCatalog()
    {
        return scenarioService.GetCatalog().Select(definition => new
        {
            command = definition.Name,
            estimatedMinutes = definition.EstimatedMinutes,
            phases = definition.Phases,
            userCount = definition.UserCount,
            groupCount = definition.GroupCount,
            batchCount = definition.BatchCount,
        });
    }

    [McpServerTool(Name = "user_upsert", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Starts Pure User Recipient Upsert, Pure User Link Upsert, and Mixed User Upsert on a TDS machine.")]
    public Task<ScenarioStartResult> UserUpsert(
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side = "A",
        string objectStoreDestination = "Test",
        int randomSeed = 1729,
        int initialReportIntervalMinutes = 2,
        int steadyReportIntervalMinutes = 5,
        int steadyIntervalAfterMinutes = 10,
        CancellationToken cancellationToken = default) =>
        StartAsync("User-Upsert", machineNameOrIp, organization, objectPrefix, side, objectStoreDestination, randomSeed, initialReportIntervalMinutes, steadyReportIntervalMinutes, steadyIntervalAfterMinutes, cancellationToken);

    [McpServerTool(Name = "group_upsert", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Starts Pure Group Recipient Upsert, Pure Group Link Upsert, and Mixed Group Upsert on a TDS machine.")]
    public Task<ScenarioStartResult> GroupUpsert(
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side = "A",
        string objectStoreDestination = "Test",
        int randomSeed = 1729,
        int initialReportIntervalMinutes = 2,
        int steadyReportIntervalMinutes = 5,
        int steadyIntervalAfterMinutes = 10,
        CancellationToken cancellationToken = default) =>
        StartAsync("Group-Upsert", machineNameOrIp, organization, objectPrefix, side, objectStoreDestination, randomSeed, initialReportIntervalMinutes, steadyReportIntervalMinutes, steadyIntervalAfterMinutes, cancellationToken);

    [McpServerTool(Name = "user_properties_deletion", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Starts Pure User Recipient Deletion, Pure User Link Deletion, and Mixed User Deletion on a TDS machine.")]
    public Task<ScenarioStartResult> UserPropertiesDeletion(
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side = "A",
        string objectStoreDestination = "Test",
        int randomSeed = 1729,
        int initialReportIntervalMinutes = 2,
        int steadyReportIntervalMinutes = 5,
        int steadyIntervalAfterMinutes = 10,
        CancellationToken cancellationToken = default) =>
        StartAsync("User-Properties-Deletion", machineNameOrIp, organization, objectPrefix, side, objectStoreDestination, randomSeed, initialReportIntervalMinutes, steadyReportIntervalMinutes, steadyIntervalAfterMinutes, cancellationToken);

    [McpServerTool(Name = "group_properties_deletion", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Starts Pure Group Recipient Deletion, Pure Group Link Deletion, and Mixed Group Deletion on a TDS machine.")]
    public Task<ScenarioStartResult> GroupPropertiesDeletion(
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side = "A",
        string objectStoreDestination = "Test",
        int randomSeed = 1729,
        int initialReportIntervalMinutes = 2,
        int steadyReportIntervalMinutes = 5,
        int steadyIntervalAfterMinutes = 10,
        CancellationToken cancellationToken = default) =>
        StartAsync("Group-Properties-Deletion", machineNameOrIp, organization, objectPrefix, side, objectStoreDestination, randomSeed, initialReportIntervalMinutes, steadyReportIntervalMinutes, steadyIntervalAfterMinutes, cancellationToken);

    [McpServerTool(Name = "run_all", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Starts all 12 Object Store scenarios in canonical order on a TDS machine.")]
    public Task<ScenarioStartResult> RunAll(
        string machineNameOrIp,
        string organization,
        string objectPrefix,
        string side = "A",
        string objectStoreDestination = "Test",
        int randomSeed = 1729,
        int initialReportIntervalMinutes = 2,
        int steadyReportIntervalMinutes = 5,
        int steadyIntervalAfterMinutes = 10,
        CancellationToken cancellationToken = default) =>
        StartAsync("RunAll", machineNameOrIp, organization, objectPrefix, side, objectStoreDestination, randomSeed, initialReportIntervalMinutes, steadyReportIntervalMinutes, steadyIntervalAfterMinutes, cancellationToken);

    [McpServerTool(Name = "get_run_status", ReadOnly = true, Idempotent = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Gets bounded status for a run. Supply the launch token returned by start or resume when checking a live PID.")]
    public Task<JsonElement> GetRunStatus(
        string machineNameOrIp,
        string runDirectory,
        int processId = 0,
        DateTimeOffset? processStartUtc = null,
        string? launchToken = null,
        CancellationToken cancellationToken = default) =>
        scenarioService.GetStatusAsync(machineNameOrIp, runDirectory, processId, processStartUtc, launchToken, cancellationToken);

    [McpServerTool(Name = "resume_run", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Resumes a compatible ScenarioTest checkpoint using its original command and immutable parameters.")]
    public Task<ScenarioStartResult> ResumeRun(
        string machineNameOrIp,
        string runDirectory,
        int initialReportIntervalMinutes = 2,
        int steadyReportIntervalMinutes = 5,
        int steadyIntervalAfterMinutes = 10,
        CancellationToken cancellationToken = default) =>
        scenarioService.ResumeAsync(machineNameOrIp, runDirectory, initialReportIntervalMinutes, steadyReportIntervalMinutes, steadyIntervalAfterMinutes, cancellationToken);

    [McpServerTool(Name = "stop_run", Destructive = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Stops the exact ScenarioTest process after verifying PID, start time, harness command line, and launch token.")]
    public Task<ScenarioStopResult> StopRun(
        string machineNameOrIp,
        string runDirectory,
        int processId,
        DateTimeOffset processStartUtc,
        string launchToken,
        CancellationToken cancellationToken = default) =>
        scenarioService.StopAsync(machineNameOrIp, runDirectory, processId, processStartUtc, launchToken, cancellationToken);

    [McpServerTool(Name = "get_timing_report", ReadOnly = true, Idempotent = true, OpenWorld = true, UseStructuredContent = true)]
    [Description("Returns per-phase, per-batch, and total elapsed timing statistics from a ScenarioTest checkpoint.")]
    public Task<JsonElement> GetTimingReport(
        string machineNameOrIp,
        string runDirectory,
        CancellationToken cancellationToken = default) =>
        scenarioService.GetTimingReportAsync(machineNameOrIp, runDirectory, cancellationToken);

    private Task<ScenarioStartResult> StartAsync(
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
        CancellationToken cancellationToken) =>
        scenarioService.StartAsync(
            command,
            machineNameOrIp,
            organization,
            objectPrefix,
            side,
            objectStoreDestination,
            randomSeed,
            initialReportIntervalMinutes,
            steadyReportIntervalMinutes,
            steadyIntervalAfterMinutes,
            cancellationToken);
}
