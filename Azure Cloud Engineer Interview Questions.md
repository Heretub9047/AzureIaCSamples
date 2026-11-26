# Azure Cloud Engineer – Interview Questions & Answer Guide

Nov 26, 2026 · @James

## How to use this guide

Six questions fill a 60-minute interview: three technical (about 10 minutes each) and three broad (about 8 minutes each), leaving time for the candidate's questions. Each question lists what it tests, what a strong answer covers, follow-up probes, and red flags.

A candidate doesn't need to hit every bullet. Look for depth on the core points and sound reasoning when you push past what they know. "I haven't used that, but I'd expect it to work like X" is a good sign.

Tip: open with Broad Q4 to settle the candidate in, then move to the technical questions while they're warmed up.

| Score | Meaning | Typical signal |
| --- | --- | --- |
| 4 – Strong | Has done it, at scale, and explains the trade-offs | Volunteers caveats and alternatives without prompting |
| 3 – Solid | Has done it and gets the core right | Needs a probe or two to reach the deeper points |
| 2 – Partial | Knows the concepts but has thin hands-on experience | Generic answers; struggles with the follow-ups |
| 1 – Weak | Can't explain the basics, or describes risky practice | Shows one or more of the listed red flags |

## Technical Q1 – Bicep: one codebase, many environments

**Ask:** "You join a team that deploys a web app – App Service, Azure SQL, Key Vault and private endpoints – to dev, test and prod. Walk me through how you'd structure the Bicep so it's reusable, safe, and identical across environments."

**What it tests:** Real hands-on Bicep: modular design, parameterising environments, handling secrets, and safe change management.

**A strong answer covers:**

- **Modules:** a `main.bicep` that calls focused modules (network, Key Vault, SQL, app). Reuses Azure Verified Modules (`br/public:avm/...`) or a versioned internal registry rather than writing everything from scratch.
- **One template, many environments:** a `.bicepparam` file per environment (`using './main.bicep'`), never copies of the template. Differences such as SKU, instance count and zone redundancy are parameters, validated with `@allowed`, `@minValue` or user-defined types.
- **Scopes:** understands `targetScope` (resource group, subscription, management group). For example, a subscription-scoped main that creates the resource group, then deploys modules into it with `scope:`.
- **Dependencies and shared resources:** relies on implicit dependencies from symbolic references, rarely writing `dependsOn`. Uses the `existing` keyword for shared resources like the hub VNet, central Log Analytics or private DNS zones.
- **Secrets:** `@secure()` parameters and `getSecret()` on an existing Key Vault, passed into a module. Never outputs secrets. Even better: managed identity with Entra authentication to SQL, so there's no password at all.
- **Conventions:** consistent naming (e.g. `uniqueString(resourceGroup().id)`), tags passed in and applied everywhere, conditions (`if`) for prod-only features, loops (`for`) for repeated resources.
- **Quality gates:** the linter via `bicepconfig.json`, `what-if` before every deploy, and policy or security scanning (PSRule for Azure, Checkov).

**Follow-up probes:**

1. *"How do you see what a deployment will change before you run it?"* Listen for `az deployment group what-if`, reviewed in the PR or before approval. A strong candidate admits it can be noisy, with false-positive changes on some properties.
2. *"You delete a resource from the template and redeploy. What happens in Azure?"* By default, nothing: incremental mode leaves it in place. Complete mode deletes anything not in the template, which is risky. The best answer is **deployment stacks** (`az stack group create --action-on-unmanage deleteResources`), which can also deny portal changes with deny settings.
3. *"How do you share and version modules across teams?"* A private Bicep registry in Azure Container Registry (`br:` references with version tags) or template specs, with semantic versioning.
4. *"Bicep or Terraform – when would you pick each?"* A balanced view: Bicep is Azure-only, has no state file and supports new APIs on day one. Terraform is multi-cloud, has a plan/state model and a wider provider ecosystem.

