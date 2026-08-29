---
name: scenario-test-runner
description: Run User-Upsert, Group-Upsert, User-Properties-Deletion, Group-Properties-Deletion, or RunAll Directory Object Store scenarios. Supports start, resume, monitoring, diagnosis, repair, timing reports, and repro packages with adaptive bounded-memory reporting.
---

# Scenario Test Runner

## Purpose
Execute `ScenarioTest.md` and `Invoke-DirectoryObjectStoreLongevity.ps1` as an operational runbook while minimizing unnecessary preflight cost and preserving evidence for diagnosis.

## User-facing commands

Treat any of these exact, case-insensitive command names as a request to start
the corresponding ScenarioTest subset:

| Command | Scenarios | Population | Full estimate | Full batches |
| --- | --- | ---: | ---: | ---: |
| `User-Upsert` | Pure User Recipient Upsert; Pure User Link Upsert; Mixed User Upsert | 235 contacts | about 1 hour | 12 |
| `Group-Upsert` | Pure Group Recipient Upsert; Pure Group Link Upsert; Mixed Group Upsert | 267 groups | about 75 minutes | 12 |
| `User-Properties-Deletion` | Pure User Recipient Deletion; Pure User Link Deletion; Mixed User Deletion | 235 contacts | about 80 minutes | 12 |
| `Group-Properties-Deletion` | Pure Group Recipient Deletion; Pure Group Link Deletion; Mixed Group Deletion | 267 groups | about 90 minutes | 12 |
| `RunAll` | All 12 scenarios in canonical order | 235 contacts and 267 groups | about 5 hours | 48 |

Each command accepts one optional mode modifier:

- `--full`: run batch 0 plus repetitions 1, 2, and 3 for every phase.
- `--miniSet`: run only batch 0 for every phase; skip repetitions 1-3.

Use `--full` when no modifier is supplied. Do not ask the user to choose a
mode. Reject a request containing both modifiers.

Examples:

```text
User-Upsert
User-Upsert --full
User-Upsert --miniSet
RunAll --miniSet
```

Map the modifier to the harness:

```powershell
$ScenarioSetMode = if ($UserRequestedMiniSet) { "MiniSet" } else { "Full" }
```

Invoke the harness with the matching `-ScenarioCommand`:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode ScenarioTest `
    -ScenarioCommand User-Upsert `
    -ScenarioSetMode $ScenarioSetMode `
    -Organization $Organization `
    -ObjectPrefix $ObjectPrefix `
    -Side A `
    -ObjectStoreDestination Test
