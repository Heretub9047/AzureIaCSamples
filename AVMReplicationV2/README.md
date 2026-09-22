# Bicep Module Registry — AVM Mirror + Custom Modules

A single Azure Repos git repo that is both:
1. A **mirror of Azure Verified Modules (AVM)** source, kept in sync nightly, and
2. The **source of truth for your organisation's own custom Bicep modules**.

Both are published into your private Azure Container Registry (ACR) through
the same pipeline, so consumers always reference modules the same way
regardless of origin.

## Repo layout

```
bicep/
  avm/
    res/<provider>/<resource>/...   AVM resource modules (mirrored)
    ptn/<pattern>/...               AVM pattern modules (mirrored)
    _manifest.json                  module path -> currently mirrored version
  custom/
    res/<name>/...                  your org's custom resource modules
    ptn/<name>/...                  your org's custom pattern modules
pipelines/
  mirror-avm.yml                    nightly: sync AVM source, commit to main
  publish-modules.yml                on push to main: publish to ACR
scripts/
  discover-modules.ps1              AVM index -> list of module paths
  get-latest-versions.ps1           resolves each module's latest version from MCR
  install-oras.ps1                  installs ORAS (used only for tag listing)
  sync-avm-source.ps1               pulls source, updates manifest, commits/pushes
  publish-modules.ps1               diffs repo vs ACR, publishes what's missing
```

Each module folder — mirrored or custom — contains just the deployable
files: `main.bicep`, `version.json`, `README.md`. AVM's own `tests/`
subfolders are **not** mirrored, to keep the repo lean and syncs fast.

## How the two pipelines fit together

**`mirror-avm.yml`** (nightly, 02:00 UTC)
1. Reads the official AVM module-index CSVs to get the current list of
   published module paths.
2. For each module, finds its latest published version on `mcr.microsoft.com`
   (via `oras repo tags`).
3. Pulls `main.bicep` / `version.json` / `README.md` for that module straight
   from `Azure/bicep-registry-modules` on GitHub, writes them into
   `bicep/avm/res/...` or `bicep/avm/ptn/...`, and records the resolved
   version in `bicep/avm/_manifest.json`.
4. Commits and pushes **directly to `main`** — no PR step, per your setup.

**`publish-modules.yml`** (triggered on push to `main`, path-filtered to
`bicep/*`; also runs nightly at 03:00 UTC as a safety net)
1. Scans every folder under `bicep/avm/**` and `bicep/custom/**` that
   contains a `main.bicep`.
2. Works out the version each one should publish at:
   - **AVM modules** — looked up in `bicep/avm/_manifest.json` (upstream's
     own `version.json` only stores `MAJOR.MINOR`; Microsoft's CI assigns
     the `PATCH` at publish time, so we don't use it directly — the
     manifest carries the real, resolved version instead).
   - **Custom modules** — read from that module's own `version.json`,
     which must contain a full `MAJOR.MINOR.PATCH`, e.g. `{"version": "1.0.0"}`.
3. Diffs against what's already in the ACR (`az acr repository show-tags`)
   and runs `az bicep publish` only for what's missing.

Because step 3 diffs against the ACR rather than relying on git diff, this
pipeline is idempotent and safe to re-run — nothing gets published twice,
and a missed trigger self-heals on the next scheduled run.

## Adding a custom module

1. Create `bicep/custom/res/<name>/` (or `bicep/custom/ptn/<name>/`) with:
   - `main.bicep`
   - `version.json` — `{ "version": "1.0.0" }`
   - `README.md` (recommended)
2. Open a normal PR into `main`.
3. Once merged, `publish-modules.yml` picks it up automatically and
   publishes `br:<youracr>.azurecr.io/bicep/custom/res/<name>:1.0.0`.
4. To ship a new version, bump `version.json` and merge again — the old
   version stays published, untouched.

## Setup

1. **Create (or reuse) a destination ACR.**
2. **Grant the mirror pipeline push rights on this repo.** It commits
   directly to `main` with no PR, so the identity it runs as (by default
   the project's Build Service account) needs:
   - **Contribute** permission on the repo, and
   - **Bypass policies when pushing** if `main` has branch policies
     (required PR reviewers, required builds, etc.) — direct pushes will
     otherwise be rejected.
3. **Create an Azure Resource Manager service connection** for the publish
   pipeline, pointing at the subscription containing your ACR. Its identity
   needs **AcrPush** (or a broader role like Contributor) on the ACR.
   Note this is different from an `az acr import`-based approach: `az bicep
   publish` is a registry **push** (data-plane), so `AcrPush` is sufficient
   and is the more tightly-scoped choice.
4. **Add both YAML files as separate Azure DevOps pipelines**, pointing at
   `pipelines/mirror-avm.yml` and `pipelines/publish-modules.yml`
   respectively.
5. **Set pipeline parameters** on `publish-modules.yml`:
   - `azureServiceConnection` — service connection from step 3
   - `acrName` — destination ACR name (without `.azurecr.io`)
6. **Run `mirror-avm.yml` once manually** to populate `bicep/avm/**` for the
   first time, then run `publish-modules.yml` (with `dryRun=true` first, if
   you want to preview) to do the initial bulk publish. After that, the
   schedules keep everything current automatically.

## Using the published modules

```bicep
// AVM module, from your own registry
module storageAccount 'br/myorgacr.azurecr.io/bicep/avm/res/storage/storage-account:0.30.1' = { ... }

// Custom org module
module landingZone 'br/myorgacr.azurecr.io/bicep/custom/ptn/landing-zone:1.0.0' = { ... }
```

Optionally configure
[registry aliases in `bicepconfig.json`](https://learn.microsoft.com/azure/azure-resource-manager/bicep/private-module-registry#configure-a-bicep-registry-alias)
so teams don't have to reference the full ACR hostname every time:

```json
{
  "moduleAliases": {
    "br": {
      "avm": { "registry": "myorgacr.azurecr.io", "modulePath": "bicep/avm" },
      "custom": { "registry": "myorgacr.azurecr.io", "modulePath": "bicep/custom" }
    }
  }
}
```

```bicep
module storageAccount 'br/avm:res/storage/storage-account:0.30.1' = { ... }
module landingZone 'br/custom:ptn/landing-zone:1.0.0' = { ... }
```

## Notes & things worth tuning

- **First run is the slow one.** ~520 AVM modules will land in the repo and
  then get published in one go. After that, both pipelines only touch
  what's new.
- **Parallelism**: `discoverParallelism` / `syncParallelism` on the mirror
  pipeline default to 8/12. Back these off if you see repeated warnings
  from MCR or GitHub rate limiting.
- **Orphaned modules**: included by default (`includeOrphaned=true`) since
  they're still valid, installable versions.
- This mirrors **Bicep** AVM modules only. Terraform AVM modules are
  distributed via the Terraform Registry, not a container registry, so
  they're out of scope here.
- **Digest/provenance note**: because we recompile from source with
  `az bicep publish` rather than copying the original OCI artifact
  byte-for-byte, the resulting image digest in your ACR will differ from
  the one on `mcr.microsoft.com`, even though the compiled template content
  is the same (Bicep compilation is deterministic). If you need
  bit-identical artifacts for signature/provenance verification against
  Microsoft's originals, flag that — it changes the design back towards an
  `az acr import`-based copy for the AVM side.
