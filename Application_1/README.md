# Application_1 — Infrastructure as Code

Bicep (wrapping public Azure Verified Modules) plus an Azure DevOps YAML pipeline that deploys a
privately networked Web API and Function App with their data services.

## What gets deployed

| Resource | Notes |
|---|---|
| Resource group | `rg-<app>-<env>-<region>` |
| 2 subnets in an **existing** VNet (other resource group) | `snet-pe` for private endpoint NICs, `snet-int` delegated to `Microsoft.Web/serverFarms` |
| Application Insights | Workspace-based, linked to the central Log Analytics workspace |
| App Configuration | Standard SKU, local auth off, public access off, private endpoint |
| App Service Plan | Linux Premium v3, shared by the Web API and the Function App |
| Web API | Linux, system-assigned identity, VNet integration, public access off, private endpoint |
| Function App | Linux, on the shared plan, identity-based host storage, VNet integration, private endpoint |
| Function host storage | Shared keys off, public access off, private endpoints for blob/queue/table |
| Data storage | Shared keys off, public access off, private endpoint for blob |
| Key Vault | RBAC, purge protection, public access off, private endpoint |

Each private endpoint creates its own network interface (named `nic-pe-<resource>[-<service>]`)
in `snet-pe` and registers in the matching **existing central** privatelink DNS zone.

### RBAC

| Identity | Scope | Role |
|---|---|---|
| Web API | App Configuration | App Configuration Data Reader |
| Web API | Data storage | Storage Blob Data Contributor |
| Function App | Data storage | Storage Blob Data Contributor |
| Function App | Host storage | Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor |

## Layout

```
Application_1/
├── bicepconfig.json               linter rules (errors fail the pipeline)
├── infra/
│   ├── main.bicep                 subscription-scope orchestrator
│   └── modules/                   one wrapper per resource type
├── environments/{dev,test}/       <env>.bicepparam
└── pipelines/azure-pipeline.yaml  Validation -> What-If -> Deploy
```

## AVM module versions

| Module | Version |
|---|---|
| `avm/res/resources/resource-group` | 0.4.4 |
| `avm/res/insights/component` | 0.8.0 |
| `avm/res/app-configuration/configuration-store` | 0.10.1 |
| `avm/res/web/serverfarm` | 0.7.0 |
| `avm/res/web/site` | 0.24.0 |
| `avm/res/storage/storage-account` | 0.33.1 |
| `avm/res/key-vault/vault` | 0.14.2 |

`subnet.bicep` and `role-assignments.bicep` use native resources on purpose: the AVM
virtual-network module would manage the whole shared VNet, and native role assignments keep the
RBAC explicit.

## One-time setup

1. **Fill in the param files.** Replace every `<placeholder>` in `environments/*/*.bicepparam`
   (VNet, subnet prefixes, Log Analytics workspace, DNS zone resource group).
2. **Service connections.** Create `sc-application1-dev` and `sc-application1-test` as Azure
   Resource Manager connections using workload identity federation, one per environment
   subscription. Rename them in the pipeline `variables` block if you use other names.
3. **Permissions for each service connection's identity:**

   | Scope | Role |
   |---|---|
   | Target subscription | Contributor (creates the resource group) |
   | Target subscription | Role Based Access Control Administrator, conditioned to the 5 roles in the RBAC table |
   | VNet resource group | Network Contributor (or custom: `subnets/write`, `subnets/join/action`, `virtualNetworks/read`) |
   | Central DNS zone resource group | Private DNS Zone Contributor (or custom with `privateDnsZones/join/action`) |
   | Log Analytics workspace | Reader |

4. **Azure DevOps environments.** Create `application1-dev` and `application1-test`, and add an
   approval check (at least on test) so the What-If output is reviewed before Deploy runs.
5. **Pipeline.** Create a pipeline from `Application_1/pipelines/azure-pipeline.yaml` and run it
   manually, choosing the environment.

## Run locally

```bash
az bicep lint --file infra/main.bicep
az deployment sub what-if --location australiaeast --template-file infra/main.bicep --parameters environments/dev/dev.bicepparam
```

## Things to know

- **Subnet redeploys replace the whole subnet definition.** Declare any NSG or route table the
  subnet must keep in the param file, or a redeploy removes it.
- **First deployment:** system-assigned identities only exist once the apps do, so RBAC is
  applied last. The Function App can log storage auth errors for a few minutes until the role
  assignments propagate.
- **App code deployment needs a VNet-connected agent.** Both sites (including SCM) have public
  access disabled, so a Microsoft-hosted agent can't push code. Use a self-hosted agent or a
  Managed DevOps Pool in the VNet for app deployments. This IaC pipeline only calls Azure
  Resource Manager, so Microsoft-hosted agents are fine for it.
- **App Configuration key-values are not managed here.** `dataPlaneProxy.privateLinkDelegation`
  is enabled so they can be added via the module's `keyValues` parameter later.
- **No app has Key Vault data access.** Add Key Vault Secrets User for an app identity if it
  needs Key Vault references.
- **Runtime:** defaults to .NET 10 (`DOTNETCORE|10.0` / `DOTNET-ISOLATED|10.0`) because .NET 8
  support ended in November 2026. Change it per environment in the param files.
