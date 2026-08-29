# Directory Object Store ScenarioTest

This repository contains the ScenarioTest harness and Copilot skill for
creating isolated Exchange recipients on a TDS machine, mutating recipient and
link properties, and comparing Active Directory with Directory Object Store.

The primary interface is the five `ScenarioCommand` values below. Legacy
`AttributeCoverage` and time-based `Longevity` modes remain available for
advanced use.

## Shared commands

Users can invoke the skill with one of these exact command names:

| Command | Scenarios | Fresh population | Estimate | Batches |
| --- | --- | ---: | ---: | ---: |
| `User-Upsert` | Pure User Recipient Upsert, Pure User Link Upsert, Mixed User Upsert | 235 contacts | about 1 hour | 12 |
| `Group-Upsert` | Pure Group Recipient Upsert, Pure Group Link Upsert, Mixed Group Upsert | 267 groups | about 75 minutes | 12 |
| `User-Properties-Deletion` | Pure User Recipient Deletion, Pure User Link Deletion, Mixed User Deletion | 235 contacts | about 80 minutes | 12 |
| `Group-Properties-Deletion` | Pure Group Recipient Deletion, Pure Group Link Deletion, Mixed Group Deletion | 267 groups | about 90 minutes | 12 |
| `RunAll` | All 12 scenarios in canonical order | 235 contacts and 267 groups | about 5 hours | 48 |

Each scenario has four batches:

1. Batch 0 mutates one property on every object.
2. Batches 1-3 use deterministic variable-width property selections.
3. Every mutation batch completes before the 15-second sync wait begins.
4. The next batch starts only after every required comparison returns
   `DataSame`.

Deletion commands first prepare missing values for every object, compare all
seeded baselines together, and only then start deletion mutations.

## PowerShell invocation

Run the harness from an elevated Windows PowerShell 5.1 Exchange environment
on the TDS machine:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Upsert `
    -Organization contoso.com `
    -ObjectPrefix DOSUserUpsert `
    -Side A `
    -ObjectStoreDestination Test `
    -CompareSetupScript C:\tds\CompareAndRepairSetup.ps1 `
    -ScenarioRuntimeDependencyRoot C:\tds\RuntimeDependencies\net472
```

Replace `User-Upsert` with any command from the table. Use a unique
`ObjectPrefix` for every new population.

The script records the selected command, phase list, estimate, population
sizes, and total batch count in `parameters.json`, `status.json`,
`checkpoint.json`, and `summary.json`.

## Start announcement

Before launching, the skill reports:

```text
Command: <command>
Scenarios: <ordered scenario names>
Estimated duration: <estimate>
Population: <contacts/groups to create>
Monitoring: every 2 minutes for the first 10 traffic minutes, then every
5 minutes while healthy.
```

The estimates describe expected scenario execution on a healthy TDS machine.
Initial preflight, exhaustive qualification, environment repair, or a script
repair can add time.

## Prerequisites

- Use a dedicated Windows TDS Exchange machine.
- Run from an elevated Windows PowerShell 5.1 process.
- `MSExchangeDirCacheService`, OLS, and
  `M365DirectoryProxyService` must be healthy.
- Ports 83 and 6092 must be listening.
- Supply a test organization such as `contoso.com`.
- Keep `CompareAndRepairSetup.ps1` available on the TDS machine.
- Provision `RuntimeDependencies\net472` from an authorized internal build.
  Do not commit compiled Exchange binaries to this repository.
- Use a dedicated, unique object prefix.

`User` means a mail-contact recipient created by this harness. It does not
mean an AD user or mailbox user. `Group` means a distribution group created by
the harness.

## Skill and stdio MCP server

The scripts can still be run directly on TDS. For a narrower Copilot
interface, this repository also provides the Windows stdio MCP server
`Wellorz.ObjectStoreScenarioTest.Mcp`.

The server exposes:

- `get_command_catalog`
- `user_upsert`
- `group_upsert`
- `user_properties_deletion`
- `group_properties_deletion`
- `run_all`
- `get_run_status`
- `resume_run`
- `stop_run`
- `get_timing_report`

The MCP server launches SubstrateMCP internally through the Microsoft
`agency` tool. Consumers do not need to register a second `substratemcp`
server in Copilot CLI, but they do need `agency` on `PATH` and authorized
access to the O365 Exchange Enzyme feed. No credentials or runtime Exchange
binaries are included in the package.

The default administrator-owned paths on TDS are:

```text
C:\tds\ObjectStoreScenarioTest
C:\tds\CompareAndRepairSetup.ps1
C:\tds\RuntimeDependencies\net472
```

Administrators can override them in the environment that starts Copilot:

| Environment variable | Purpose |
| --- | --- |
| `OBJECTSTORE_SCENARIO_REMOTE_ROOT` | Trusted script, run, and launch-log root |
| `OBJECTSTORE_SCENARIO_COMPARE_SETUP_SCRIPT` | Trusted comparison setup script |
| `OBJECTSTORE_SCENARIO_RUNTIME_DEPENDENCY_ROOT` | Trusted `net472` runtime dependencies |
| `OBJECTSTORE_SCENARIO_SUBSTRATE_MCP_COMMAND` | Nested SubstrateMCP launcher, default `agency` |
| `OBJECTSTORE_SCENARIO_SUBSTRATE_MCP_ARGUMENTS_JSON` | JSON string array overriding launcher arguments |

Executable paths are intentionally not MCP tool arguments. The server
canonicalizes run directories beneath the configured `Runs` root, rejects
UNC/device/reparse-point paths, and verifies packaged script hashes before
execution.

### Install the MCP server from source

Build and register the server:

```powershell
dotnet build .\src\ObjectStoreScenarioTest.Mcp\ObjectStoreScenarioTest.Mcp.csproj -c Release

