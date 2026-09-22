Azure Bicep Registry (Azure Container Registry)
22 Sept 2026 · @James
This page describes the private Bicep module registry hosted on Azure Container Registry (ACR), used as an offline mirror of Azure Verified Modules (AVM) and as the home for custom, organization-specific Bicep modules and patterns.
Overview
Azure Container Registry (ACR) supports the OCI artifact spec, which lets it act as a private Bicep registry alongside its usual role storing container images. This registry is used for two purposes:
• An offline mirror of Azure Verified Modules (AVM). Rather than pulling AVM modules directly from the public Microsoft Container Registry (MCR) at deployment time, deployments resolve them from this internal registry. This removes a runtime dependency on internet/MCR access, gives control over exactly which module versions are approved for use, and protects against upstream changes or outages.
• A home for custom Bicep modules and patterns. Modules and reusable patterns written in-house (not part of AVM) are published here so they can be consumed the same way, with the same versioning and access model.
Both are stored as OCI artifacts in the same ACR instance, distinguished by repository path (see Registry structure).
Registry structure
Modules are organized under two top-level repository paths in the ACR:
Path
Contents
Source
bicep/avm/**
Mirrored Azure Verified Modules, path-for-path matching the public AVM repository structure (e.g. bicep/avm/res/storage/storage-account)
Synced from the public AVM registry
bicep/custom/**
Organization-authored modules and patterns not part of AVM
Authored and maintained in-house
Mirroring the AVM path structure exactly (avm/res/<provider>/<resource>, avm/ptn/..., avm/utl/...) under bicep/avm/ means the only thing that changes when switching a template from the public registry to this one is the registry hostname — the rest of the path is identical.
Under bicep/custom/, a suggested convention is to mirror the same shape (custom/res/..., custom/ptn/...) so the two trees stay easy to navigate side by side, but teams are free to organize this tree by project or domain instead if that fits better.
Publishing AVM modules
AVM modules are pulled from the public registry and re-published (mirrored) into bicep/avm/**, preserving the original path and version tag.
1. Identify the module and version to mirror from the AVM module index.
2. Pull the OCI artifact from the public MCR using the Bicep CLI or oras:
   bicep publish br:mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.14.0 --target br:<acrname>.azurecr.io/bicep/avm/res/storage/storage-account:0.14.0
   or, using oras for a direct artifact copy that also preserves manifests/metadata:
   oras copy mcr.microsoft.com/bicep/avm/res/storage/storage-account:0.14.0 <acrname>.azurecr.io/bicep/avm/res/storage/storage-account:0.14.0
3. Verify the mirrored module resolves correctly by referencing it from a scratch .bicep file and running bicep build.
4. Record the mirrored version (see Versioning) so consumers know which AVM releases are available internally.
This is typically automated as a scheduled pipeline that reads a maintained list of approved AVM modules + versions and syncs any that are missing, rather than being done module-by-module by hand.
Publishing custom modules and patterns
Custom modules live in a source repository, following the AVM authoring conventions (module metadata, main.bicep, README, tests) so they behave consistently with AVM modules for anyone consuming them.
1. Author the module under source control with a main.bicep, a README.md, and, where practical, deployment tests.
2. Bump the version following semantic versioning (see Versioning).
3. Publish with the Bicep CLI:
   bicep publish ./main.bicep --target br:<acrname>.azurecr.io/bicep/custom/res/<team>/<module-name>:1.2.0
4. Tag :latest (optional, team preference) alongside the semver tag if consumers should be able to float to the newest version.
5. Update the module catalog/README listing available custom modules so they're discoverable.
Publishing is generally wired into CI so merges to the module repository's main branch publish automatically, rather than being run manually from a developer machine.
Consuming modules
Templates reference modules from this registry with the br: module reference syntax, using the ACR login server as the host.
An AVM module:
module storageAccount 'br:<acrname>.azurecr.io/bicep/avm/res/storage/storage-account:0.14.0' = {
  name: 'storageAccountDeployment'
  params: {
    name: 'stexample001'
  }
}
A custom module:
module networkPattern 'br:<acrname>.azurecr.io/bicep/custom/ptn/networking/hub-spoke:1.2.0' = {
  name: 'hubSpokeDeployment'
  params: {
    hubAddressSpace: '10.0.0.0/16'
  }
}
To avoid repeating the full registry hostname everywhere, teams can define a br alias in bicepconfig.json:
{
  "moduleAliases": {
    "br": {
      "avm": { "registry": "<acrname>.azurecr.io", "modulePath": "bicep/avm" },
      "custom": { "registry": "<acrname>.azurecr.io", "modulePath": "bicep/custom" }
    }
  }
}
which shortens references to br/avm:res/storage/storage-account:0.14.0 and br/custom:ptn/networking/hub-spoke:1.2.0.
Access and authentication
Access is controlled with standard ACR RBAC roles, scoped as narrowly as practical:
Role
Assigned to
Purpose
AcrPull
Developers, deployment identities/service principals, CI/CD pipelines
Resolve (bicep build/deploy) modules from either path
AcrPush
The AVM sync pipeline's identity, the custom module CI pipeline's identity
Publish new module versions
AcrDelete
A small admin group only
Remove deprecated or broken artifacts
Authentication is typically via Azure AD:
• Local development: az acr login --name <acrname> after az login, which the Bicep CLI then uses transparently for br: references.
• CI/CD: a managed identity or service principal with the appropriate role above, authenticating non-interactively (e.g. az acr login in a pipeline step, or an OIDC-federated identity in GitHub Actions/Azure DevOps).
• Deployed resources: deployment principals only need AcrPull, since modules are resolved at deployment time, not at runtime by the deployed resources themselves.
Versioning
• AVM mirror (bicep/avm/**): tags match the upstream AVM release exactly (e.g. 0.14.0), so a version reference behaves identically whether pulled from the public registry or this mirror. Only approved/reviewed AVM versions are mirrored — the registry does not need to carry every upstream release.
• Custom modules (bicep/custom/**): tags follow semantic versioning (MAJOR.MINOR.PATCH), bumped by the module author on each published change: patch for fixes, minor for backward-compatible additions, major for breaking changes.
• No untagged/latest-only publishing: every published version gets an explicit semver or AVM-matching tag, so deployments can pin to a specific version. A latest tag can additionally point at the newest version for convenience, but is never the only tag on an artifact.
Maintenance
• Keeping the AVM mirror current: a scheduled sync pipeline checks the AVM index for new versions of approved modules and mirrors any that are missing (see Publishing AVM modules). New modules are added to the approved list on request/review rather than mirrored automatically.
• Deprecating a version: rather than deleting an in-use tag outright, mark it deprecated in the module catalog/README and give consumers a migration window before removal, to avoid breaking existing deployments that pin to it.
• Troubleshooting pulls: most failures are either an auth/RBAC issue (az acr login, missing AcrPull role) or a path/tag typo — verify the exact repository path and tag exist with az acr repository show-tags --name <acrname> --repository bicep/avm/res/storage/storage-account.
• Registry health: monitor ACR storage usage and enable soft-delete/retention policies appropriate to the org's recovery requirements, since this registry becomes a dependency for deployments once the offline mirror is in active use.
