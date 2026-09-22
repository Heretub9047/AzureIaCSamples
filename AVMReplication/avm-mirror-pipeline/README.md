# AVM → Private ACR Mirror Pipeline

Keeps a private Azure Container Registry (ACR) in sync with the public
[Azure Verified Modules](https://aka.ms/avm) Bicep registry hosted on
`mcr.microsoft.com`.

## How it works

**Stage 1 — Discover**
1. Downloads the three official AVM module-index CSVs that Microsoft
   publishes and maintains (these back the AVM website and VS Code
   IntelliSense, so they're the authoritative source of truth):
   - `BicepResourceModules.csv` (`avm/res/...`)
   - `BicepPatternModules.csv` (`avm/ptn/...`)
   - `BicepUtilityModules.csv` (`avm/utl/...`)
2. Filters to modules with status `Available` (and optionally `Orphaned`,
   which are still published but unmaintained) and extracts each module's
   registry path from its `PublicRegistryReference` column.
3. For every module path, queries `mcr.microsoft.com` (via `oras repo tags`)
   for every published version.
4. Publishes a `module,tag` CSV as a pipeline artifact.

**Stage 2 — Sync**
1. Downloads the artifact from Stage 1.
2. For each module, lists what's already present in your ACR
   (`az acr repository show-tags`).
3. Computes the diff and runs `az acr import` only for the missing
   module/version combinations. `az acr import` is a **server-side** copy —
   image bytes never pass through the pipeline agent, so this scales fine
   even with hundreds of modules and thousands of versions.

Because the sync step only imports what's *missing*, the first run will be
the slow one (there are currently 500+ modules and several thousand
module/version combinations in total). Every run after that is fast, since
it only pulls newly published modules/versions.

## Setup

1. **Create (or reuse) a destination ACR.**
2. **Create an Azure Resource Manager service connection** in Azure DevOps
   pointing at the subscription containing that ACR.
3. **Grant permissions.** The service connection's identity needs a role
   that includes the `Microsoft.ContainerRegistry/registries/importImage/action`
   permission on the destination ACR. The built-in **Contributor** role
   covers this. Note that **AcrPush alone does not** — `az acr import` is a
   registry-level control-plane operation, not a data-plane push. If you
   want something narrower than Contributor, create a custom role with just
   that action (plus `Microsoft.ContainerRegistry/registries/read`).
4. **Add this repo as an Azure DevOps pipeline**, pointing at
   `azure-pipelines.yml`.
5. **Set the pipeline parameters** (or edit the defaults in the YAML):
   - `azureServiceConnection` — name of the service connection from step 2
   - `acrName` — destination ACR name (without `.azurecr.io`)
   - `destinationPrefix` — repository prefix in your ACR (default `bicep`,
     which mirrors MCR's own layout so `br/public:avm/res/...` becomes
     `br/youracr.azurecr.io/bicep/avm/res/...` — a predictable, minimal
     find/replace for teams migrating their Bicep files)
6. **Run once manually with `dryRun=true`** to see what would be imported
   before letting it run for real. The nightly schedule (02:00 UTC) then
   keeps things current automatically.

## Using the mirrored modules

Once mirrored, reference modules from your own registry instead of the
public one:

```bicep
// Before (public registry)
module storageAccount 'br/public:avm/res/storage/storage-account:0.30.0' = { ... }

// After (your private registry)
module storageAccount 'br/myorgacr.azurecr.io/bicep/avm/res/storage/storage-account:0.30.0' = { ... }
```

You can also configure an
[alias in `bicepconfig.json`](https://learn.microsoft.com/azure/azure-resource-manager/bicep/private-module-registry#configure-a-bicep-registry-alias)
so teams don't have to rewrite every module reference:

```json
{
  "moduleAliases": {
    "br": {
      "avm": {
        "registry": "myorgacr.azurecr.io",
        "modulePath": "bicep"
      }
    }
  }
}
```

```bicep
module storageAccount 'br/avm:avm/res/storage/storage-account:0.30.0' = { ... }
```

## Files

Everything is PowerShell (`pwsh`), which ships pre-installed on Microsoft-hosted
Azure DevOps agents (both Windows and Linux) — no extra tooling to install.

| File | Purpose |
|---|---|
| `azure-pipelines.yml` | Pipeline definition (2 stages, schedule trigger) |
| `scripts/discover-modules.ps1` | Parses AVM index CSVs → list of module paths |
| `scripts/install-oras.ps1` | Installs a pinned ORAS CLI build |
| `scripts/get-tags.ps1` | Lists published versions per module from MCR |
| `scripts/sync-modules.ps1` | Diffs vs. destination ACR, imports what's missing |

Why PowerShell over bash here: the AVM index CSVs contain quoted fields with
embedded commas (e.g. `AlternativeNames` values like `"AAD, Entra ID, Microsoft
Entra Domain Services"`), which naive `awk`/`cut`-based bash parsing will
silently mis-split. PowerShell's `ConvertFrom-Csv` parses these correctly, and
`ForEach-Object -Parallel` gives the same concurrency `xargs -P` gave in the
bash version, so behaviour is otherwise identical.

## Notes & things worth tuning

- **Parallelism**: `discoverParallelism` / `syncParallelism` default to 8/6.
  MCR and `az acr import` can throttle under heavy concurrency — back these
  off if you see repeated `WARN`/`FAIL` lines in the logs.
- **Orphaned modules**: included by default since they're still valid,
  installable versions; set `includeOrphaned=false` if you only want
  actively maintained modules.
- **Proposed modules** are never included — they have no
  `PublicRegistryReference` yet, meaning nothing exists to import.
- This mirrors **Bicep** AVM modules (OCI artifacts under `bicep/avm/...`).
  Terraform AVM modules are distributed via the Terraform Registry, not a
  container registry, so they're out of scope for this pipeline.
