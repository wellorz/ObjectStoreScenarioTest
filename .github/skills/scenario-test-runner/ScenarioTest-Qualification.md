# Directory Object Store ScenarioTest Qualification Contract

This document is a required companion to `ScenarioTest.md`. It defines the
qualification, preflight, and resume requirements that apply before scenario
traffic starts.

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

For a read-only environment validation, run ScenarioTest with `-PreflightOnly`.
This loads the Windows PowerShell Exchange snap-in, resolves the forest,
validates the six A/B Object Store sync cookies and compare cookies, checks
schema/value prerequisites, performs one non-uploading comparison runtime
probe, and exits before creating test objects or starting traffic. Copy the
harness's `RuntimeDependencies\net472` folder to every TDS box with the script.
The preflight loads `Microsoft.Exchange.Directory.ChaosTest.dll` from that
bundle when the TDS build does not install its .NET Framework build under
`V15\Bin`. The preflight also rejects AD-owned operational attributes in
upsert arrays. `objectCategory`, for example, is readable in schema metadata
but AD rejects direct replacement with `ADIllegalModifyOperationException`.
The sync-cookie read first warms the local Exchange directory context with
`Get-AccountPartition`, then retries transient cookie-query failures up to
three times while recording inner-exception details. A persistent query
failure stops preflight; it is not reported as a missing-cookie configuration
problem. Only the six `Recipients`, `Links`, and `TenantConfig` cookies for
sides A and B are required; a Training-side cookie is not required.
Each compare-cookie read runs in a bounded Windows PowerShell child process
(`CompareCookieReadTimeoutSeconds`, default 30 seconds). The child uses
`CompareCookieHelper` and unwraps task results with `GetAwaiter().GetResult()`;
a timeout or helper failure stops preflight with diagnostics.
