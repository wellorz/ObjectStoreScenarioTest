# Directory Object Store ScenarioTest Skill

This repository publishes one self-contained GitHub Copilot skill for running
Directory Object Store ScenarioTest workflows on TDS:

```text
.github/skills/scenario-test-runner/
```

That directory is the single source of truth. The repository root intentionally
does not contain duplicate harness, status, contract, or skill files.

## Commands

| Command | Scenarios | `--miniSet` | `--full` |
| --- | --- | ---: | ---: |
| `User-Upsert` | Pure User Recipient Upsert, Pure User Link Upsert, Mixed User Upsert | about 5 minutes | about 60 minutes |
| `Group-Upsert` | Pure Group Recipient Upsert, Pure Group Link Upsert, Mixed Group Upsert | about 5 minutes | about 75 minutes |
| `User-Properties-Deletion` | Pure User Recipient Deletion, Pure User Link Deletion, Mixed User Deletion | about 10 minutes | about 80 minutes |
| `Group-Properties-Deletion` | Pure Group Recipient Deletion, Pure Group Link Deletion, Mixed Group Deletion | about 10 minutes | about 95 minutes |
| `RunAll` | All 12 scenarios | about 25 minutes | about 305 minutes |

Commands default to `--full`, which runs all four batches per phase. Add
`--miniSet` to run only the initial batch for each phase:

```text
User-Upsert --miniSet
RunAll --miniSet
```

Use `--full` explicitly when desired:

```text
Group-Upsert --full
```

Estimates are based on the measured batch timings from a completed full run and
are rounded upward to the next five minutes.

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
User-Upsert on SG2TDSO3000036 for contoso.com
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
