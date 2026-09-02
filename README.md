# Directory Object Store ScenarioTest Skill

This repository publishes one self-contained GitHub Copilot skill for running
Directory Object Store ScenarioTest workflows on TDS:

```text
.github/skills/scenario-test-runner/
```

That directory is the single source of truth. The repository root intentionally
does not contain duplicate harness, status, contract, or skill files.

## Commands

| Command | Scenarios | `--miniSet` scenario | `--full` scenario |
| --- | --- | ---: | ---: |
| `User-Upsert` | Pure User Recipient Upsert, Pure User Link Upsert, Mixed User Upsert | 5 minutes | 60 minutes |
| `Group-Upsert` | Pure Group Recipient Upsert, Pure Group Link Upsert, Mixed Group Upsert | 5 minutes | 75 minutes |
| `User-Properties-Deletion` | Pure User Recipient Deletion, Pure User Link Deletion, Mixed User Deletion | 10 minutes | 80 minutes |
| `Group-Properties-Deletion` | Pure Group Recipient Deletion, Pure Group Link Deletion, Mixed Group Deletion | 10 minutes | 95 minutes |
| `Run-All-OBScenarios` | All 12 scenarios in canonical order | 30 minutes | 305 minutes |

`RunAll` and `Run-All-Scenarios` are legacy persisted names supported only
when resuming older runs. Use `Run-All-OBScenarios` for every new run.

Commands default to `--full`, which runs all four batches per phase. Add
`--miniSet` to run only the initial batch for each phase:

```text
User-Upsert --miniSet
Run-All-OBScenarios --miniSet
```

Use `--full` explicitly when desired:

```text
Group-Upsert --full
```

The command table shows scenario execution time only. Every new command also
runs mandatory preflight and exhaustive qualification, estimated at 10
minutes. When no compatible shared population exists, add 15 minutes to create
and validate the complete population of 237 contacts and 269 groups.

Total estimates, including those stages:

| Command | Mini-set, reused population | Mini-set, new population | Full, reused population | Full, new population |
| --- | ---: | ---: | ---: | ---: |
| `User-Upsert` | 15 min | 30 min | 70 min | 85 min |
| `Group-Upsert` | 15 min | 30 min | 85 min | 100 min |
| `User-Properties-Deletion` | 20 min | 35 min | 90 min | 105 min |
| `Group-Properties-Deletion` | 20 min | 35 min | 105 min | 120 min |
| `Run-All-OBScenarios` | 40 min | 55 min | 315 min | 330 min |

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
duration, automatically selected Exchange organization, resolved object
prefix, and monitoring cadence before starting.

It reuses the newest compatible successful shared population and its exact
object prefix when possible. Otherwise, it creates the complete shared
population and generates a prefix from the command, UTC timestamp, and a
six-character GUID suffix.

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
- Microsoft `agency` and authorized Enzyme feed access when using
  SubstrateMCP for Copilot-driven remote execution.
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