```

## Automatic input resolution

Do not ask the user to choose an object prefix. Generate a new prefix for every
fresh run using the command code, UTC timestamp, and a six-character GUID
suffix:

```powershell
$commandCode = @{
    "User-Upsert" = "UU"
    "Group-Upsert" = "GU"
    "User-Properties-Deletion" = "UD"
    "Group-Properties-Deletion" = "GD"
    "RunAll" = "RA"
}[$ScenarioCommand]
$ObjectPrefix = "DOS$commandCode-$([datetime]::UtcNow.ToString('MMddHHmmss'))-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
```

The generated value satisfies the harness's 3-32 character constraint. Report
it in the start announcement and persist it in run state, but do not ask the
user to approve or edit it unless they explicitly supplied a prefix.

Resolve the organization without prompting when possible:

1. Use the organization explicitly supplied by the user.
2. Otherwise prefer `contoso.com` when it is a valid Exchange organization
   with at least one mailbox.
3. If `contoso.com` is unavailable, choose the first eligible non-system
   organization, sorted by name, that has at least one mailbox:
   ```powershell
   $Organization = $null
   $preferred = Get-Organization -Identity "contoso.com" -ErrorAction SilentlyContinue
   if ($null -ne $preferred -and
       $preferred.OrganizationStatus.ToString() -eq "Active")
   {
       $mailbox = Get-Mailbox -Organization "contoso.com" -ResultSize Unlimited `
           -ErrorAction SilentlyContinue |
           Where-Object { $_.RecipientTypeDetails -eq "UserMailbox" } |
           Select-Object -First 1
       if ($null -ne $mailbox)
       {
           $Organization = "contoso.com"
       }
   }

   if ([string]::IsNullOrWhiteSpace($Organization))
   {
       $Organization = Get-Organization -ResultSize Unlimited |
           Where-Object {
               $name = [string]$_.Name
               $_.OrganizationStatus.ToString() -eq "Active" -and
               $name -notmatch "^(sct-|DirSyncSystemTenant-)" -and
               $name -notmatch "\.templateTenant$" -and
               $name -notmatch "\.exchangemon\.net$"
           } |
           Sort-Object Name |
           ForEach-Object {
               $name = [string]$_.Name
               $mailbox = Get-Mailbox -Organization $name -ResultSize Unlimited `
                   -ErrorAction SilentlyContinue |
                   Where-Object { $_.RecipientTypeDetails -eq "UserMailbox" } |
                   Select-Object -First 1
               if ($null -ne $mailbox)
               {
                   $name
               }
           } |
           Select-Object -First 1
   }
   ```
4. If no eligible organization exists, stop and report the missing
   prerequisite. Do not ask the user to choose from system, synthetic,
   monitoring, forest-domain, or template tenants.

`Get-AcceptedDomain` is not organization discovery. Its default authoritative
domain can be the TDS forest domain, which `Get-Organization -Identity` cannot
use as a tenant.

Likewise, use an explicitly supplied TDS machine or the active TDS machine.
Ask only when neither is available or the target is ambiguous. Do not ask for
confirmation of the selected command, generated prefix, default side `A`,
destination `Test`, random seed `1729`, default `Full` set mode, or default
reporting intervals.

Before starting, tell the user:

```text
Command: <command>
Set mode: <Full-or-MiniSet>
Scenarios: <ordered scenario names>
Estimated duration: <estimate>
Population: <contacts/groups to create>
Scenario batches: <completed>/<mode-specific-total>
Organization: <supplied-or-discovered-organization>
Object prefix: <automatically-generated-prefix>
Monitoring: every 2 minutes for the first 10 traffic minutes, then every
5 minutes while healthy.
```

If the user specifies a reporting interval, use their requested interval
instead. If they specify separate initial and steady-state intervals, use both.
After any failure, repair, resume, or material regression, return to the
requested initial interval; otherwise return to the default two-minute
interval.

Mode-specific totals:

- subset command with `Full`: 12 batches;
- subset command with `MiniSet`: 3 batches;
- `RunAll --full` or plain `RunAll`: 48 batches;
- `RunAll --miniSet`: 12 batches.

Mini-set estimates are one quarter of the corresponding full estimate, rounded
up. They remain estimates; environment preflight and repair can add time.

## Discoverability and helper skills

This directory is the canonical, self-contained skill package. It includes
`SKILL.md`, the harness, status helper, scenario contract, and operating guide.
Share or install the complete `scenario-test-runner` directory; do not create
or maintain duplicate operational files at the repository root.

Provision `RuntimeDependencies\net472` separately from an authorized internal
build. Do not commit compiled Exchange binaries, credentials, or TDS run
artifacts to this repository.

Use existing project skills only for their narrow supporting roles:

- `cd-tds-box`: repair a missing TDS organization or mailbox prerequisite. Skip
  add-in provisioning because ScenarioTest does not require it.
- `tdsedi`: verify live process configuration, loaded binary versions, and
  restart uptake after a configuration, service, or binary repair. Do not run
  broad Get-EDI queries on every routine progress report.
- `tdsecs`: use only when an ECS/variant-config setting itself must be inspected
  or changed. The harness's documented `DirectoryObjectStore.settings.ini`
  setup remains authoritative for this scenario.
- `tdscopy`: use only when product binaries must be deployed. Use
  `tds_copy_files` for the harness, status script, comparison setup script, and
  `RuntimeDependencies\net472` payload.

Do not invoke a supporting skill merely because it is available. The active
harness and its TDS run directory remain the source of truth.

SubstrateMCP is a separate prerequisite for Copilot-driven remote TDS
operations. Install it with:

```powershell
copilot mcp add substratemcp -- `
    agency artifact exec `
    --feed https://pkgs.dev.azure.com/o365exchange/_packaging/Enzyme/nuget/v3/index.json `
    --name Microsoft.Substrate.SubstrateMCP `
    --type nuget `
    --rid none `
    -- tools\any\win-x64\SubstrateDevelopmentMCP.Hosts.Console mcp start
```

This requires `agency` and authorized Enzyme feed access. Do not add tokens,
passwords, or feed credentials to this repository or the command.

## Required inputs and discovery

1. Locate `ScenarioTest.md` and `Invoke-DirectoryObjectStoreLongevity.ps1`.
2. Read `ScenarioTest.md` completely and inspect the script parameter block and execution entry point before executing any command.
3. Extract and maintain these commands, parameters, or procedures from the document and script:
   - scenario command and estimate
   - full preflight
   - traffic start
   - traffic status/query
   - failure-stop behavior and whether a graceful operator stop exists
   - local validation
   - TDS validation/run
   - stale-state inspection and cleanup
   - object-level diagnostics
   - organization, side, Object Store destination, compare setup script,
     runtime dependency root, output root, and automatic object-prefix format