copilot mcp add object-store-scenario -- `
    dotnet run `
    --project Q:\src\ObjectStoreScenarioTest\src\ObjectStoreScenarioTest.Mcp\ObjectStoreScenarioTest.Mcp.csproj `
    --configuration Release `
    --no-build
```

Use an absolute project path in the registration. Verify it with:

```powershell
copilot mcp list
copilot mcp get object-store-scenario
```

### Install the published MCP package

After version `0.1.0-beta` is published to Enzyme:

```powershell
copilot mcp add object-store-scenario -- `
    dnx Wellorz.ObjectStoreScenarioTest.Mcp@0.1.0-beta `
    --add-source https://pkgs.dev.azure.com/o365exchange/_packaging/Enzyme/nuget/v3/index.json
```

Inside an interactive session, use `/mcp` to inspect the server. Start a new
session or use `/restart` if newly registered tools are not visible.

The MCP server returns the requested monitoring cadence but cannot send
unsolicited chat messages. The `scenario-test-runner` skill remains
responsible for creating and updating the two-minute/five-minute Copilot
monitoring schedule.

## Preflight and qualification

A new command run performs:

1. Exchange and Object Store cookie initialization.
2. Comparison-runtime checks.
3. LDAP schema and property-generator validation.
4. Command-specific deterministic qualification.
5. Semantic target checks.
6. Fresh population creation.

Qualification covers only the phases selected by `ScenarioCommand`:

- subset command: 3 phases and 12 batches;
- `RunAll`: 12 phases and 48 batches.

Scenario traffic starts only after qualification reports zero defects.

For read-only environment checking:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand Group-Upsert `
    -PreflightOnly `
    -Organization contoso.com `
    -ObjectPrefix DOSPreflight
```

## Monitoring and reporting

Default reporting cadence:

1. Report every two minutes during bootstrap and the first ten traffic
   minutes.
2. After ten stable traffic minutes, report every five minutes.
3. Return to two-minute reporting after a failure, repair, resume, or material
   regression.

A user-requested interval overrides these defaults. If the user requests
separate initial and steady-state intervals, use both requested values.

Every report includes:

- local time with UTC offset and UTC time;
- run ID, exact PID, process start time, CPU, and private memory;
- command, current phase, batch, and stage;
- fresh population counts;
- completed batches versus command total;
- mutation and comparison `m/N`;
- baseline preparation, seeding, and comparison progress for deletion;
- operation and validation counters;
- consistency status and new failures;
- service, port, watermark, host-memory, and monitor health;
- current reporting interval.

Use the bounded status helper:

```powershell
.\Get-DirectoryObjectStoreScenarioStatus.ps1 `
    -RunDirectory C:\tds\ObjectStoreScenarioTest\Runs\<run-id> `
    -AllowedRunsRoot C:\tds\ObjectStoreScenarioTest\Runs `
    -AllowedLaunchRoot C:\tds\ObjectStoreScenarioTest\LaunchLogs `
    -ProcessId <pid> `
    -ResumeStartedUtc <process-start-utc> `
    -LaunchToken <32-character-launch-token> `
    -StandardErrorPath <stderr-path>
```

Never load complete JSONL histories during recurring monitoring. Read
`status.json`, `checkpoint.json`, `summary.json`, and `PAUSED`; use at most a
20-line, 256-KB tail when additional log evidence is required.

## Failure behavior

Batch 0 attempts every object and aggregates all mutation and comparison
failures before pausing. Batches 1-3 stop on their first failure.

On failure the run preserves:

