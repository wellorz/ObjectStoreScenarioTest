# Directory Object Store ScenarioTest Contract

This document defines the comprehensive, repeatable LDAP attribute scenario
test implemented by `Invoke-DirectoryObjectStoreLongevity.ps1`. Do not alter
or interrupt an active TDS run when validating changes; use a separate run.

## Object Types

- `User` means the mail-contact recipient objects already created by the
  DOSLongevity harness. Do not substitute AD users or mailbox users.
- `Group` means the distribution-group objects already created by the harness.
- Identify objects by GUID during mutation and validation so mutable naming or
  address attributes do not break later operations.
- Create the User and Group populations once per run. Reuse the same
  ledger-owned objects in every applicable phase; never create a new population
  merely because a phase or repetition changed.
- An object may enter a later phase only after its earlier mutations explicitly
  reached `DataSame`. Because any terminal failure pauses before the next phase,
  a recipient or group with an unresolved failure is never reused in later
  traffic.

## Embedded Property Arrays

Use these embedded arrays from the script:

| Array | Symbol | Current count |
|---|---|---:|
| `UserRecipientPropertiesForUpsert` | `N_URP_U` | 235 |
| `GroupRecipientPropertiesForUpsert` | `N_GRP_U` | 267 |
| `UserLinkPropertiesForUpsert` | `N_ULP_U` | 33 |
| `GroupLinkPropertiesForUpsert` | `N_GLP_U` | 45 |
| `UserRecipientPropertiesForDeletion` | `N_URP_D` | 235 |
| `GroupRecipientPropertiesForDeletion` | `N_GRP_D` | 265 |
| `UserLinkPropertiesForDeletion` | `N_ULP_D` | 33 |
| `GroupLinkPropertiesForDeletion` | `N_GLP_D` | 44 |

Calculate counts at runtime rather than hard-coding them:

```powershell
$N_User = [Math]::Max(
    $N_URP_U,
    [Math]::Max($N_ULP_U, [Math]::Max($N_URP_D, $N_ULP_D)))

$N_Groups = [Math]::Max(
    $N_GRP_U,
    [Math]::Max($N_GLP_U, [Math]::Max($N_GRP_D, $N_GLP_D)))
```

With the current arrays, create 235 mail contacts and 267 groups.

## General Requirements

The harness supports these command subsets:

- `User-Upsert`: Pure User Recipient Upsert, Pure User Link Upsert, Mixed User Upsert.
- `Group-Upsert`: Pure Group Recipient Upsert, Pure Group Link Upsert, Mixed Group Upsert.
- `User-Properties-Deletion`: Pure User Recipient Deletion, Pure User Link Deletion, Mixed User Deletion.
- `Group-Properties-Deletion`: Pure Group Recipient Deletion, Pure Group Link Deletion, Mixed Group Deletion.
- `RunAll`: all 12 phases in canonical order.

The scenario set mode controls batches per selected phase:

- `Full` is the default and runs batch 0 plus repetitions 1-3: four batches per
  phase, 12 for a subset command, and 48 for `RunAll`.
- `MiniSet` runs only batch 0: one batch per phase, 3 for a subset command, and
  12 for `RunAll`.

Persist the command and set mode in the checkpoint and reject a resume
requested with a different command or mode. Mini-set mode preserves the full
batch-0 `MUTATE_ALL -> WAIT_15_SECONDS -> COMPARE_ALL` barrier and aggregated
failure behavior; it only omits repetitions 1-3.

1. Use a logged random seed so every run can be reproduced.
2. Shuffle object order independently for each phase and repetition.
3. Select properties without replacement for each object and batch.
4. Generate schema-valid, property-specific values. Do not use a generic
   string generator for binary, integer, Boolean, enum, SID, GUID, DN, security
   descriptor, quota, or link attributes.
5. For multivalued attributes, generate 1-5 distinct valid values while
   respecting schema limits and property invariants.
6. Link attributes must reference valid objects of the required class. Create
   and retain any policy, mailbox, database, recipient, group, or configuration
   targets required by a property-specific generator.
7. Never mutate mandatory identity attributes in a way that makes the test
   object undiscoverable. Use GUID-based lookup throughout.
8. The initial one-property coverage batch uses an explicit three-stage state
    machine: `MUTATE_ALL -> WAIT_15_SECONDS -> COMPARE_ALL`. Do not start the
    wait or any comparison until every object selected for that initial batch
    has been attempted.
   Persist live progress throughout the batch:
   `Stage`, `ObjectsAttempted`, `ObjectCount`, `ObjectsSucceeded`,
   `ObjectsFailed`, `ObjectsToCompare`, and `ObjectsCompared`. A monitor must
   be able to report `m/N` while mutation or comparison is active.
