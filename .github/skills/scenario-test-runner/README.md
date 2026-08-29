# Directory Object Store ScenarioTest

This repository contains the ScenarioTest harness and Copilot skill for
creating isolated Exchange recipients on a TDS machine, mutating recipient and
link properties, and comparing Active Directory with Directory Object Store.

The primary interface is the five `ScenarioCommand` values below. Legacy
`AttributeCoverage` and time-based `Longevity` modes remain available for
advanced use.

## Shared commands

Users can invoke the skill with one of these exact command names:

| Command | Scenarios | Fresh population | `--miniSet` | `--full` |
| --- | --- | ---: | ---: | ---: |
| `User-Upsert` | Pure User Recipient Upsert, Pure User Link Upsert, Mixed User Upsert | 235 contacts | about 5 minutes | about 60 minutes |
| `Group-Upsert` | Pure Group Recipient Upsert, Pure Group Link Upsert, Mixed Group Upsert | 267 groups | about 5 minutes | about 75 minutes |
| `User-Properties-Deletion` | Pure User Recipient Deletion, Pure User Link Deletion, Mixed User Deletion | 235 contacts | about 10 minutes | about 80 minutes |
| `Group-Properties-Deletion` | Pure Group Recipient Deletion, Pure Group Link Deletion, Mixed Group Deletion | 267 groups | about 10 minutes | about 95 minutes |
| `RunAll` | All 12 scenarios in canonical order | 235 contacts and 267 groups | about 25 minutes | about 305 minutes |

## Set modes

Every command supports:

- `--full` — four batches per phase; this is the default.
- `--miniSet` — only batch 0 per phase; repetitions 1-3 are skipped.

Examples:

```text
User-Upsert
User-Upsert --full
User-Upsert --miniSet
RunAll --miniSet
```

| Mode | Subset command | `RunAll` |
| --- | ---: | ---: |
| `--full` or omitted | 12 batches | 48 batches |
| `--miniSet` | 3 batches | 12 batches |

Full mode uses four batches:

1. Batch 0 mutates one property on every object.
2. Batches 1-3 use deterministic variable-width property selections.
3. Every mutation batch completes before the 15-second sync wait begins.
4. The next batch starts only after every required comparison returns
   `DataSame`.

Deletion commands first prepare missing values for every object, compare all
seeded baselines together, and only then start deletion mutations.

Mini-set mode retains the complete batch-0 mutation barrier, sync wait,
comparison, and aggregated failure behavior. It changes only the number of
batches; it does not weaken batch-0 validation.

## PowerShell invocation

Run the harness from an elevated Windows PowerShell 5.1 Exchange environment
on the TDS machine:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Upsert `
    -ScenarioSetMode Full `
    -Organization contoso.com `
    -ObjectPrefix DOSUserUpsert `
    -Side A `
    -ObjectStoreDestination Test `
    -CompareSetupScript C:\tds\CompareAndRepairSetup.ps1 `
    -ScenarioRuntimeDependencyRoot C:\tds\RuntimeDependencies\net472
```

Replace `User-Upsert` with any command from the table. When Copilot runs the
skill, it automatically generates a unique `ObjectPrefix` from the command,
UTC timestamp, and a six-character GUID suffix, for example:

```text
DOSUU-0829170744-a1b2c3
```

Users do not need to choose or approve the prefix. Direct PowerShell callers
must still provide their own unique `-ObjectPrefix`.

The script records the selected command, phase list, estimate, population
sizes, and total batch count in `parameters.json`, `status.json`,
`checkpoint.json`, and `summary.json`.

## Start announcement

Before launching, the skill reports:

```text
Command: <command>
Set mode: <Full-or-MiniSet>
Scenarios: <ordered scenario names>
Estimated duration: <estimate>
Population: <contacts/groups to create>
Scenario batches: <mode-specific-total>
Organization: <supplied-or-automatically-selected-organization>
Object prefix: <automatically-generated-prefix>
Monitoring: every 2 minutes for the first 10 traffic minutes, then every
5 minutes while healthy.
```

The estimates describe expected scenario execution on a healthy TDS machine.
Initial preflight, exhaustive qualification, environment repair, or a script
repair can add time.