4. Never invent a command, environment, tenant, object identifier, cleanup scope, or success criterion that is absent from `ScenarioTest.md`, the harness, supporting scripts, or command output.
5. If a required command is not documented, stop before the unsafe step and report the exact missing item plus the evidence collected so far.

## Persistent run state

Treat the harness run directory on TDS as the source of truth. Read its
`parameters.json`, `status.json`, `checkpoint.json`, `summary.json`,
`events.jsonl`, validation logs, and terminal markers directly.

Do not create `.scenario-test-run-state.json` or `.scenario-test-run.log` in a
repository or shared workspace. If session-local continuity is needed, store a
small state record in the agent's session-artifact area. Track at least:

- `runId`
- `scenarioCommand`
- `scenarioSetMode`
- `estimatedMinutes`
- `machineName`
- `machineIp`
- `remoteRunDirectory`
- `processId`
- `processStartUtc`
- `stdoutPath`
- `stderrPath`
- `startedAtUtc`
- `phase`
- `scriptSha256`
- `configurationFingerprint`
- `fullPreflightCompleted`
- `preflightRunId`
- `trafficStartedAtUtc`
- `reportIntervalMinutes`
- `scheduleId`
- `lastReportAtUtc`
- `lastKnownStatus`
- `dataConsistencyStatus`
- `dataConsistencyEvidence`
- `failureClassification`
- `failedObjects`
- `scriptFixes`
- `cleanupActions`
- `commandsExecuted`
- `evidencePaths`

Never put secrets, tokens, passwords, certificate private material, or full
credentials in session state or reports.

## State machine

Use this state flow:

`DISCOVER -> PREFLIGHT -> START_TRAFFIC -> MONITOR_2M -> MONITOR_5M`

Failures may transition from any active state to `DIAGNOSE`, then to
`FIX_SCRIPT`, `VALIDATE_FIX`, `TARGETED_CLEANUP`, `RESUME_TRAFFIC`,
`STOP_AND_REPRO`, or `COMPLETE` as supported by evidence. A failed preflight
may return to `PREFLIGHT` after its prerequisite is corrected.

A resumed run must load and verify the exact TDS run directory. Reconstruct
missing session state from TDS artifacts when necessary. Never attach to a PID
or run merely because it is the newest one.

Before modifying any resume artifact, require the original workload, scenario
command, scenario set mode, organization, side, Object Store destination,
object prefix, random seed, WhatIf mode, comparison setup, and runtime
dependency path. Reject a cross-mode, cross-tenant, cross-destination, or
simulation-to-live resume.

## 1. Full preflight

Run the complete preflight before starting traffic when any of these is true:

- no successful preflight exists for the exact TDS machine;
- the harness or runtime dependency hash changed;
- the organization, side, Object Store destination, compare setup, relevant
  variant configuration, or service topology changed;
- the machine rebooted, was reprovisioned, or restored from a snapshot;
- prior evidence indicates a cookie, comparison, directory, OLS, or dependency
  failure that the preflight is expected to detect;
- the user explicitly requests a clean run.

1. Before any run, verify that the harness implements the current scenario
   contract:
   - `ScenarioBatchesPerPhase=4` for `Full` or `1` for `MiniSet`;
   - a hard initial-batch
     `MUTATE_ALL -> WAIT_15_SECONDS -> COMPARE_ALL` barrier;
   - initial-batch-wide comparison and failure aggregation;
   - fail-fast behavior for repetitions 1, 2, and 3 in `Full` mode;
   - exhaustive harness qualification with a machine-readable zero-defect
     report.
   If any item is missing, do not run or resume ScenarioTest. Update and
   validate the harness first.
2. Perform the complete environment preflight and exhaustive harness
   qualification defined in `ScenarioTest.md`.
3. Record each check and its result plus evidence paths. Do not duplicate
   unbounded command output into local state.
4. Do not start traffic if a required preflight or qualification check fails.
5. Qualification must continue after individual harness failures and report all
   generator, value, target-class, request-planning, payload-limit, and probe
   write/read-back defects together. Never use the live scenario as an
   iterative harness-debugging loop.
6. Classify a preflight or qualification failure separately from a traffic or
   product failure.
7. Set `fullPreflightCompleted=true` only after environment preflight and the
   exhaustive qualification both pass.
8. Verify the exact organization and all required path parameters before
   launching; omission of `-Organization` is a preflight invocation defect.
