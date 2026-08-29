# Directory Object Store TDS longevity scenario

`Invoke-DirectoryObjectStoreLongevity.ps1` generates sustained recipient and link traffic on an isolated TDS Exchange box and validates AD against L2/Object Store.

## Attribute-coverage workload

`AttributeCoverage` is the default workload mode. It:

1. Creates `CoverageRecipientCount` mail contacts and `CoverageGroupCount` distribution groups.
2. Builds a safe, data-driven attribute catalog for each object type.
3. Randomizes the catalog independently for every object.
4. Upserts one remaining attribute per object in each round.
5. Waits for the recipient sync cookie and requires Compare Engine `DataSame` for every mutated object before starting the next round.
6. Repeats until every catalogued attribute has been upserted on every applicable object.
7. Randomizes the catalog again and clears one attribute per object per round, with the same Compare Engine gate, until every clearable value has been removed.

The recipient catalog includes `msExchMultiMailboxDatabasesLink`. The harness writes its
DN-string value using `Set-ADObject`, validates both ranged add and ranged delete changes,
and requires `RecipientChange.MaterialRangedAttr` telemetry. Missing telemetry or any
AD/Object Store divergence pauses the run with diagnostics.

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode AttributeCoverage `
    -CoverageRecipientCount 100 `
    -CoverageGroupCount 50 `
    -Organization <test-organization> `
    -ObjectPrefix DOSAttributes `
    -ConfigureEnvironment `
    -CleanupOnSuccess
```

Each object receives at most one mutation per round. Comparisons are batched, but every
result must be `DataSame`; an object is never mutated again before its previous mutation
has converged and passed comparison.

## Time-based longevity workload

Use `-WorkloadMode Longevity` for the fixed production-shaped mix:

| Operation | Weight |
| --- | ---: |
| Create mail contact | 12% |
| Update mail contact | 20% |
| Remove unlinked mail contact | 6% |
| Create distribution group | 6% |
| Update distribution group | 8% |
| Remove distribution group | 3% |
| Add group membership link | 15% |
| Remove group membership link | 10% |
| Read recipient | 12% |
| Read group membership | 8% |

Mail contacts are used instead of mailboxes so the scenario never creates or stores credentials.

Every mutation queues an AD-to-Object Store comparison after the configured convergence delay. Deletions are checked from AD and then through the OS-to-AD comparison path. Any unexpected command failure, comparison failure, or convergence timeout atomically pauses traffic and writes diagnostics.

## Prerequisites

- Run from an elevated Exchange Management Shell on a dedicated TDS Exchange box.
- `MSExchangeDirCacheService` must be installed and running.
- The Substrate enlistment containing `CompareAndRepairSetup.ps1` must be available at the default path, or pass `-CompareSetupScript`.
- Copy the `RuntimeDependencies\net472` folder with the harness. ScenarioTest loads
  `Microsoft.Exchange.Directory.ChaosTest.dll` from this bundle when the TDS build does
  not install the .NET Framework binary under `V15\Bin`.
- Use a dedicated test organization when possible. Every created object has the supplied `-ObjectPrefix`, but cleanup uses the run ledger rather than a broad prefix search.

ScenarioTest preflight invokes one read-only AD-to-Object Store comparison with
`-SkipUploadingDivergence`. This validates the same comparison runtime used after
bootstrap, including transitive assembly loading, before any test objects are created.
It also rejects AD-owned operational attributes such as `objectCategory` if they
are accidentally added to an upsert property array.

Before ScenarioTest traffic, run the exhaustive harness qualification required
by `ScenarioTest.md`. It materializes the complete deterministic 48-batch plan,
validates every generated value and semantic target, exercises bounded ADWS and
LDAP request planning, and aggregates all probe-write defects into one report.
Do not use the live scenario to discover generator defects one at a time.
During deterministic qualification, `qualification-progress.json` exposes the
current phase, batch, object `m/N`, overall object-plan `m/N`, percentage, and
failure count for monitoring.

When resuming the same plan-version run, the harness reuses its existing
zero-defect `qualification.json` and checkpoint. By default it skips the full
preflight and does not repeat completed qualification visits, batches, or
object mutations. Use `-ForceFullPreflightOnResume` only for a failure proven
to involve preflight or environment state.

The run also persists `scenario-target-context.clixml`. A matching resume
restores this cache instead of repeating the 21 isolated Exchange/AD target
queries, each of which otherwise starts a fresh Windows PowerShell child.

Each active scenario batch persists its deterministic object/property mapping
in `scenario-plan-pNN-bNN.json`. Deletion batches first prepare and seed every
object, validate all seeded GUIDs at one barrier, and then execute
`MUTATE_ALL`. Preparation progress is checkpointed independently from completed
deletions. Tenant identity anchors `msExchCU` and `msExchOURoot` are never
selected for deletion.

Monitored JSON snapshots use unique temporary files and atomic same-volume
replacement with bounded retry. Concurrent reads therefore see a complete old
or new snapshot without racing the scenario writer.

The initial ScenarioTest coverage batch has a strict barrier: attempt one
property mutation for every randomized object, wait 15 seconds, then compare
every successfully mutated object and report all failures together.
Repetitions 1–3 retain fail-fast behavior.

ScenarioTest creates its 235 mail contacts and 267 distribution groups once,
then reuses those same ledger-owned objects across all applicable phases.
Objects advance only after the previous phase passed comparison; failed objects
are not replaced with newly provisioned objects.

The mutation/comparison barrier applies to every scenario and phase. A later
batch starts only after the current batch passes comparison, and a later phase
starts only after all four batches of the current phase pass. Repairs resume
the failed step at its saved object position without replaying completed
objects or skipping forward.

During an active batch, `status.json` and `checkpoint.json` expose the current
stage plus live `ObjectsAttempted/ObjectCount` and
`ObjectsCompared/ObjectsToCompare` counters. Monitors should report these as
`m/N` progress rather than only saying that scenario traffic is running.

For monitoring, use `Get-DirectoryObjectStoreScenarioStatus.ps1`. The harness
atomically refreshes the bounded `status.json` file at every checkpoint and on
terminal completion, so a reporter does not need to parse growing JSONL logs.
If the expected PID exits, the monitor reads `summary.json`, the `PAUSED` marker,
and only the last eight event/error lines to report the terminal result promptly.

## Dry run

Exercises scheduling, checkpointing, random traffic selection, validation queues, and cleanup without changing AD:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -DurationHours 0.01 `
    -OperationsPerSecond 5 `
    -InitialRecipientCount 5 `
    -InitialGroupCount 2 `
    -WhatIfTraffic `
    -CleanupOnSuccess