The estimates use the measured timings from the completed 48-batch run.
Mini-set sums the three or twelve batch-0 durations; full sums all applicable
scenario totals. Each value is rounded upward to the next five minutes:

- `User-Upsert`: 5 minutes mini-set, 60 minutes full;
- `Group-Upsert`: 5 minutes mini-set, 75 minutes full;
- `User-Properties-Deletion`: 10 minutes mini-set, 80 minutes full;
- `Group-Properties-Deletion`: 10 minutes mini-set, 95 minutes full;
- `RunAll`: 25 minutes mini-set, 305 minutes full.

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

When the user does not specify an organization, the skill discovers eligible
Exchange organizations with `Get-Organization`. It prefers a valid
active `contoso.com` organization with a `UserMailbox`; otherwise it
deterministically uses the first active, non-system organization with a
`UserMailbox`. It never treats the forest's default `Get-AcceptedDomain` value
as the tenant. If no eligible organization exists, the run stops with a
prerequisite error instead of asking the user to choose from system tenants.

`User` means a mail-contact recipient created by this harness. It does not
mean an AD user or mailbox user. `Group` means a distribution group created by
the harness.

## Skill versus MCP

ObjectStoreScenarioTest is an **agent skill plus PowerShell scripts**. It is
not an MCP server and does not require an MCP server when an operator runs the
scripts directly on the TDS machine.

For Copilot-driven remote TDS setup, execution, and monitoring, the skill uses
an independently managed SubstrateMCP server exposing tools such as
`tds_execute_powershell` and `tds_copy_files`. SubstrateMCP is not bundled in
this repository.

Install the internal SubstrateMCP server in Copilot CLI:

```powershell
copilot mcp add substratemcp -- `
    agency artifact exec `
    --feed https://pkgs.dev.azure.com/o365exchange/_packaging/Enzyme/nuget/v3/index.json `
    --name Microsoft.Substrate.SubstrateMCP `
    --type nuget `
    --rid none `
    -- tools\any\win-x64\SubstrateDevelopmentMCP.Hosts.Console mcp start
```

This requires the Microsoft `agency` tool and access to the O365 Exchange
Enzyme feed. Verify the installation:

```powershell
copilot mcp list
copilot mcp get substratemcp
```

Inside an interactive session, use `/mcp` to view or manage configured
servers. Start a new session or use `/restart` if the newly added tools are not
visible.

## Preflight and qualification

A new command run performs:

1. Exchange and Object Store cookie initialization.
2. Comparison-runtime checks.
3. LDAP schema and property-generator validation.
4. Command-specific deterministic qualification.
5. Semantic target checks.
6. Fresh population creation.

Qualification covers only the phases selected by `ScenarioCommand`:

- Full subset command: 3 phases and 12 batches;
- Mini-set subset command: 3 phases and 3 batches;
- Full `RunAll`: 12 phases and 48 batches;
- Mini-set `RunAll`: 12 phases and 12 batches.

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
    -RunDirectory C:\tds\ScenarioTest\Runs\<run-id> `
    -ProcessId <pid> `
    -ResumeStartedUtc <process-start-utc> `
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

Always resume with the original workload, command, and set mode:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Properties-Deletion `
    -ScenarioSetMode <original-Full-or-MiniSet> `
    -ResumeRunDirectory C:\tds\ScenarioTest\Runs\<run-id> `
    -Organization contoso.com `
    -ObjectPrefix <original-prefix> `
    -Side A `
    -ObjectStoreDestination Test
```

The checkpoint persists `WorkloadMode`, `ScenarioCommand`, and
`ScenarioSetMode`. A mismatched resume is rejected before state restoration or
traffic.

Resume also requires the original organization, side, Object Store
destination, object prefix, random seed, simulation mode, comparison setup,
and runtime dependency path. This prevents a checkpoint from one set mode,
tenant, or execution mode being applied to another.

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
- every configured batch duration;
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
copilot skill add "$PWD\.github\skills"
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

This directory is the single source of truth for the skill. Edit these files
directly and do not recreate duplicate operational copies at the repository
root.