9. Only the initial coverage batch aggregates failures. Continue through its
    complete randomized object list, collect every LDAP mutation failure, then
    poll every successfully mutated object until it reaches `DataSame` or its
    configured deadline. After every object has a terminal result, emit one
    report containing every initial-batch mutation failure, cookie timeout,
    compare timeout, non-`DataSame` object, divergent property, generated value,
    and exception.
10. Repetitions 1, 2, and 3 retain fail-fast behavior. Stop the current
     repetition at the first mutation failure, cookie timeout, comparison error,
     compare timeout, or non-`DataSame` terminal result. Do not start the next
     repetition after a failure. A single immediate compare attempt is not
     sufficient.
11. Validate both recipient and link effects as applicable, with the required
    A/B cookies. Preserve the existing six-cookie and full-sync readiness
    checks.
12. Log every randomized choice and each LDAP change in JSONL. Keep logs
    bounded or rotated so individual files remain at most 4 MB.
13. "Pure" means the current mutation command touches only the named property
    family. Values left by earlier successful phases may remain.
14. Before deleting an attribute, verify that the selected value exists. If it
    is absent, seed a valid value, wait for sync, and require a `DataSame`
    baseline during a separate batch-preparation stage before `MUTATE_ALL`.
    Seed every object first, validate the seeded GUIDs together, and only then
    begin deletion mutations. Persist preparation progress separately from
    completed deletion GUIDs.
15. For multivalued deletion, randomly choose either:
    - remove one or more selected values while retaining at least one value, or
    - clear the entire attribute.
    Record which deletion mode was used.
    Never delete `msExchCU` or `msExchOURoot`; they are tenant identity anchors
    required to construct a valid Exchange organization identity.
16. Recipient and link arrays overlap on some LDAP names. In a mixed batch,
    resample or deduplicate so the same LDAP attribute is not assigned two
    conflicting operations or values in one LDAP modify request.
17. Combine compatible selected attributes into bounded LDAP Modify operations.
    Enforce documented ADWS/LDAP attribute-count and encoded-payload limits;
    split before a request reaches either limit and log why it was split.
18. Each `Full` phase consists of one initial one-property-per-object batch
    followed by three variable-width repetitions. Each `MiniSet` phase consists
    only of the initial batch.

## Coverage-Aware Initial Batch

For each phase, randomize both the object order and property order, then assign
properties cyclically. This preserves randomness while ensuring every property
is selected at least once when the object count is at least the property count.
Do not independently sample with replacement, because that can leave properties
untested.

The initial-batch mutation barrier is absolute: first attempt exactly one
property mutation for every randomized object. Only after all objects have
been attempted may the harness wait 15 seconds and validate the full batch.
Comparison must reach a terminal result for every initial-batch object and
report all failures together.

## Variable-Width Repetitions

For an object at one-based randomized position `m`, select:

```text
1 + (m % property-count)
```

unique properties from the phase's array. Complete the mutation pass, wait
15 seconds, and validate the mutated objects. Repetitions are fail-fast: stop
at the first mutation or terminal validation failure. Repeat this process three
times, reshuffling objects and property selections for every repetition.

## Universal Step and Phase Gates

Apply the same progression rule to every User, Group, Recipient-property,
Link-property, Mixed, Upsert, and Deletion scenario:

1. Finish the current mutation step for its full intended object set unless a
   repetition's fail-fast mutation error stops it.
2. Do not start comparison until the mutation step reaches its barrier.
3. Do not start the next batch/repetition until the current comparison step
   passes.
4. Do not start the next phase until every batch configured for the selected
   set mode passes.
5. If the current step fails, preserve its exact checkpoint and resume inside
   that step after the defect is fixed. Never skip ahead to another batch or
   phase, and never replay already completed objects.

The initial batch comparison reports all failures together. Repetitions 1-3
remain fail-fast at the first terminal failure, but both behaviors enforce the
same rule: a failed step blocks every later step.

## Execution Order

Run the 12 phases in exactly this order:

1. Pure User Recipient Upsert
2. Pure User Link Upsert
3. Pure Group Recipient Upsert
4. Pure Group Link Upsert
5. Mixed User Upsert
6. Mixed Group Upsert
7. Pure User Recipient Deletion
8. Pure User Link Deletion
9. Pure Group Recipient Deletion
10. Pure Group Link Deletion
11. Mixed User Deletion
12. Mixed Group Deletion

All upsert phases, including mixed upserts, must complete before any deletion
phase starts. `Full` runs the initial coverage batch and repetitions 1, 2, and
3 for 48 batches total. `MiniSet` runs only the initial coverage batch for 12
batches total.

Phase transitions reuse the existing 235 User recipients or 267 Group
recipients from the run ledger. Do not recreate, replace, or renumber objects
that passed the previous phase.