9. Expect the full TDS preflight and qualification to take several minutes.
   Run them through a
   separately observable process or provide interim progress at least every
   two minutes; do not leave a long blocking command silent.
10. `-PreflightOnly` is the read-only environment preflight command; it does not
    replace the write-capable exhaustive harness qualification. A later full
   `ScenarioTest` invocation runs preflight again before creating objects; do
   not report the full run as traffic until its own preflight passes.

After a script fix, run validation that crosses the changed production seam.
For a new run, require the complete exhaustive qualification. For a resume of
the same plan-version run with an existing zero-defect `qualification.json`,
do not rerun the full preflight, qualification, or completed scenario work.
Validate the specific fix through its affected runtime seam, preserve the
checkpoint, restore `scenario-target-context.clixml`, and resume at the saved
object position. Rebuild the 21-query target context only when the cache is
missing or its plan version, organization, or forest does not match.

Restore the active batch's `scenario-plan-pNN-bNN.json` verbatim. For deletion,
resume baseline preparation using `BaselinePreparedGuids`; do not treat a
prepared or seeded GUID as a completed deletion. Require one aggregate
seed-validation barrier before any deletion mutation begins. Never select
`msExchCU` or `msExchOURoot` for deletion.

Use `-ForceFullPreflightOnResume` only when direct evidence shows the new
failure is related to preflight, environment, dependency, cookie,
comparison-runtime, configuration, or target-discovery state.

## 1A. Required scenario batch semantics

For every phase:

1. Reuse the existing ledger-owned User or Group population. Do not provision
   phase-specific replacement objects.
2. Verify the previous phase completed successfully before reusing its objects.
   Any recipient or group with an unresolved mutation or comparison failure
   must not advance to another phase.
3. The initial batch must attempt one property upsert/delete for every
   randomized object before waiting or comparing any object.
4. For the initial batch only, continue after individual mutation and
   comparison failures so every object is checked. Aggregate all initial-batch
   failures and pause once after the complete report.
5. In `Full` mode, each of repetitions 1, 2, and 3 uses the deterministic
   variable-width property set and preserves fail-fast behavior. `MiniSet`
   ends the phase after batch 0 passes.
6. During enabled repetitions 1–3, pause immediately on the first mutation failure,
   cookie timeout, comparison error, compare timeout, or terminal non-`DataSame`
   result. Do not continue merely to aggregate additional failures.
7. Never start a later batch or phase after either an aggregated initial-batch
   failure or a fail-fast repetition failure.

Apply these gates identically to all 12 phases. Before reporting or starting a
new step, prove from the checkpoint that:

- the previous mutation barrier completed;
- its comparison barrier completed successfully;
- the previous batch is recorded as passed;
- when crossing a phase boundary, every batch configured for the selected set
  mode is recorded as passed.

After a repair, resume the failed step at its saved object position. Do not
advance to a sibling scenario, later batch, or later phase, and do not repeat
objects already recorded in `CurrentBatchCompletedGuids`.

Progress reports must distinguish `mutation stage`, `15-second wait`, and
`comparison stage`, including `objects attempted/total` and
`objects terminal/total`.

Once scenario traffic has started, never summarize an active batch merely as
`traffic running` or `blocked`. Read `ScenarioState.CurrentBatch` and report:

```text
<Phase>, batch <index>, <Stage>: <ObjectsAttempted>/<ObjectCount> mutations;
<ObjectsCompared>/<ObjectsToCompare> comparisons.
```

Use `blocked` only before traffic, while environment preflight or exhaustive
qualification is preventing the run from starting.

While qualification is active, read `qualification-progress.json` and report:

```text
Qualification: <Phase>, batch <index>, object <Position>/<ObjectCount>;
overall <CompletedObjectPlans>/<TotalObjectPlans> (<PercentComplete>%);
failures found <FailureCount>.
```

Never report only `qualification.json is not complete` when the progress file
is available.

## 2. Start traffic and adaptive monitoring

Before launching, enumerate active PowerShell processes whose command line
contains `Invoke-DirectoryObjectStoreLongevity.ps1`, and correlate each PID,
start time, object prefix, organization, and run directory. Do not start a
second ScenarioTest against the same machine and organization while another is
active unless the user explicitly approves parallel traffic. Separate run
directories and prefixes prevent ledger collisions but do not isolate shared
services, cookies, configuration, comparison capacity, or tenant load.

After traffic starts:

1. Record the traffic start time and identifiers.
2. Monitor immediately, then report progress and status every 2 minutes.
   Set `trafficStartedAtUtc` from the full run's first traffic event, normally
   `Creating initial isolated test population`, not from process creation or
   the start of the full run's preflight.
