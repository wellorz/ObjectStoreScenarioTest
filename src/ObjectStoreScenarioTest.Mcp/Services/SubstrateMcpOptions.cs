using System.Text.Json;

namespace ObjectStoreScenarioTest.Mcp.Services;

internal sealed record SubstrateMcpOptions(string Command, IReadOnlyList<string> Arguments)
{
    private const string CommandVariable = "OBJECTSTORE_SCENARIO_SUBSTRATE_MCP_COMMAND";
    private const string ArgumentsVariable = "OBJECTSTORE_SCENARIO_SUBSTRATE_MCP_ARGUMENTS_JSON";

    public static SubstrateMcpOptions FromEnvironment()
    {
        string command = Environment.GetEnvironmentVariable(CommandVariable) ?? "agency";
        string? configuredArguments = Environment.GetEnvironmentVariable(ArgumentsVariable);
        string[] arguments = configuredArguments is null
            ?
            [
                "artifact",
                "exec",
                "--feed",
                "https://pkgs.dev.azure.com/o365exchange/_packaging/Enzyme/nuget/v3/index.json",
                "--name",
                "Microsoft.Substrate.SubstrateMCP",
                "--type",
                "nuget",
                "--rid",
                "none",
                "--",
                @"tools\any\win-x64\SubstrateDevelopmentMCP.Hosts.Console",
                "mcp",
                "start",
            ]
            : JsonSerializer.Deserialize<string[]>(configuredArguments)
                ?? throw new InvalidOperationException($"{ArgumentsVariable} must be a JSON string array.");

        if (string.IsNullOrWhiteSpace(command))
        {
            throw new InvalidOperationException($"{CommandVariable} cannot be empty.");
        }

        return new(command, arguments);
    }
}