The checkpoint records the phase-plan version and batches-per-phase value.
Checkpoints from an older ScenarioTest plan must not be resumed; start a new
run instead. The prior failed preflight run generated no scenario traffic.

For each active batch, sort source objects by GUID before seeded shuffling and
persist the materialized position, object GUID, selected properties, and
required cookies in `scenario-plan-pNN-bNN.json`. Resume that exact plan rather
than rebuilding it from hashtable enumeration order.

Publish status, checkpoint, qualification-progress, plan, and summary JSON
through unique same-volume temporary files and atomic replacement. Retry only
short `IOException` replacement conflicts so a concurrent monitor read cannot
pause otherwise healthy traffic.

## Exhaustive Harness Qualification

The harness must discover generator, planner, target-selection, and command
construction defects before scenario traffic. It must provide a qualification
mode that executes the complete deterministic plan without advancing the real
scenario checkpoint.

Qualification must:

1. Materialize every phase, every batch configured for the selected set mode,
   every randomized object position, every selected property, and every
   generated value for the requested seed.
2. Validate all values against LDAP schema syntax, single/multivalue shape,
   `rangeLower`, `rangeUpper`, enum/domain restrictions, XML serialization
   contracts, GUID/SID/binary formats, and property-specific invariants.
3. Validate semantic targets, not only DN syntax. Examples:
   - `msExchCU` must target the tenant configuration unit;
   - `msExchOURoot` must target the organization root;
   - `homeMTA` must target a valid MTA;
   - policy GUID-string properties must contain valid policy object GUIDs;
   - mailbox, database, policy, recipient, group, server, and computer links
     must target objects of the required class and tenant.
4. Exercise the real request planner and prove every AD read and LDAP Modify is
   split below supported attribute-count and encoded-payload limits.
5. Use isolated disposable User and Group probe objects to perform representative
   LDAP writes and read-backs for every distinct property/value shape. Restore or
   delete only those probe objects afterward.
6. Continue qualification after an individual property fails. Aggregate every
   failure by phase, batch, position, property, generated value, target, command,
   and exception, then fail once with the complete defect list.
7. Produce a machine-readable qualification report. Scenario traffic must not
   start unless that report contains zero harness defects.
8. Publish `qualification-progress.json` while the deterministic plan is being
   checked. It must include current phase, batch, object position, batch object
   count, completed object-plans, total object-plans, percentage, generated
   selection/value counts, and failures found so far. Monitoring must report
   both batch `m/N` and overall `m/N`.

A syntax-only parse, one representative generated value, or one comparison
probe is not sufficient qualification for a new run.

For a resume of the same plan-version checkpoint, reuse the run directory's
existing zero-defect `qualification.json`. Do not rerun the full environment
preflight, qualification visits, completed scenario batches, or completed
object mutations. Validate the specific script fix through its affected
runtime seam, restore the persisted runtime target context, and continue from
the saved object position. Build and persist target context only when no valid
same-plan cache exists.

Run the full preflight on resume only when direct evidence ties the failure to
preflight, environment, dependency, cookie, comparison-runtime, configuration,
or target-discovery state. The operator can explicitly request this with
`-ForceFullPreflightOnResume`.

For a read-only environment validation, run ScenarioTest with `-PreflightOnly`. This
loads the Windows PowerShell Exchange snap-in, resolves the forest, validates
the six A/B Object Store sync cookies and compare cookies, checks schema/value
prerequisites, performs one non-uploading comparison runtime probe, and exits
before creating test objects or starting traffic. Copy the harness's
`RuntimeDependencies\net472` folder to every TDS box with the script. The
preflight loads `Microsoft.Exchange.Directory.ChaosTest.dll` from that bundle
when the TDS build does not install its .NET Framework build under `V15\Bin`.
The preflight also rejects AD-owned operational attributes in upsert arrays.
`objectCategory`, for example, is readable in schema metadata but AD rejects
direct replacement with `ADIllegalModifyOperationException`.
The sync-cookie read first warms the local Exchange directory context with
`Get-AccountPartition`, then retries transient cookie-query failures up to
three times while recording inner-exception details. A persistent query failure
stops preflight; it is not reported as a missing-cookie configuration problem.
Only the six `Recipients`, `Links`, and `TenantConfig` cookies for sides A and B
are required; a Training-side cookie is not required.
Each compare-cookie read runs in a bounded Windows PowerShell child process
(`CompareCookieReadTimeoutSeconds`, default 30 seconds). The child uses
`CompareCookieHelper` and unwraps task results with `GetAwaiter().GetResult()`;
a timeout or helper failure stops preflight with diagnostics.

## Pure Phase Definitions