3. Each report must include:
   - report timestamp in both local time with numeric UTC offset and UTC
   - traffic start time, elapsed time, time since the previous report, and next scheduled report time
   - current phase
   - traffic/job identifiers
   - completed, succeeded, failed, pending, and active counts when available
   - newly observed errors since the previous report
   - data-consistency status: `consistent`, `inconsistent`, `not checked`, or `unknown`
   - consistency-check time, scope, expected value/state, actual value/state, mismatched objects/properties, and evidence when available
   - suspected failure class, if any
   - next action
4. Continue the 2-minute interval while any script defect is suspected or while the run is unstable.
5. When at least 10 minutes have elapsed since traffic start and no script defect has been found, change the reporting interval to 5 minutes.
6. The interval change is based on elapsed traffic time, not number of reports.
7. Reset the interval to 2 minutes after a resume, a new failure, a repair, or any material status regression.
8. A user-specified interval overrides the defaults in steps 2, 5, and 7.

Use this progress-source order:

1. terminal `summary.json` and `PAUSED`;
2. `status.json` and `checkpoint.json`;
3. latest complete records and file timestamps from `events.jsonl`,
   `operations.jsonl`, `validations.jsonl`, and `scenario-details-*.jsonl`;
4. process CPU/liveness and narrowly filtered object counts during initial
   population creation.

### Bounded-memory monitoring

Every recurring monitor must use bounded memory and must never load complete
JSONL histories.

- Never use `[IO.File]::ReadAllLines`, `Get-Content -Raw`, or an equivalent
  whole-file read on `events*.jsonl`, `operations*.jsonl`,
  `validations*.jsonl`, or `scenario-details-*.jsonl`.
- Never pipe a complete JSONL file through `ConvertFrom-Json`, `Group-Object`,
  `Sort-Object`, or an in-memory collection.
- Read counters, object counts, pending validations, current phase/batch, and
  mutation/comparison `m/N` from bounded `status.json` and `checkpoint.json`.
- Prefer direct bounded file access for those state files. If TDS PowerShell
  remoting must read them, return only scalar projections and cast log-tail
  lines to `[string]`; never return raw `Get-Content` or `ConvertFrom-Json`
  objects across remoting because remoting metadata can amplify a small state
  read into gigabytes of retained `wsmprovhost` memory.
- Status, checkpoint, qualification-progress, plan, and summary files are
  atomically replaced through unique temporary paths. Readers may retry a
  transient missing-path observation, but must never modify, rename, or lock
  the published file longer than the bounded read.
- Read JSONL only when extra evidence is necessary, using a shared-read
  file stream and a tail bounded to at most 20 lines and 256 KB. Discard the
  tail after producing the report.
- Derive bootstrap counts from the checkpoint's `Contacts` and `Groups`
  collections. Do not rescan the full operations ledger on every tick.
- Query only the exact PID and required service/port state. Do not enumerate
  unrelated process details unless diagnosing a memory or liveness issue.
- Treat each TDS monitor invocation as transient. Do not leave a watcher,
  PowerShell loop, or accumulating in-memory history running on the TDS.
- After a timed-out remote monitor call, check for an attributable orphaned
  remote shell by exact PID and creation time. Terminate only the exact shell
  created by that call; never kill `wsmprovhost` processes by name or disturb
  an unattributed shell in the shared environment.
- When attribution is unclear, correlate the shell creation time with WinRM
  Operational event 91 and require its `clientIP` to match the current
  devbox's TDS VPN address before terminating the exact PID.
- Include scenario-process private bytes, monitor-process private bytes when
  observable, and host free physical memory when investigating memory health.
  Do not confuse 64-bit virtual-address reservation with committed/private
  memory.

If an existing schedule uses whole-file JSONL reads, stop and replace it with
a bounded-memory monitor before the next poll.

`Get-DirectoryObjectStoreScenarioStatus.ps1` uses `StatusIsFresh` to mean that
the status belongs to the current start/resume window. It does **not** mean that
`status.json` was updated recently. Compare `Status.UpdatedUtc` and artifact
timestamps with the current time independently.

Long initial convergence validation can append thousands of
`validations.jsonl` records without refreshing `status.json`. Treat a recently
growing validation log plus a live process as active progress. A validation-log
line is a poll attempt, not a completed object validation; never report its line
count as objects passed.

Use the execution environment's recurring schedule when available. Record the
schedule ID and exact run/PID identity, and stop the schedule when the run
becomes terminal. A detached remote test process is allowed only after its PID,
start time, run directory, and redirected output paths are verified. If no
recurring mechanism exists, provide the exact monitor command and current
status without claiming monitoring will continue.

