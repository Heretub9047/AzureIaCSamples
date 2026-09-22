# Bicep Module Registry — AVM Mirror + Custom Modules

A single Azure Repos git repo that is both:
1. A **mirror of Azure Verified Modules (AVM)** source, kept in sync nightly, and
2. The **source of truth for your organisation's own custom Bicep modules**.

Both are published into your private Azure Container Registry (ACR) through
the same pipeline, so consumers always reference modules the same way
regardless of origin. **Every version, once mirrored or published, keeps its
own permanent folder in git and is never overwritten** — see
[Versioning model](#versioning-model) below.

## Repo layout

```
bicep/
  avm/
    res/<provider>/<resource>/<version>/main.bicep, version.json, README.md
    ptn/<pattern>/<version>/...
  custom/
    res/<name>/<version>/main.bicep, version.json, README.md
    ptn/<name>/<version>/...
pipelines/
  mirror-avm.yml                    nightly: capture new AVM versions, open/update a PR
  publish-modules.yml               on push to main: publish to ACR
scripts/
  discover-modules.ps1              AVM index -> list of module paths
  get-latest-versions.ps1           resolves each module's latest version from MCR
  install-oras.ps1                  installs ORAS (used only for tag listing)
  check-for-new-versions.ps1        cheap gate: is there anything to sync at all?
  sync-avm-source.ps1               captures new version folders, pushes branch, opens/updates PR
  publish-modules.ps1               diffs repo vs ACR, publishes what's missing
```

Each module version folder — mirrored or custom — contains just the
deployable files: `main.bicep`, `version.json`, `README.md`. AVM's own
`tests/` subfolders are **not** mirrored, to keep the repo lean and syncs
fast.

## Versioning model

**Every version gets its own folder, named after that version, and that
folder is never edited or deleted once created.** The folder name *is* the
version — there's no separate manifest file to keep in sync with it.

```
bicep/avm/res/storage/storage-account/
  0.30.1/main.bicep, version.json, README.md
  0.30.2/main.bicep, version.json, README.md   <- added later, 0.30.1 untouched
```

This means the full history of every version this pipeline has ever seen
stays in the repo and stays deployable — you can always go back and look at
exactly what `0.30.1`'s source was, and republish it if you ever needed to.

**One honest limitation, worth understanding:** Microsoft's own AVM
publishing process assigns the `PATCH` version automatically at publish
time and does not expose a corresponding git tag for it, so there is no
reliable way to fetch the *exact* historical source of a version after the
fact. This mirror works around that by capturing each version's source **at
the moment it first observes that version as new** — which is accurate as
long as the mirror runs at least once between any two published versions of
the same module. If a module publishes two or more new versions between
mirror runs (uncommon at AVM's typical release cadence, but possible), only
the latest of those gets captured; the skipped intermediate version simply
never gets a folder here (it remains directly available at
`mcr.microsoft.com` if ever needed). If this matters for your modules, run
`mirror-avm.yml` more often than nightly to shrink that window.

Custom modules follow the exact same rule: to ship a new version, create a
**new** version folder (e.g. `1.1.0/` next to the existing `1.0.0/`) rather
than editing `1.0.0/` in place.

## How the two pipelines fit together

**`mirror-avm.yml`** (nightly, 02:00 UTC)
1. Reads the official AVM module-index CSVs to get the current list of
   published module paths.
2. For each module, finds its latest published version on `mcr.microsoft.com`
   (via `oras repo tags`).
3. **Checks whether anything is actually new** — a cheap check against the
   current checkout of `main`, no git branch work involved. If nothing is
   new, the next step is **skipped entirely** (shows as "skipped" in the
   pipeline run, not a step that ran and did nothing).
4. Only if step 3 found something new: for any module where
   `bicep/avm/<module>/<version>/` doesn't already exist (checked again
   here, now also against whatever's already waiting on the mirror branch,
   so nothing gets fetched twice), pulls `main.bicep` / `version.json` /
   `README.md` straight from `Azure/bicep-registry-modules` on GitHub and
   writes them into that new folder. Existing version folders are left
   completely alone.
5. Pushes to a single long-lived branch (`avm-mirror-sync` by default) and
   opens a pull request into `main` — **or**, if a PR from that branch is
   already open, just leaves the new commit there; the existing PR picks it
   up automatically rather than a new one being created. **Merging the PR
   is what actually lands the new versions** — nothing here pushes to
   `main` directly.

**`publish-modules.yml`** (triggered on push to `main`, path-filtered to
`bicep`; also runs nightly at 03:00 UTC as a safety net)
1. Scans every folder under `bicep/avm/**` and `bicep/custom/**` that
   contains a `main.bicep` — the folder's own name is treated as its
   version (e.g. `.../storage-account/0.30.1/` publishes as `0.30.1`).
2. Diffs those versions against what's already in the ACR
   (`az acr repository show-tags`) and runs `az bicep publish` only for
   what's missing. Already-published versions are never republished or
   overwritten.

Because step 2 diffs against the ACR rather than relying on git diff, this
pipeline is idempotent and safe to re-run — nothing gets published twice,
and a missed trigger self-heals on the next scheduled run. It only fires
once mirrored (or custom) changes are actually merged into `main`, so
nothing gets published to the ACR before a human has approved the PR.

## Adding a custom module

1. Create `bicep/custom/res/<name>/1.0.0/` (or
   `bicep/custom/ptn/<name>/1.0.0/`) with:
   - `main.bicep`
   - `version.json` — `{ "version": "1.0.0" }` (kept for documentation;
     the folder name is what actually determines the published tag)
   - `README.md` (recommended)
2. Open a normal PR into `main`.
3. Once merged, `publish-modules.yml` picks it up automatically and
   publishes `br:<youracr>.azurecr.io/bicep/custom/res/<name>:1.0.0`.
4. To ship a new version, add a **new** folder, e.g.
   `bicep/custom/res/<name>/1.1.0/` — never edit `1.0.0/` after it's been
   published.

## Setup

1. **Create (or reuse) a destination ACR.**
2. **Grant the mirror pipeline permission to push a branch and open PRs on
   this repo.** The identity it runs as (by default the project's Build
   Service account) needs:
   - **Contribute** permission on the repo (to push the `avm-mirror-sync`
     branch), and
   - **Contribute to pull requests** permission (to open/read PRs via the
     REST API).
   Since this pipeline no longer pushes to `main` directly, no branch-policy
   bypass is needed — the PR goes through your normal review/policy flow
   for `main` like any other PR.
3. **Allow the pipeline job to use the OAuth token.** This is already wired
   up in `mirror-avm.yml` via `env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)`
   on the sync step; you shouldn't need to change anything, but if your
   organization has "Limit job authorization scope" restricted at the
   collection/project level, make sure it still allows same-project token
   use (the default).
4. **Create an Azure Resource Manager service connection** for the publish
   pipeline, pointing at the subscription containing your ACR. Its identity
   needs **AcrPush** (or a broader role like Contributor) on the ACR.
   Note this is different from an `az acr import`-based approach: `az bicep
   publish` is a registry **push** (data-plane), so `AcrPush` is sufficient
   and is the more tightly-scoped choice.
5. **Add both YAML files as separate Azure DevOps pipelines**, pointing at
   `pipelines/mirror-avm.yml` and `pipelines/publish-modules.yml`
   respectively.
6. **Set pipeline parameters** on `publish-modules.yml`:
   - `azureServiceConnection` — service connection from step 4
   - `acrName` — destination ACR name (without `.azurecr.io`)
7. **Run `mirror-avm.yml` once manually**, then **merge the PR it opens**
   to populate `bicep/avm/**` for the first time. That merge triggers
   `publish-modules.yml` automatically (or run it manually with
   `dryRun=true` first, if you want to preview the bulk publish). After
   that, the schedules keep everything current automatically.

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

- **First run captures every currently-published version's latest release,
  not full history.** ~520 AVM modules will land in the repo, one folder
  each (their current latest version), and then get published in one go.
  Older historical versions that were already published before you started
  mirroring won't retroactively get a folder here — see
  [Versioning model](#versioning-model) for why. They remain directly
  available on `mcr.microsoft.com` if anyone still needs them.
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