**Red flags:**

- A copy of the whole template per environment.
- Secrets in parameter files, committed to the repo, or exposed in outputs.
- Has never used `what-if`, or deploys straight to prod.
- Only knows ARM exported from the portal and decompiled, never refactored.
- Can't explain incremental vs complete mode, or uses complete mode casually.

**What good looks like (reference for the interviewer):**

```bicep
// main.bicep
@allowed(['dev', 'test', 'prod'])
param environment string
param keyVaultName string

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

module sql 'modules/sql.bicep' = {
  name: 'sql-${environment}'
  params: {
    zoneRedundant: environment == 'prod'
    adminPassword: kv.getSecret('sql-admin-password') // @secure() param in the module
  }
}

// prod.bicepparam
using './main.bicep'
param environment = 'prod'
param keyVaultName = 'kv-app-prod-aue'
```

## Technical Q2 – Azure DevOps YAML pipelines: deploying Bicep safely to prod

**Ask:** "Design an Azure DevOps YAML pipeline that deploys that Bicep to dev, test and prod. Talk me through the stages, how you control who and what can reach prod, and how the pipeline authenticates to Azure."

**What it tests:** Fluency with multi-stage YAML, gating and governance, secure identity, and reuse at scale.

**A strong answer covers:**

- **Stages:** Validate (`az bicep build`/lint, security scan, publish the infra as a pipeline artifact), then Dev, Test and Prod. The same artifact is promoted through every stage, never rebuilt per environment.
- **Deployment jobs, not plain jobs:** `- deployment:` with `environment:` and `strategy: runOnce`, so every deployment is recorded against an Azure DevOps Environment.
- **Environment checks:** approvals on prod, branch control (only `main`), exclusive lock to stop overlapping deploys, business hours, and "required template" for governed pipelines.
- **Identity:** Azure Resource Manager service connections using **workload identity federation** (OIDC), so there are no client secrets to store or rotate. One service connection per environment, with least-privilege RBAC scoped to that environment, and checks on the prod connection too.
- **Secrets:** variable groups linked to Key Vault. Nothing sensitive in YAML or echoed to logs.
- **Reuse:** step, job and stage templates with typed parameters, kept in a shared repo (`resources: repositories` and `template: x.yml@templates`). `extends` templates enforce organisation-wide guardrails.
- **Triggers:** CI on `main` with path filters (e.g. `infra/`). PR validation runs lint and what-if; in Azure Repos that's a branch policy build validation, because the YAML `pr:` trigger only applies to GitHub and Bitbucket.
- **Agents:** Microsoft-hosted by default; self-hosted agents or Managed DevOps Pools when the pipeline must reach resources behind private endpoints.

**Follow-up probes:**

1. *"What's the difference between `${{ }}`, `$[ ]` and `$( )`?"* This is the best test of real YAML experience. `${{ }}` template expressions are evaluated at compile time and can shape the pipeline itself (loops, conditional stages). `$[ ]` runtime expressions are evaluated during the run, typically in conditions and variables. `$( )` macro syntax is substituted just before each task runs.
2. *"How do you avoid writing the deploy stage three times?"* One stage template with parameters, called in a `${{ each env in parameters.environments }}` loop.
3. *"How do you guarantee prod only deploys from main?"* Branch control on the prod environment or service connection. Strong nuance: a `condition:` in YAML isn't enough, because anyone can edit the YAML in a branch; checks on protected resources can't be bypassed that way.
4. *"Where does what-if run relative to the prod approval?"* In a stage *before* the gated stage. Checks gate a stage before any of its jobs start, so a what-if inside the deploy job would only run after someone approved blind. Bonus: what-if output published to the run summary or PR.
5. *"Have you migrated classic release pipelines to YAML?"* Listen for what they gained (versioned in Git, PR review of pipeline changes, templates) and what tripped them up.

**Red flags:**

