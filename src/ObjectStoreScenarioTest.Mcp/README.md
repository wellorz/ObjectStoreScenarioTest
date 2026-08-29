# Object Store ScenarioTest MCP server

`Wellorz.ObjectStoreScenarioTest.Mcp` is a Windows stdio MCP server for
starting, monitoring, resuming, stopping, and reporting on Directory Object
Store ScenarioTest runs on TDS.

## Requirements

- Windows x64
- Microsoft `agency` on `PATH`
- authorized access to the O365 Exchange Enzyme feed
- an administrator-owned TDS script root
- `CompareAndRepairSetup.ps1` and authorized `net472` runtime dependencies on
  the TDS machine

The server starts SubstrateMCP internally through `agency`. It does not store
credentials, bundle Exchange runtime binaries, or write MCP protocol data to
stderr.

## Tools

| Tool | Purpose |
| --- | --- |
| `get_command_catalog` | List commands, phases, estimates, populations, and batch counts |
| `user_upsert` | Run the three user upsert scenarios |
| `group_upsert` | Run the three group upsert scenarios |
| `user_properties_deletion` | Run the three user property-deletion scenarios |
| `group_properties_deletion` | Run the three group property-deletion scenarios |
| `run_all` | Run all 12 scenarios |
| `get_run_status` | Return bounded process, service, port, artifact, and failure status |
| `resume_run` | Resume a compatible paused checkpoint |
| `stop_run` | Stop only the exact verified scenario PID |
| `get_timing_report` | Return structured phase and batch timings |

Start tools report the default two-minute interval for the first ten traffic
minutes and five-minute interval thereafter. The calling agent or skill must
schedule those reports; an stdio MCP server cannot initiate unsolicited chat
messages.

## Trusted TDS configuration

Defaults:

```text
OBJECTSTORE_SCENARIO_REMOTE_ROOT=C:\tds\ObjectStoreScenarioTest
OBJECTSTORE_SCENARIO_COMPARE_SETUP_SCRIPT=C:\tds\CompareAndRepairSetup.ps1
OBJECTSTORE_SCENARIO_RUNTIME_DEPENDENCY_ROOT=C:\tds\RuntimeDependencies\net472
```

Optional nested-MCP overrides:

```text
OBJECTSTORE_SCENARIO_SUBSTRATE_MCP_COMMAND=agency
OBJECTSTORE_SCENARIO_SUBSTRATE_MCP_ARGUMENTS_JSON=["artifact","exec",...]
```

Executable paths are server configuration rather than public tool arguments.
Remote scripts are SHA-256 verified before execution, and run directories
must be immediate children of the configured `Runs` root.

## Install from Enzyme

```powershell
copilot mcp add object-store-scenario -- `
    dnx Wellorz.ObjectStoreScenarioTest.Mcp@0.1.0-beta `
    --add-source https://pkgs.dev.azure.com/o365exchange/_packaging/Enzyme/nuget/v3/index.json
```

## Build and test from source

```powershell
dotnet build .\src\ObjectStoreScenarioTest.Mcp\ObjectStoreScenarioTest.Mcp.csproj -c Release

dotnet run `
    --project .\tests\ObjectStoreScenarioTest.Mcp.IntegrationTests\ObjectStoreScenarioTest.Mcp.IntegrationTests.csproj `
    --configuration Release
```

The integration test launches the server over stdio, lists all tools, invokes
the command catalog, validates public schemas and trusted-path rules, and
parses the generated and packaged PowerShell scripts.

## Package

```powershell
dotnet pack .\src\ObjectStoreScenarioTest.Mcp\ObjectStoreScenarioTest.Mcp.csproj -c Release
```

Publish the resulting package through the approved authenticated Enzyme feed
workflow. Never commit or document feed credentials.