- completed object GUIDs;
- deletion preparation and seeding progress;
- the immutable batch plan;
- pending validations;
- operation and comparison evidence;
- a `PAUSED` marker and failure bundle.

Script defects may be repaired and resumed without repeating completed
objects. Product, consistency, and environment failures remain paused for
diagnosis.

## Resume

Always resume with the original workload and command:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Properties-Deletion `
    -ResumeRunDirectory C:\tds\ScenarioTest\Runs\<run-id> `
    -Organization contoso.com `
    -ObjectPrefix <original-prefix> `
    -Side A `
    -ObjectStoreDestination Test
```

The checkpoint persists `WorkloadMode` and `ScenarioCommand`. A mismatched
resume is rejected before state restoration or traffic.

Resume also requires the original organization, side, Object Store
destination, object prefix, random seed, simulation mode, comparison setup,
and runtime dependency path. This prevents a checkpoint from one tenant or
execution mode being applied to another.

Compatible resumes restore:

- `scenario-target-context.clixml`, avoiding repeated target discovery;
- `scenario-plan-pNN-bNN.json`, preserving exact object/property assignments;
- mutation, comparison, and deletion-preparation checkpoints.

Run full preflight on resume only when the failure is proven to involve the
environment, dependencies, cookies, comparison runtime, configuration, or
target discovery.

## Run artifacts

Each run directory contains:

- `parameters.json`
- `status.json`
- `checkpoint.json`
- `summary.json`
- `qualification.json`
- `qualification-progress.json`
- `scenario-target-context.clixml`
- `scenario-plan-pNN-bNN.json`
- bounded/rotated operation, validation, event, and scenario-detail logs
- `PAUSED` and `failure-<timestamp>` when a failure occurs

JSON snapshots use unique temporary files and atomic same-volume replacement
with bounded retry, so concurrent monitor reads cannot pause healthy traffic.

## Timing statistics

Each successful batch records `ElapsedSeconds`, including preparation,
mutation, sync wait, and comparison. Each completed phase contains its four
batch records.

At terminal success, report:

- every phase total;
- all four batch durations;
- upsert/deletion totals;
- total scenario-batch time;
- full wall-clock time;
- any repair/resume-affected timing that should be excluded from comparison.

## Cleanup

Pass `-CleanupOnSuccess` to remove only objects recorded in that run's ledger.
Objects are preserved after failure for diagnosis.

## Advanced workloads

`ScenarioCommand` applies only to `-WorkloadMode ScenarioTest`.

`AttributeCoverage` is the legacy default workload and exercises a generated
attribute catalog. `Longevity` runs a time-based production-shaped mix of
create, update, delete, membership, and read operations.

Do not resume a ScenarioTest checkpoint as `AttributeCoverage` or `Longevity`;
workload-mode compatibility is enforced.

## Copilot skill installation

Clone the repository:

```powershell
git clone https://github.com/wellorz/ObjectStoreScenarioTest.git
Set-Location .\ObjectStoreScenarioTest
```

### Project installation

The repository already contains the project skill at:

```text
.github/skills/scenario-test-runner/SKILL.md
```

Start Copilot CLI from the repository root:

```powershell
copilot
```

Then verify:

```text
/skills reload
/skills info scenario-test-runner
```

### Personal installation

To make the skill available in other repositories, register the cloned skill
collection:

```powershell
copilot skill add Q:\src\ObjectStoreScenarioTest\.github\skills
```

Inside an existing Copilot CLI session:

```text
/skills reload
/skills info scenario-test-runner
```

You can also copy the complete `scenario-test-runner` directory to:

```text
%USERPROFILE%\.copilot\skills\scenario-test-runner
```

The skill directory includes `SKILL.md`, the harness, status script, scenario
contract, and README. Runtime dependency binaries must still be provisioned
separately.

After installation, invoke it with one of:

```text
User-Upsert
Group-Upsert
User-Properties-Deletion
Group-Properties-Deletion
RunAll
```

Keep the root and discoverable copies synchronized when changing the skill.

## MCP development and publication

Run the protocol integration test:

```powershell
dotnet run `
    --project .\tests\ObjectStoreScenarioTest.Mcp.IntegrationTests\ObjectStoreScenarioTest.Mcp.IntegrationTests.csproj `
    --configuration Release
```

Create the self-contained Windows MCP NuGet package:

```powershell
dotnet pack .\src\ObjectStoreScenarioTest.Mcp\ObjectStoreScenarioTest.Mcp.csproj -c Release
```

Publish the generated `.nupkg` through the approved authenticated Enzyme feed
workflow. Do not put feed tokens or API keys in this repository or in shared
installation commands.