- Only uses classic (GUI) release pipelines.
- Service principal with a client secret in a pipeline variable, or one Owner-level principal across all subscriptions.
- No approvals or checks on prod ("we just don't run it").
- Rebuilds per stage, so prod gets a different artifact from what was tested.
- Can't explain compile-time vs runtime expressions.

**What good looks like (reference skeleton):**

```yaml
# azure-pipelines.yml
trigger:
  branches:
    include: [main]
  paths:
    include: [infra]

parameters:
  - name: environments
    type: object
    default: [dev, test, prod]

resources:
  repositories:
    - repository: templates            # shared templates repo
      type: git
      name: Platform/pipeline-templates

stages:
  - stage: Validate
    jobs:
      - job: Lint
        steps:
          - script: az bicep build --file infra/main.bicep   # build runs the linter
          - publish: infra
            artifact: infra

  - ${{ each env in parameters.environments }}:
      - template: stages/deploy-bicep.yml@templates
        parameters:
          environment: ${{ env }}

# stages/deploy-bicep.yml (in the templates repo)
parameters:
  - name: environment
    type: string

stages:
  - stage: Deploy_${{ parameters.environment }}
    jobs:
      - deployment: Deploy
        environment: app-${{ parameters.environment }}    # approvals and checks live here
        strategy:
          runOnce:
            deploy:
              steps:
                - task: AzureCLI@2
                  inputs:
                    azureSubscription: sc-app-${{ parameters.environment }}   # workload identity federation
                    scriptType: bash
                    scriptLocation: inlineScript
                    inlineScript: >
                      az deployment group create
                      --resource-group rg-app-${{ parameters.environment }}
                      --template-file $(Pipeline.Workspace)/infra/main.bicep
                      --parameters $(Pipeline.Workspace)/infra/${{ parameters.environment }}.bicepparam
```

## Technical Q3 – Troubleshooting: App Service can't reach Azure SQL over a private endpoint

**Ask:** "After the first prod deployment, the App Service can't connect to Azure SQL. SQL has public access disabled and a private endpoint; the app uses VNet integration. The same code works in dev. Prod sits in a hub-and-spoke network with custom DNS servers in the hub. How do you troubleshoot it?"

**What it tests:** Azure networking depth, especially private endpoint DNS (the most common real-world failure), a structured troubleshooting method, and fixing the root cause in code.

**A strong answer covers:**

- **Starts with DNS:** from inside the app, does `myserver.database.windows.net` resolve to a private IP or a public one? Tools: the Kudu console's `nameresolver` and `tcpping myserver.database.windows.net:1433` (Windows), or SSH with `nslookup` and `nc` (Linux).
- **Explains how private endpoint DNS works:** the public name is a CNAME to `myserver.privatelink.database.windows.net`. That name must be answered by a private DNS zone, `privatelink.database.windows.net`, holding the endpoint's A record.
- **Spots why prod differs:** with custom DNS in the hub, the private DNS zone must be linked to the hub VNet where resolution happens. The hub DNS must also forward to Azure DNS (168.63.129.16), usually via Azure DNS Private Resolver or conditional forwarders. In dev, the zone was probably linked straight to a VNet using Azure-provided DNS.
- **Checks the A record exists:** is a DNS zone group configured on the private endpoint? In landing zones, an Azure Policy (DeployIfNotExists) often creates it. If the policy didn't fire, or the zone sits in another subscription without permissions, the record is missing.
- **Then the network path:** VNet integration with all outbound traffic routed through the VNet, the integration subnet delegated to `Microsoft.Web/serverFarms`, NSGs on both subnets, and UDRs sending traffic through a hub firewall (are port 1433 and the return path allowed?).
- **Then SQL and auth:** separates connectivity errors from authentication errors. SQL firewall rules don't apply to private endpoint traffic.
- **Tools:** Network Watcher (connection troubleshoot, next hop), effective routes, firewall logs, App Service "Diagnose and solve problems".
- **Fixes it in code:** a `privateDnsZoneGroups` child resource on the private endpoint in Bicep (or the policy fixed), VNet links managed in IaC, and a post-deploy connectivity smoke test in the pipeline.