### Monitor-process liveness and unexpected exit

The PowerShell status command may query a process that has already exited because the scenario case failed. Treat process disappearance as a terminal observation to diagnose, not as a reason to keep polling forever.

For every monitoring iteration:

1. Run the documented PowerShell status command with a bounded timeout.
2. Independently check whether the target process still exists, using its captured PID when available. Do not rely only on process name because a new process can reuse the same name.
3. Interpret outcomes explicitly:
   - process exists and status command succeeds: parse and report status normally;
   - process exists but status command times out or fails: capture command output and error, report the monitor failure, retry only within the documented bounded retry policy, then diagnose instead of looping indefinitely;
   - process no longer exists: immediately stop status polling for that PID, capture the process exit code when available, end time, last successful status, case result, and relevant logs, then classify the underlying case failure;
   - process identity changed or PID was reused: do not attach automatically; verify the new process belongs to the same run before monitoring it.
4. Never interpret `process not found`, null/empty process output, a broken PowerShell pipe, or status-command timeout as `still running`.
5. Use a watchdog based on wall-clock time and last successful monitor response. If there is no valid response within the allowed poll timeout/retry window, leave the monitoring state and enter diagnosis.
6. A failed case whose process exited must advance to `DIAGNOSE`; it must not leave the skill stuck in `MONITOR_2M` or `MONITOR_5M`.
7. Include monitor health, process liveness, PID, process start/end time, exit code if available, and last successful status time in every report.
8. Do not call the run stalled solely because `status.json` is old. Treat it as
   suspected stalled only when all relevant progress artifacts are old, process
   CPU is not advancing across observations, and no bounded child operation
   explains the quiet period.

### TDS health and sync-progress signals

Every progress report must perform the lightweight checks:

- `MSExchangeDirCacheService`, `OLS Service`, and
  `M365DirectoryProxyService`;
- listeners on ports `83` and `6092`.

Perform the heavier functional cookie/read-path checks during preflight, at
scenario batch or phase transitions when available, at least every 15 minutes
during a long quiet validation period, and immediately when progress appears
stale or a related error occurs. Do not run the expensive cookie and Get-EDI
queries every two minutes merely to populate a report.

A running service or listening port proves only liveness, not correctness.
During preflight, require the documented functional cookie reads and comparison
runtime probe.

For validation gating, use each cookie's
`WhenDirSyncLastProcessedUTC` as the primary watermark. Use `Timestamp` only as
a compatibility fallback when the last-processed property is absent or null.
Report both values when diagnosing stale progress. If server logs show cookie
writes while reads remain stale, classify the result as an Object Store
read/persistence-path discrepancy until direct evidence identifies the failing
layer.

Presence and `DirSyncFinishedFullSync=true` are preflight readiness signals, not
proof that active traffic is being processed. Correlate watermark expectations
with the operation type:

- initial contact/group creation and recipient-property mutations require the
  `Recipients` watermark to advance;
- link mutations require the `Links` watermark to advance;
- require `TenantConfig` advancement only when the run actually changed tenant
  configuration data.

Do not classify an unrelated cookie as stalled merely because it is old. Mark
sync progress degraded when the relevant watermark remains earlier than the
traffic or batch start beyond the configured convergence delay while matching
objects remain pending.

## 2A. Data-consistency checks and reporting

Every progress, repair, resume, final, and stop/repro report must state whether any data inconsistency has been detected.

1. Use only consistency checks, comparison commands, validation queries, expected-state definitions, and authoritative data sources documented in `ScenarioTest.md` or the repository. Do not invent invariants or assume that two stores must already match.
2. Report one of these exact states:
   - `consistent`: the documented consistency check ran successfully and found no mismatch within the reported scope;
   - `inconsistent`: at least one documented expected-versus-actual mismatch was found;
   - `not checked`: the consistency check has not run yet or is not applicable at this phase;
   - `unknown`: the check was attempted but could not produce a trustworthy result.
3. Never report `consistent` merely because no consistency error appeared in logs. `Consistent` requires an explicit successful check.
4. For `inconsistent`, include:
   - first detected time and most recent check time, in local time with UTC offset and UTC;
   - affected object count when the command provides it, otherwise `unknown`;
   - representative safe object identifiers;
   - source and destination/store names or aliases;
   - mismatched property names, expected values or hashes, and actual values or hashes;
   - whether the mismatch is transient, persistent, or unknown based only on repeated observed checks;
   - correlation/activity IDs and evidence paths;
   - whether traffic continues, pauses, or stops, based on `ScenarioTest.md`.
