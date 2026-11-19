# Application_2 — Infrastructure as Code

Bicep (wrapping public Azure Verified Modules where they fit) plus an Azure DevOps YAML pipeline
that deploys an Azure Analysis Services server, its backup storage, and an Automation Account
with runbooks that pause and start the server.

## What gets deployed

| Resource | Notes |
|---|---|
| Resource group | `rg-<app>-<env>-<region>` |
| Storage account | Analysis Services backups, in the `aas-backups` container. Cool tier, soft delete on, anonymous access off |
| Analysis Services server | SKU per environment, admins and firewall rules from the param file, backups wired to the storage container |
| Automation Account | Basic SKU, local auth off, system-assigned identity, `AnalysisServerResourceId` variable |
| PowerShell 7.4 runtime environment | `PowerShell-74`, default Az package |
| Runbook `Suspend-AnalysisServer` | Pauses the server. Linked to the daily 6PM schedule in dev, test and uat |
| Runbook `Resume-AnalysisServer` | Starts the server. No schedule: run it ad hoc |
| Schedule `Daily-6PM-Pause` | Every day at 18:00 Australia/Sydney (follows daylight saving). Not created in prod, which runs 24/7 |

### RBAC (applied after the main resources)

| Identity | Scope | Role |
|---|---|---|
| Automation Account | Analysis Services server | Contributor |

## Layout

```
Application_2/
├── bicepconfig.json                    linter rules (errors fail the pipeline)
├── infra/
│   ├── main.bicep                      subscription-scope orchestrator
│   └── modules/                        one module per resource type
├── environments/{dev,test,uat,prod}/   <env>.bicepparam
├── runbooks/                           runbook scripts (file name = runbook name)
└── pipelines/
    ├── azure-pipeline.yaml             Validation -> What-If -> Deploy
    └── scripts/publish-runbooks.sh     uploads/publishes runbooks, links the schedule
```

## AVM usage

| Module | Source |
|---|---|
| `resource-group.bicep` | `avm/res/resources/resource-group:0.4.4` |
| `storage-account.bicep` | `avm/res/storage/storage-account:0.33.2` |
| `automation-account.bicep` | `avm/res/automation/automation-account:0.19.4` (account, variable, schedule) |
| `analysis-server.bicep` | Native. AVM `analysis-services/server:0.4.0` can't set server admins or the backup container, and defaults to an allow-all firewall |
| `automation-runbooks.bicep` | Native. The AVM automation module can't create a PowerShell 7.4 runtime environment or attach runbooks to one. PowerShell 7.1/7.2 are out of support |
| `role-assignments.bicep` | Native role assignment, same pattern as Application_1 |

## How the runbooks get their code

ARM can't hold runbook script content, and a schedule can only be linked to a published
runbook. So the Deploy stage runs in two steps:

1. `az deployment sub create`: creates everything, including empty runbooks and the schedule,
   then RBAC.
2. `pipelines/scripts/publish-runbooks.sh`: uploads `runbooks/<name>.ps1` into each runbook,
   publishes it, and links `Suspend-AnalysisServer` to `Daily-6PM-Pause` if that link doesn't
   exist yet. Safe to re-run.

The runbooks use the Analysis Services REST API through `Invoke-AzRestMethod`, so they need no
modules beyond the default Az package. They read the server from the `AnalysisServerResourceId`
Automation variable, or take `-ServerResourceId` as a parameter.

## Schedule start time

An Automation schedule's first run must be in the future and must carry the right UTC offset
for 6PM local time. The pipeline calculates the next 6PM in Australia/Sydney (with daylight
saving) and passes it in the `PAUSE_SCHEDULE_START` environment variable, which the dev/test/uat
param files read with `readEnvironmentVariable()`. The time zone appears in two places: the
`pauseTimeZone` pipeline variable and `pauseScheduleTimeZone` in the param files. Keep them the same.

## One-time setup

1. **Fill in the param files.** Replace the `<placeholder>` values in
   `environments/*/*.bicepparam`, especially `analysisServerAdministrators` (at least one admin
   is required). Add firewall rules if clients connect from outside Power BI.
2. **Service connections.** Create `sc-application2-dev`, `-test`, `-uat` and `-prod` as Azure
   Resource Manager connections using workload identity federation.
3. **Permissions for each service connection's identity (target subscription):**
   - **Contributor**, which creates the resource group and resources and also covers runbook
     publishing
   - **Role Based Access Control Administrator**, conditioned to the Contributor role (for the
     Automation Account's role assignment)
4. **Azure DevOps environments.** Create `application2-dev`, `-test`, `-uat` and `-prod`, with
   approval checks at least on uat and prod.
5. **Pipeline.** Create a pipeline from `Application_2/pipelines/azure-pipeline.yaml` and run it
   manually, choosing the environment.

## Run locally (Linux/WSL)

```bash
export PAUSE_SCHEDULE_START=$(TZ=Australia/Sydney date -d "$(TZ=Australia/Sydney date -d '+1 day' +%F) 18:00" +%Y-%m-%dT%H:%M:%S%:z)
az deployment sub what-if --location australiaeast --template-file infra/main.bicep --parameters environments/dev/dev.bicepparam
```

## Things to know

- **Backup storage needs shared keys and a public endpoint.** Analysis Services writes backups
  with a SAS URI (no managed identity support for backups). The SAS is generated in
  `analysis-server.bicep`, scoped to the backup container, and valid for 1 year from each
  deployment. Redeploy at least yearly, or backups stop working when it expires. To narrow the
  storage firewall, set `backupStorageAllowedIpRanges` to the Analysis Services region's IP range.
- **Deploying to a paused server.** If a deployment fails because the server is paused, run
  `Resume-AnalysisServer` first, then re-run the pipeline.
- **SKU tiers can't be downgraded.** Dev uses D1 (Developer), test and uat use S0, prod uses S1.
  You can move up a tier, but not back down without recreating the server.
- **The 6PM run in dev, test and uat pauses whatever is running**, including processing jobs.
  Start the server again with `Resume-AnalysisServer`, which you can run from the portal or with
  `Start-AzAutomationRunbook`.