**Follow-up probes:**

1. *"Should the connection string use the privatelink name or the private IP?"* Neither. Keep the normal `database.windows.net` name and let DNS do the redirection; certificate validation expects the standard name.
2. *"SQL returns 'Deny Public Network Access is set to Yes'. What does that tell you?"* The request reached SQL over the public endpoint, so DNS returned a public IP or the traffic didn't go through VNet integration.
3. *"How do you stop this for the next 50 private endpoints?"* Central private DNS zones in the hub, DeployIfNotExists policy for zone groups (the Azure Landing Zone pattern), DNS Private Resolver, and shared Bicep modules that include the zone group.
4. *"Connectivity now works, but the managed identity can't log in. Next step?"* An Entra admin set on the server, a database user created with `CREATE USER [app-name] FROM EXTERNAL PROVIDER`, and the right database roles granted.

**Red flags:**

- Never mentions DNS.
- "Fixes" it by enabling public access or adding SQL firewall rules.
- Hardcodes the private IP in a hosts file or connection string.
- Changes things at random rather than working layer by layer from a hypothesis.
- Fixes it by hand in the portal and doesn't bring the fix back into Bicep.

## Broad Q4 – An Azure environment you built end to end

**Ask:** "Tell me about an Azure environment you designed or significantly improved, end to end. What was the business need, what did you build, what trade-offs did you make, and what would you do differently now?"

**What it tests:** Ownership, architectural judgement, linking technology to business outcomes, self-reflection and communication.

**A strong answer covers:**

- **Business context first:** who used it, the constraints (compliance, budget, timeline) and what success meant. For example, data residency in Australian regions, or Essential Eight / IRAP requirements for government work.
- **The foundations, not just the app:** subscription and management group layout, network topology (hub-and-spoke or Virtual WAN), identity (Entra ID, managed identities, PIM), monitoring and alerting, backup and DR, and cost controls.
- **Explicit trade-offs with reasons:** e.g. App Service vs Container Apps vs AKS, zone redundancy vs cost, Azure Firewall vs a third-party NVA, single vs multi-region. Well-Architected pillars come up naturally rather than as buzzwords.
- **A measurable outcome:** deployment time cut, cost reduced, uptime achieved, audit passed.
- **Specific hindsight:** something concrete they'd change, e.g. "I'd put policy guardrails in place before onboarding teams" or "we underestimated the DNS design".
- **Clear about their role:** distinguishes what *they* did from what the team did.

**Follow-up probes:**

1. *"Why that over \[the obvious alternative\]?"* Pick one decision and push on it; strong candidates defend it with context and concede its downsides.
2. *"What did it cost per month, and how did you keep that in check?"* Budgets and alerts, reservations or savings plans, right-sizing, tagging for showback.
3. *"What happens if the region goes down? Was that tested?"* Listen for RTO/RPO targets and a DR test that actually happened.
4. *"Who could change what in production, and how was that controlled?"*

**Red flags:**

- "We" throughout, with no clear personal contribution.
- A list of services with no business reason behind them.
- No trade-offs ("it was just the best option").
- No story for monitoring, backup or cost.
- Can't name anything they'd do differently, or blames others for everything.

## Broad Q5 – Your IaC journey: Bicep, pipelines and portal changes

**Ask:** "Tell me about your experience with Bicep and Azure DevOps YAML pipelines. How have you introduced or matured infrastructure as code in a team, and how do you deal with people making changes directly in the portal?"

**What it tests:** The depth and length of real IaC experience, the ability to change team habits, and a pragmatic approach to drift.

**A strong answer covers:**