The eight pure phases use these definitions:

1. **Pure User Recipient Upsert**
   - Array: `UserRecipientPropertiesForUpsert`
   - Width: `1 + (m % N_URP_U)`
   - Operation: add or replace valid values.

2. **Pure User Link Upsert**
   - Array: `UserLinkPropertiesForUpsert`
   - Width: `1 + (m % N_ULP_U)`
   - Operation: add or replace valid link values.

3. **Pure Group Recipient Upsert**
   - Array: `GroupRecipientPropertiesForUpsert`
   - Width: `1 + (m % N_GRP_U)`
   - Operation: add or replace valid values.

4. **Pure Group Link Upsert**
   - Array: `GroupLinkPropertiesForUpsert`
   - Width: `1 + (m % N_GLP_U)`
   - Operation: add or replace valid link values.

5. **Pure User Recipient Deletion**
   - Array: `UserRecipientPropertiesForDeletion`
   - Width: `1 + (m % N_URP_D)`
   - Operation: remove selected values or clear the attribute.

6. **Pure User Link Deletion**
   - Array: `UserLinkPropertiesForDeletion`
   - Width: `1 + (m % N_ULP_D)`
   - Operation: remove selected link values or clear the link attribute.
   - Do not use the upsert array or perform an upsert in this phase.

7. **Pure Group Recipient Deletion**
   - Array: `GroupRecipientPropertiesForDeletion`
   - Width: `1 + (m % N_GRP_D)`
   - Operation: remove selected values or clear the attribute.

8. **Pure Group Link Deletion**
   - Array: `GroupLinkPropertiesForDeletion`
   - Width: `1 + (m % N_GLP_D)`
   - Operation: remove selected link values or clear the link attribute.
   - Do not use the upsert array or perform an upsert in this phase.

## Mixed Phase Definitions

Run these four phases. Each object must receive both recipient-property and
link-property changes in the same logical batch.

1. **Mixed User Upsert**
   - Recipient width: `1 + (m % N_URP_U)`
   - Link width: `1 + (m % N_ULP_U)`
   - Arrays: `UserRecipientPropertiesForUpsert` and
     `UserLinkPropertiesForUpsert`
   - Add or replace valid values.

2. **Mixed Group Upsert**
   - Recipient width: `1 + (m % N_GRP_U)`
   - Link width: `1 + (m % N_GLP_U)`
   - Arrays: `GroupRecipientPropertiesForUpsert` and
     `GroupLinkPropertiesForUpsert`
   - Add or replace valid values.

3. **Mixed User Deletion**
   - Recipient width: `1 + (m % N_URP_D)`
   - Link width: `1 + (m % N_ULP_D)`
   - Arrays: `UserRecipientPropertiesForDeletion` and
     `UserLinkPropertiesForDeletion`
   - Remove selected values or clear attributes. Do not upsert.

4. **Mixed Group Deletion**
   - Recipient width: `1 + (m % N_GRP_D)`
   - Link width: `1 + (m % N_GLP_D)`
   - Arrays: `GroupRecipientPropertiesForDeletion` and
     `GroupLinkPropertiesForDeletion`
   - Remove selected values or clear attributes. Do not upsert.

For the initial mixed batch, select at least one distinct recipient property and
one distinct link property for every object. For the three variable-width
repetitions, combine the selected recipient and link mutations into the fewest
bounded, valid LDAP Modify requests.

## Ranged-Link Validation

When a genuine `msExchMultiMailboxDatabasesLink` mutation occurs:

- wait for the required Object Store sync-cookie watermarks;
- poll AD-to-Object Store comparison until the object returns `DataSame`;
- fail on timeout or any persistent base/link divergence;
- do not require implementation-specific sync log messages.

Internal branch names and log text may change without changing the externally
observable synchronization contract.

## Completion Criteria

The scenario passes only when:

- exhaustive harness qualification completes with zero defects;
- all 12 phases complete their initial batch and three repetitions;
- every attempted LDAP operation succeeds;
- every mutated object eventually validates as `DataSame`;
- no consistency divergence, compare timeout, relevant process crash, or
  service failure occurs;
- all six sync cookies remain present and full-sync complete;
- `SkipNonMaterialRecipientChangeEnabled` remains at the requested test value;
- OLS and Directory Cache remain running;
- ranged-link mutations reach `DataSame` on the required sync sides;
- cleanup removes every ledger-owned mail contact, group, and supporting target
  object created by the run.

Produce a final report containing object counts, per-phase operations, every
attribute exercised, value/deletion modes, compare totals, `DataSame` totals,
divergences, ranged-mutation counts, failures, service/crash health, random
seed, elapsed time, and cleanup results. Separate product failures from harness,
environment, and invalid-test-data failures.