```

## One-hour TDS shakedown

The first real run should be short:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode Longevity `
    -DurationHours 1 `
    -OperationsPerSecond 0.5 `
    -Organization <test-organization> `
    -ObjectPrefix DOSShake `
    -ConfigureEnvironment
```

`-ConfigureEnvironment` creates/checks sync cookies, enables the redundant-alias flight on both TDS variants, disables recent-ETag compare suppression, and restarts `MSExchangeDirCacheService`.

If the box only has the forest-wide organization, use `-SkipDeletionOperations`. Deletion
validation requires a tenant organization ID; this switch replaces delete traffic with updates
while retaining recipient and group-link coverage.

## 84-hour run

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -WorkloadMode Longevity `
    -DurationHours 84 `
    -OperationsPerSecond 1 `
    -InitialRecipientCount 50 `
    -InitialGroupCount 10 `
    -MaximumRecipientCount 500 `
    -MaximumGroupCount 100 `
    -ConvergenceDelaySeconds 300 `
    -ValidationTimeoutSeconds 1800 `
    -Organization <test-organization> `
    -ObjectPrefix DOS84H `
    -ConfigureEnvironment
```

The requested rate is a target. Exchange cmdlets and comparison calls are synchronous, so the summary records the actual achieved operations per second.
`DurationHours` measures the traffic window after environment setup and initial-object creation complete.

Each run writes both machine-readable `operations.jsonl` and a human-readable `operations.log`.
The text log uses this format:

```text
[2026/8/23 11:26:00.013] [DOS84H-g-example] [AddGroupMember] [Member=DOS84H-c-example] [Success]
```

## Failure behavior

For the initial coverage batch, the script completes full mutation and
comparison accounting and reports all failures together. For repetitions 1–3,
it pauses on the first failure. In either case it creates:

- `PAUSED`
- `failure-<timestamp>\failure.json`
- service state
- Object Store sync-cookie state
- an inventory of recent Directory logs
- `operations.jsonl`
- `validations.jsonl`
- `checkpoint.json`
- `summary.json`

The random seed and operation history allow deterministic workload replay.

## Resume

After investigating and correcting an environmental issue, resume the ledger:

```powershell
.\Invoke-DirectoryObjectStoreLongevity.ps1 `
    -ResumeRunDirectory "<run-directory>" `
    -DurationHours 12 `
    -OperationsPerSecond 1 `
    -Organization <test-organization>
```

Remove the `PAUSED` marker only after preserving the failure bundle. Resuming does not erase prior logs.

## Cleanup

Pass `-CleanupOnSuccess` to delete only objects recorded in the run ledger. Objects are intentionally preserved after failure for investigation.