- **Concrete history:** how long, at what scale (environments, subscriptions, teams), what they inherited (ARM, scripts, portal-built, Terraform) and what they moved it to.
- **Incremental adoption:** start with new workloads or a pilot, then bring existing resources under code gradually. Shared modules, PR reviews, and the pipeline as the only route to prod.
- **The people side:** pairing, starter templates or a "golden path" repo, and making the right way the easy way. Wins buy-in by showing faster, safer deployments.
- **Drift handled in layers:**
  - *Prevent:* humans get Reader in prod and the pipeline identity makes changes; PIM for break-glass access; resource locks or deployment stack deny settings.
  - *Detect:* scheduled what-if runs, Azure Policy compliance, and Activity Log alerts on writes not made by the pipeline identity.
  - *Correct:* bring the change into code through a PR, or redeploy to revert it. Emergency fixes are allowed but must be back-ported within an agreed time.
- **Measures of success:** share of resources under code, deployment lead time, change failure rate (DORA metrics).

**Follow-up probes:**

1. *"An engineer hot-fixed prod in the portal during an outage. What now?"* Acceptable in an emergency, handled blamelessly, but captured in code by PR quickly. Bonus: what-if on the next run would show the difference, so it doesn't silently get reverted.
2. *"How do you bring a hand-built environment under Bicep without downtime?"* Export or `az bicep decompile` (or "Insert Resource" in VS Code), refactor into modules, then iterate until what-if shows no changes before letting the pipeline own it.
3. *"What do you look for when reviewing a Bicep PR?"* Lint results, what-if output, policy or security scan results, small focused changes, code owners on shared modules.
4. *"What did you get wrong early on?"* Honest, specific lessons are a strong signal.

**Red flags:**

- IaC only ever run from their own laptop, never through a pipeline or code review.
- Bans all portal access with no break-glass path, or treats drift as someone else's problem.
- A "big bang" rewrite with no migration plan.
- Can't give examples of scale or numbers.
- No awareness of the people and change-management side.

## Broad Q6 – A production incident

**Ask:** "Tell me about a significant production incident you were involved in on Azure. What happened, what was your role, how was it resolved, and what changed afterwards?"

**What it tests:** Operational maturity, composure under pressure, communication, root-cause thinking and a learning culture.

**A strong answer covers:**

- **A clear timeline:** how it was detected (an alert, or a customer complaint?), triage, mitigation and resolution.
- **Mitigate first, investigate second:** restores service quickly (roll back, swap a deployment slot, fail over, scale out), then finds the cause.
- **The right tools:** Azure Monitor, Log Analytics and KQL, Application Insights, Service Health and Resource Health to rule a platform issue in or out, and the Activity Log to answer "what changed?".
- **Communication:** regular stakeholder updates and clear roles, such as an incident lead separate from the people fixing it.
- **Root cause, not just the trigger:** "the certificate expired" is the trigger; "renewal was manual and expiry wasn't monitored" is the root cause.
- **Lasting change:** a blameless post-incident review with tracked actions, such as new alerts, a runbook, a fix in Bicep or a new pipeline check.
- **Honesty:** owns their part if they contributed to the problem.

**Follow-up probes:**

1. *"How did you first find out? Would you catch it sooner today?"* Good: an alert fired. Better: SLO-based alerting or synthetic availability tests that catch it before customers do.
2. *"Roughly what KQL would you run to find the failing requests?"* A strong candidate can sketch something like `requests | where success == false | summarize count() by resultCode, bin(timestamp, 5m)` (or the `AppRequests` table in a workspace).
3. *"How did you tell whether it was Azure or your own change?"* Service Health and Resource Health, plus recent deployments and Activity Log entries.
4. *"Which action from the review actually got done?"* Separates real follow-through from good intentions.

**Red flags:**

- Can't recall any incident (a concern for a mid-level or senior role).
- A hero story: fixed it alone, no communication, no review.
- Blames individuals, or blames Microsoft without evidence.
- Stops at the trigger, with nothing changed afterwards.
- Fixed prod by hand and never brought the change back into code.
