using ObjectStoreScenarioTest.Mcp.Models;

namespace ObjectStoreScenarioTest.Mcp.Services;

internal static class ScenarioCatalog
{
    private static readonly IReadOnlyDictionary<string, ScenarioCommandDefinition> Definitions =
        new Dictionary<string, ScenarioCommandDefinition>(StringComparer.OrdinalIgnoreCase)
        {
            ["User-Upsert"] = new(
                "User-Upsert",
                60,
                [
                    "Pure User Recipient Upsert",
                    "Pure User Link Upsert",
                    "Mixed User Upsert",
                ],
                235,
                0),
            ["Group-Upsert"] = new(
                "Group-Upsert",
                75,
                [
                    "Pure Group Recipient Upsert",
                    "Pure Group Link Upsert",
                    "Mixed Group Upsert",
                ],
                0,
                267),
            ["User-Properties-Deletion"] = new(
                "User-Properties-Deletion",
                80,
                [
                    "Pure User Recipient Deletion",
                    "Pure User Link Deletion",
                    "Mixed User Deletion",
                ],
                235,
                0),
            ["Group-Properties-Deletion"] = new(
                "Group-Properties-Deletion",
                90,
                [
                    "Pure Group Recipient Deletion",
                    "Pure Group Link Deletion",
                    "Mixed Group Deletion",
                ],
                0,
                267),
            ["RunAll"] = new(
                "RunAll",
                300,
                [
                    "Pure User Recipient Upsert",
                    "Pure User Link Upsert",
                    "Pure Group Recipient Upsert",
                    "Pure Group Link Upsert",
                    "Mixed User Upsert",
                    "Mixed Group Upsert",
                    "Pure User Recipient Deletion",
                    "Pure User Link Deletion",
                    "Pure Group Recipient Deletion",
                    "Pure Group Link Deletion",
                    "Mixed User Deletion",
                    "Mixed Group Deletion",
                ],
                235,
                267),
        };

    public static IReadOnlyCollection<ScenarioCommandDefinition> All => Definitions.Values.ToArray();

    public static ScenarioCommandDefinition Get(string command)
    {
        if (!Definitions.TryGetValue(command, out ScenarioCommandDefinition? definition))
        {
            throw new ArgumentException($"Unknown scenario command '{command}'.", nameof(command));
        }

        return definition;
    }
}
