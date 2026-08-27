# Directory Object Store Scenario Test Implementation Prompt

Update `Invoke-DirectoryObjectStoreLongevity.ps1` to add a comprehensive,
repeatable LDAP attribute scenario test. Do not commit or push repository
changes. Do not alter or interrupt an active TDS run; start a separate run for
this scenario.

## Object Types

- `User` means the mail-contact recipient objects already created by the
  DOSLongevity harness. Do not substitute AD users or mailbox users.
- `Group` means the distribution-group objects already created by the harness.
- Identify objects by GUID during mutation and validation so mutable naming or
  address attributes do not break later operations.

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
8. Treat an LDAP mutation failure, invalid generated value, sync failure,
   compare timeout, or non-`DataSame` result as a test failure. Stop immediately
   and report the object, phase, repetition, attributes, generated values,
   operation, exception, and compare result.
9. After each batch, wait 15 seconds before starting validation. Then poll the
   Compare Engine until all mutated objects return `DataSame` or the configured
   validation timeout expires. A single immediate compare attempt is not
   sufficient.
10. Validate both recipient and link effects as applicable, with the required
    A/B cookies. Preserve the existing six-cookie and full-sync readiness
    checks.
11. Log every randomized choice and each LDAP change in JSONL. Keep logs
    bounded or rotated so individual files remain at most 4 MB.
12. "Pure" means the current mutation command touches only the named property
    family. Values left by earlier successful phases may remain.
13. Before deleting an attribute, verify that the selected value exists. If it
    is absent, seed a valid value, wait for sync, and require a `DataSame`
    baseline before performing and validating the deletion.
14. For multivalued deletion, randomly choose either:
    - remove one or more selected values while retaining at least one value, or
    - clear the entire attribute.
    Record which deletion mode was used.
15. Recipient and link arrays overlap on some LDAP names. In a mixed batch,
    resample or deduplicate so the same LDAP attribute is not assigned two
    conflicting operations or values in one LDAP modify request.
16. Combine as many compatible selected attributes as possible into one LDAP
    Modify operation. If schema or command semantics require multiple
    operations, use the minimum number and log why the batch was split.
17. Each phase consists of one initial one-property-per-object batch followed
    by two variable-width repetitions, for three batches per phase.

## Coverage-Aware Initial Batch

For each phase, randomize both the object order and property order, then assign
properties cyclically. This preserves randomness while ensuring every property
is selected at least once when the object count is at least the property count.
Do not independently sample with replacement, because that can leave properties
untested.

After mutating all objects in the initial batch, wait 15 seconds and validate
the full batch.

## Variable-Width Repetitions

For an object at one-based randomized position `m`, select:

```text
1 + (m % property-count)
```

unique properties from the phase's array. Perform the batch, wait 15 seconds,
and validate all mutated objects. Repeat this process two times, reshuffling
objects and property selections for every repetition.

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
phase starts. Each phase has exactly three batches: the initial coverage batch,
repetition 1, and repetition 2, for 36 batches total.

The checkpoint records the phase-plan version and batches-per-phase value.
Checkpoints from an older ScenarioTest plan must not be resumed; start a new
run instead. The prior failed preflight run generated no scenario traffic.

For a read-only live validation, run ScenarioTest with `-PreflightOnly`. This
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
one distinct link property for every object. For the two variable-width
repetitions, combine the selected recipient and link mutations into the fewest
valid LDAP Modify requests.

## Ranged-Link Telemetry

When a genuine `msExchMultiMailboxDatabasesLink` mutation occurs:

- require `Found RecipientChange.MaterialRangedAttr.` telemetry for both sync
  sides;
- read the four lexically newest Object Store sync log files using
  `FileStream(Open, Read, FileShare.ReadWrite | FileShare.Delete)`;
- do not filter candidate files by `LastWriteTimeUtc`;
- do not require telemetry for a no-op mutation.

## Completion Criteria

The scenario passes only when:

- all 12 phases complete their initial batch and two repetitions;
- every attempted LDAP operation succeeds;
- every mutated object eventually validates as `DataSame`;
- no consistency divergence, compare timeout, relevant process crash, or
  service failure occurs;
- all six sync cookies remain present and full-sync complete;
- `SkipNonMaterialRecipientChangeEnabled` remains at the requested test value;
- OLS and Directory Cache remain running;
- ranged-link mutations have the required A/B telemetry;
- cleanup removes every ledger-owned mail contact, group, and supporting target
  object created by the run.

Produce a final report containing object counts, per-phase operations, every
attribute exercised, value/deletion modes, compare totals, `DataSame` totals,
divergences, ranged telemetry evidence, failures, service/crash health, random
seed, elapsed time, and cleanup results. Separate product failures from harness,
environment, and invalid-test-data failures.