5. Redact secrets and sensitive values. Prefer safe identifiers and hashes when raw values are unnecessary.
6. Re-run a documented consistency check after a script fix, targeted stale-state cleanup, traffic resume, and before declaring success.
7. Data inconsistency is an observed condition, not automatically a script defect. Classify its cause separately using direct evidence.
8. If a process exits before the consistency check completes, report `unknown`, capture the partial evidence, and enter diagnosis. Do not silently report no inconsistency.
9. While objects are waiting for their first documented comparison, report
   `not checked`. Report `consistent` only for the objects and batch that
   explicitly returned `DataSame`. `ValidationsDeferred` and validation-log
   record counts are attempts, not evidence of consistency.

## 3. Failure classification

When a failure appears, preserve the raw error and classify it using direct evidence:

### Script defect
Examples include syntax errors, invalid arguments, broken parsing, incorrect paths, missing guards, bad retry logic, command construction errors, or behavior that contradicts the test script's documented intent.

### Preflight or stale-state issue
Examples include leftover state from the previous failed attempt, an incomplete prior cleanup, an unavailable prerequisite, or configuration that the documented preflight would have detected.

### Non-script failure
A service, product, environment, object-data, dependency, or unknown failure for which there is no evidence that the test script caused the failure.

Do not classify by guesswork. Record the command, error, timestamps, affected objects, and reasoning used for the classification.

## 4. Repair a script defect

When evidence shows a script defect:

1. Stop or pause only what `ScenarioTest.md` requires before editing. Avoid broad disruption.
2. Capture the failing command, relevant log excerpt, object identifiers, script path, and line or function involved.
3. Make the smallest safe fix. Do not combine unrelated cleanup or refactoring.
4. Show the exact diff.
5. Run the cheapest meaningful local validation first when the repository supports it.
6. Preserve validation output and update the run state.

## 5. Choose local or TDS validation

Use this decision rule:

- If a meaningful local validation completes within 2 minutes, use its result before resuming the scenario test.
- If local validation is unavailable, inconclusive, or requires more than 2 minutes, validate the fixed script in TDS using the documented TDS procedure.
- Do not wait beyond 2 minutes merely to prove that local validation is slow. Stop/cancel it safely if supported, retain its partial output, and switch to TDS.
- A syntax-only check does not count as meaningful validation when the defect depends on runtime behavior.

## 6. Resume after a script fix

For the resumed test:

1. Decide whether full or targeted preflight is required using the rules in
   [Full preflight](#1-full-preflight); never skip it unconditionally.
2. Inspect the previous failure evidence to determine whether it left stale state.
3. If cleanup is necessary, remove only state directly associated with the failed attempt, affected object, run identifier, or documented resource.
4. Before cleanup, list the exact items and why each is related.
5. After cleanup, verify that unrelated state was not changed when a verification method exists.
6. Start or resume traffic according to `ScenarioTest.md`.
7. Set reporting back to every 2 minutes and restart the 10-minute no-script-defect observation window.

Never use wildcard, tenant-wide, environment-wide, table-wide, queue-wide, or subscription-wide cleanup unless `ScenarioTest.md` explicitly requires it and the user explicitly authorized that scope.

## 7. Handle a subsequent non-script failure

If a non-script failure occurs after the repair/resume flow:

1. Check whether direct evidence ties it to a missed preflight condition or stale state.
2. If it is a preflight/stale-state issue:
   - stop or pause traffic as documented;
   - identify the exact stale state;
   - perform targeted cleanup only;
   - verify the cleanup;
   - rerun without a full preflight unless the evidence shows the full preflight itself is required.
3. If it is not related to preflight or stale state:
   - let the harness's internal failure path pause traffic when it detected the
     failure;
   - confirm the final paused or terminal status;
   - select one representative failed object;
   - produce the manual repro package below;
   - do not keep retrying automatically.

### Operator-requested cancellation

The harness currently exposes no graceful `-Stop` switch, stop file, or remote
stop command. `Stop-LongevityTraffic` is an internal failure path, not an
operator API, and manually creating `PAUSED` does not stop the process.

If the user asks to cancel an otherwise running scenario:

1. Capture the exact PID, process start time, run directory, latest checkpoint,
   status, logs, and current consistency state.
2. Explain that cancellation requires terminating the verified scenario PID
   and may leave ledger-owned objects for a later targeted cleanup or resume.
3. Obtain explicit confirmation before terminating that PID.
4. Never kill by process name, never invent a `PAUSED` marker, and never perform
   broad prefix or tenant cleanup.

## Manual repro package

For one representative failed object, report:

### Run context
- run ID and traffic/job ID
- environment and tenant aliases, with secrets redacted
- relevant build, branch, commit, package, configuration, or feature identifiers when available
- start, failure, and stop timestamps

### Object information
- object type
- safe object identifier(s)
- initial state and relevant properties
- expected state
- actual state
- why this object is representative

### Exact operations
Provide an ordered list containing:

- operation number
- timestamp
- script/function/command
- redacted arguments
- target object
- request/correlation/activity ID
- expected result
- actual result
- retry count and retry outcome

### Failure details
- exact error code and message
- stack trace or relevant log excerpt
- first-failure timestamp
- frequency and scope
- affected component/dependency
- status/response payload with secrets and personal data redacted
- links or paths to preserved logs and evidence

### Manual reproduction
List the minimum deterministic steps needed to reproduce the problem manually. Include prerequisites, setup, exact operations, validation query, expected result, and actual result. Do not include undocumented or guessed commands.

## Reporting templates

### Progress report

```text
Report time: <local ISO-8601 timestamp with UTC offset> / <UTC ISO-8601 timestamp>
• Run: <run-id>
• Process: PID <pid>, identity <verified/unverified>, <running/exited>; CPU <seconds/unknown>
• Stage: <preflight/bootstrap population/phase and batch/cleanup/terminal>
• Bootstrap: <contacts>/<target> contacts and <groups>/<target> groups created successfully
• Operations/writes: <succeeded> succeeded, <failed> failed
• Scenario batches: <completed>/<ScenarioBatchTotal>; <phase>, batch <index>, <stage>;
  mutations <attempted>/<total>; comparisons <terminal>/<total>
• Validations: <state and counts>; data consistency: <consistent/inconsistent/not checked/unknown>
• Latest progress: <latest meaningful operation or artifact activity>
• Errors: <none or concise new errors>; stderr <empty/non-empty> and terminal marker <absent/present>
• TDS health: Directory Cache=<state>, OLS=<state>, Directory Proxy=<state>; ports 83=<state> and 6092=<state>
• Side-A sync watermarks: Recipients <UTC/unknown>, Links <UTC/unknown>, TenantConfig <UTC/unknown>; delay <values/unknown>
• Monitor health: <healthy/degraded/failed>; <stall assessment>
• Report interval: <2 or 5> minutes; <reason>
```

Prefer this concise shape over dumping every tracked field. Include extra
failure, mismatch, correlation, or evidence lines only when they add actionable
information. When a value is unavailable, say `unknown` rather than omitting a
required field or inferring success.

Derive bootstrap progress from the exact run prefix and organization, not from
tenant-wide totals. During bootstrap, the operation count should equal
successfully created contacts plus groups unless an explicit retry or other
operation is recorded. Treat a mismatch as a reason to inspect the operation
ledger, not automatically as failure.

For the cadence reason, report the full run's actual traffic start event and
elapsed traffic time. Remain at two minutes until at least ten minutes after
that event; preflight duration does not count toward the observation window.

### Repair report

```text
[ScenarioTest script repair]
Defect evidence: <evidence>
Root cause: <directly supported cause>
Changed files: <paths>
Diff: <summary or patch path>
Validation path: <local or TDS>
Validation result: <pass/fail/inconclusive>
Data consistency: <consistent/inconsistent/not checked/unknown, scope, check time, and evidence>
Cleanup required: <yes/no and exact scope>
Resume decision: <decision and reason>
```

### Stop and manual repro report

```text
[ScenarioTest stopped]
Stop reason: <reason>
Traffic stop result: <result>
Representative object: <safe identifier>
Expected vs. actual: <details>
Exact failed operation: <details>
Error: <code and message>
Data consistency: <consistent/inconsistent/not checked/unknown, mismatch details, check time, and evidence>
Correlation IDs: <ids>
Manual repro steps: <ordered steps>
Evidence: <paths>
```

## Completion criteria

Mark the run complete only when one of these is true:

- the success criteria in `ScenarioTest.md` are met; or
- traffic is stopped and a complete manual repro package is produced for a non-script, non-preflight failure; or
- execution is safely blocked because a required command or prerequisite is missing, with the exact blocker and evidence reported.

At completion, provide a concise summary of preflight outcome, traffic duration, interval transitions, failures, repairs, validations, cleanups, final data-consistency status and evidence, final traffic status, changed files, and evidence locations. A run must not be declared successful unless the documented final consistency check is `consistent`, or `ScenarioTest.md` explicitly states that no consistency check applies.
