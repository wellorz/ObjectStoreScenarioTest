# Directory Object Store ScenarioTest Skill

This repository publishes one self-contained GitHub Copilot skill for running
Directory Object Store ScenarioTest workflows on TDS:

```text
.github/skills/scenario-test-runner/
```

That directory is the single source of truth. The repository root intentionally
does not contain duplicate harness, status, contract, or skill files.

## Commands

| Command | Mini reused | Mini first | Full reused | Full first |
| --- | ---: | ---: | ---: | ---: |
| `User-Upsert` | 15 min | 30 min | 70 min | 85 min |
| `Group-Upsert` | 15 min | 30 min | 85 min | 100 min |
| `User-Properties-Deletion` | 20 min | 35 min | 90 min | 105 min |
| `Group-Properties-Deletion` | 20 min | 35 min | 105 min | 120 min |
| `Run-All-Scenarios` | 35 min | 50 min | 315 min | 330 min |

Commands default to `--full`, which runs all four batches per phase. Add
`--miniSet` to run only the initial batch for each phase:

```text
User-Upsert --miniSet
Run-All-Scenarios --miniSet
```

Use `--full` explicitly when desired:

```text
Group-Upsert --full
```

Every estimate includes a mandatory 10-minute preflight estimate. A first run
also includes 15 minutes to create and validate the shared 235-contact and
267-group population. Later compatible commands reuse it. All stage estimates
are based on measured timings and rounded upward to the next five minutes.

## Install

Clone the repository:

```powershell
git clone https://github.com/wellorz/ObjectStoreScenarioTest.git
Set-Location .\ObjectStoreScenarioTest
```

The skill is automatically discoverable when Copilot CLI starts from the
repository root:

```powershell
copilot
```

Verify it inside Copilot CLI:

```text
/skills reload
/skills info scenario-test-runner
```

To make the skill available from other repositories:

```powershell
copilot skill add "$PWD\.github\skills"
```

Alternatively, copy the complete directory:

```text
.github\skills\scenario-test-runner
```

to:

```text
%USERPROFILE%\.copilot\skills\scenario-test-runner
```

Always copy the entire directory, not only `SKILL.md`.

## Use

After installation, ask Copilot to run one of the five commands, for example:

```text
User-Upsert on SG2TDSO3000036
```

The skill announces the selected scenarios, expected population, estimated
duration, automatically selected Exchange organization, generated unique
object prefix, and monitoring cadence before starting. It prefers a valid
`contoso.com` tenant and does not prompt users to choose a prefix or select
from system tenants.

For direct PowerShell use, the scripts are located at:

```text
.github\skills\scenario-test-runner\Invoke-DirectoryObjectStoreLongevity.ps1
.github\skills\scenario-test-runner\Get-DirectoryObjectStoreScenarioStatus.ps1
```

The complete operating guide is:

```text
.github\skills\scenario-test-runner\README.md
```

That guide includes the
[scenario-by-scenario LDAP operation and attribute lists](.github/skills/scenario-test-runner/README.md#ldap-operations-and-scenario-attribute-coverage),
grouped by `Set-ADObject -Replace`, `-Add`, `-Clear`, and `-Remove`.

## Prerequisites

- A dedicated Windows TDS Exchange machine.
- Microsoft `agency` and authorized Enzyme feed access for SubstrateMCP.
- `CompareAndRepairSetup.ps1` on TDS.
- Authorized `RuntimeDependencies\net472` provisioned separately.

No credentials, Exchange runtime binaries, or TDS run artifacts are stored in
this repository.

## Contributing

Edit files only under:

```text
.github\skills\scenario-test-runner\
```

Do not recreate duplicate operational files at the repository root. Keep the
skill directory self-contained so it can be shared or installed independently.
