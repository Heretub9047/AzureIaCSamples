# Hosting R and Python analytics apps: options paper

Nov 24, 2026 · @James

**Recommendation:** adopt Azure Container Apps, deployed through a shared Azure DevOps pipeline, as the standard way to host the Data Analysis unit's Shiny and Streamlit apps. It costs about A$65–210 a month for ten apps, keeps data in Australia East and uses staff Entra ID sign-in. App Service is the fallback, using the same images and pipeline. A 6–8 week pilot with two apps should confirm the approach before it is rolled out.

## Purpose and background

The Data Analysis unit builds interactive apps in R (Shiny) and Python (Streamlit), but there is no standard way to deploy them. One of the two hosted services the unit suggested, shinyapps.io, closes on 31 December 2026.

The unit suggested shinyapps.io or Streamlit's hosted service. Posit has announced that it will [move all shinyapps.io users to Connect Cloud at the end of 2026](https://forum.posit.co/t/important-update-shinyapps-io-is-moving-to-connect-cloud/209804). Any decision should therefore compare Connect Cloud, not shinyapps.io, against options that run inside our own Azure tenant.

A standard hosting approach needs to provide:

- Sign-in with staff Microsoft accounts, with access limited to named Entra ID groups
- Secure access to internal data sources, such as databases and storage
- Data held in Australia, if the organisation's data classification requires it (to be confirmed)
- Repeatable deployment from source control, with a test environment before production
- Low ongoing effort for both the analysts and IT

Each option is judged on three criteria:

- **Supportability:** who supports it, and how well it fits our security, identity and operations model
- **Maintainability:** the effort to build it, patch it and publish new app versions
- **Cost:** licences, Azure consumption and staff effort

## Options considered

Five options were assessed. Two are external SaaS services, two use Azure services we already run, and one is commercial software hosted in our own Azure tenant.

| Option | What it is | Where it runs | Apps supported | How analysts publish |
| --- | --- | --- | --- | --- |
| 1. [Posit Connect Cloud](https://posit.co/products/enterprise/connect-cloud) | Posit's hosted publishing service, and the replacement for shinyapps.io | Posit's multi-tenant service on AWS, US-East-2 | Shiny (R and Python), Streamlit, Dash, Quarto and more | From GitHub, RStudio, VS Code or the command line |
| 2. [Streamlit Community Cloud](https://docs.streamlit.io/deploy/streamlit-community-cloud/manage-your-app) | Free hosting for Streamlit apps | Streamlit's shared service | Streamlit only | From a GitHub repository |
| 3. Azure App Service | Web App for Containers, deployed by Azure DevOps pipelines | Our Azure tenant, Australia East | Any containerised app | Push to Azure Repos; a shared pipeline builds and deploys |
| 4. Azure Container Apps | Serverless containers, deployed by Azure DevOps pipelines | Our Azure tenant, Australia East | Any containerised app | Push to Azure Repos; a shared pipeline builds and deploys |
| 5. [Posit Connect, self-hosted](https://docs.posit.co/reference-architectures/azure.html) | Commercial publishing server, licensed from Posit | A VM (or AKS cluster) in our Azure tenant | Shiny, Streamlit, Dash, Quarto, Plumber, FastAPI and more | One-click from RStudio or VS Code, Git-backed, or Azure Pipelines |

Options 3 and 4 use the same build and release pattern, shown below. Each app is packaged as a container image with a Dockerfile. Azure Pipelines builds the image, scans it and stores it in Azure Container Registry, then deploys it. Staff sign in through Entra ID, and the app reaches internal data over private endpoints using a managed identity.

&#91;embedded content: Build and release pattern for options 3 and 4 · 6 components\]

The same image runs on either host, so moving an app between Container Apps and App Service needs no rebuild.

Streamlit Community Cloud is listed for completeness only. It allows [one private app per workspace](https://discuss.streamlit.io/t/more-private-projects/39717), and Streamlit says it is not intended as an enterprise business solution. Apps [sleep after 12 hours without traffic](https://docs.streamlit.io/deploy/streamlit-community-cloud/manage-your-app), and [there is no SLA](https://discuss.streamlit.io/t/is-there-streamlit-app-limitations-such-as-usage-time-users-etc/42800). It is not assessed further.

## Supportability

The two Azure-native options are the most supportable. They run on services covered by our existing Microsoft agreement, and they use the identity, network and monitoring controls IT already operates. Posit Connect Cloud is supported by Posit, but it sits outside our tenant and our network, and it stores data in the United States.

|  | 1. Posit Connect Cloud | 3. App Service | 4. Container Apps | 5. Posit Connect, self-hosted |
| --- | --- | --- | --- | --- |
| Platform supported by | Posit | Microsoft | Microsoft | Microsoft (VM); Posit (software) |
| Who runs it day to day | Posit | Our platform team | Our platform team | Our platform team |
| Staff sign-in | Entra ID SSO on organisation plans | Entra ID through built-in authentication | Entra ID through built-in authentication | Entra ID SSO with SCIM user provisioning |
| Where data is held | [AWS US-East-2, multi-tenant](https://docs.posit.co/connect-cloud/user/platform/security.html) | Australia East | Australia East | Australia East |
| Access to internal data | Data sources must be reachable from Posit's service | Private endpoints and VNet integration | Private endpoints and VNet integration | Inside our VNet |
| Security evidence | [SOC 2 Type I](https://docs.posit.co/connect-cloud/whats-new/index.html) (July 2026) | Azure compliance, plus Defender for Cloud, Azure Policy and Log Analytics | Azure compliance, plus Defender for Cloud, Azure Policy and Log Analytics | Azure controls on the VM; Posit software under our patching regime |

**Key points**

- **Identity:** all four options can use Entra ID. With the Azure-native options, sign-in is a platform setting, not code. Microsoft notes that [any user in the tenant can get a token by default](https://learn.microsoft.com/azure/container-apps/authentication), so each app must be limited to its Entra group.
- **Shared responsibility:** with options 3 and 4, Microsoft supports the platform and our team supports the containers and pipeline. Shiny and Streamlit are open source, so problems inside an app are handled by the unit and the community, under every option.
- **Known technical risk:** older forum threads report that [WebSockets failed when built-in authentication was enabled on Linux App Service](https://discuss.streamlit.io/t/azure-appservice-with-authentication-issues/1970). Both frameworks depend on WebSockets. Others report Streamlit [running behind Entra sign-in on Container Apps](https://docs.microsoft.com/en-us/answers/questions/1660295/how-to-access-user-claims-in-python-application-co). The pilot must confirm this early.
- **Vendor dependency:** Posit is moving from shinyapps.io to Connect Cloud in 2026. Options 1 and 5 tie the unit to Posit's product roadmap and pricing. Options 3 and 4 use standard containers that can move between Azure services, or to another cloud.

## Maintainability

Connect Cloud needs the least maintenance, because Posit runs everything. The Azure-native options need a few weeks of up-front work on templates. After that, upkeep is small, mostly keeping container base images current. Self-hosted Posit Connect gives analysts the easiest publishing experience, but it adds a server that our team must patch and upgrade.

Effort figures are indicative estimates, to be confirmed with the platform team.

|  | 1. Posit Connect Cloud | 3. App Service | 4. Container Apps | 5. Posit Connect, self-hosted |
| --- | --- | --- | --- | --- |
| Initial build | Days: set up the organisation account and SSO | 3–6 weeks: templates, shared pipeline, infrastructure module, pilot app | 3–6 weeks: same as App Service | 2–4 weeks: VM, networking, SSO, backups, plus licence procurement |
| Ongoing upkeep | Minimal; plan and seat management | About 1–2 days a month: base image updates, pipeline fixes, plan sizing | About 1–2 days a month: same as App Service | About 2–4 days a month: OS patching, Connect upgrades, R and Python versions, backups |
| Analyst workflow | Publish from GitHub or the IDE | Push code to Azure Repos; the pipeline deploys | Push code to Azure Repos; the pipeline deploys | One-click publish from RStudio or VS Code, or Git-backed |
| Skills the unit needs | R or Python only | R or Python, plus Git and a template Dockerfile | R or Python, plus Git and a template Dockerfile | R or Python only |
| Skills IT needs | Account administration | Containers, Azure Pipelines, Bicep or Terraform | Containers, Azure Pipelines, Bicep or Terraform | Linux administration, Posit Connect administration |
| Test before production | Separate content items | Deployment slots, swapped into production | Revisions, with traffic splitting | Separate content items or a staging server |

**Key points**

- **Templates do most of the work.** In options 3 and 4, analysts copy a template repo for R or Python. Each repo has a working Dockerfile and a few lines that call a shared pipeline. Most analysts never need to edit the Dockerfile.
- **One pattern, two hosts.** Options 3 and 4 share images, pipelines and templates. Moving an app between them is a configuration change, not a rebuild.
- **Reproducible builds.** Package versions are pinned with `renv` (R) and `requirements.txt` or `uv` (Python). Each release is a versioned image, so a rollback means redeploying the previous image.
- **Framework constraints.** Shiny and Streamlit hold a live session for each user. Running more than one instance needs sticky sessions. On Container Apps, [sticky sessions only work in single revision mode](https://learn.microsoft.com/azure/container-apps/sticky-sessions), so traffic splitting is not available for multi-instance apps.

## Cost

Azure Container Apps is the cheapest option to run, at about A$65–210 a month for ten apps. App Service costs about A$315 a month at a fixed rate. Both Posit options charge per user, and their prices for our user numbers must be quoted. The Azure options need more staff time up front (see Maintainability).

| Option | Pricing model | Indicative monthly cost | What pushes it up |
| --- | --- | --- | --- |
| 4. Container Apps | Per second of vCPU and memory while an app is running; scales to zero when unused | A$65 (light use) to A$207 (every app busy all business day) | Apps kept warm all day, larger apps, more apps |
| 3. App Service | Fixed hourly rate per plan; many apps share one plan | A$315 | Adding a bigger or second production plan as apps grow |
| 1. [Posit Connect Cloud](https://posit.co/blog/introducing-posit-connect-cloud-advanced-plan) | Per seat; [every signed-in user, viewers included, needs a seat](https://docs.posit.co/connect-cloud/user/account/plans.html) | From US$249 for 5 seats. About 35 users needs a quote | Every new viewer adds a seat |
| 5. Posit Connect, self-hosted | Annual licence by named users, plus an Azure VM | A$249 for the VM, plus a licence quote | Licence tier and user count |

**How the Azure figures were built** (Australia East, pay-as-you-go list prices in AUD excluding GST, from the Azure Retail Prices API on 24 November 2026; enterprise agreement discounts would lower them):

- **App Service:** a production P1v3 Linux plan (2 vCPU, 8 GB) at A$0.2615 an hour = A$191. A test P0v3 Linux plan at A$0.1307 an hour = A$95. Container Registry Standard at A$0.947 a day = A$29.
- **Container Apps:** ten apps of 0.5 vCPU and 1 GiB each, at about A$0.0000483 per vCPU-second and A$0.0000057 per GiB-second, after the [monthly free grant](https://learn.microsoft.com/azure/container-apps/billing) of 180,000 vCPU-seconds and 360,000 GiB-seconds. Busy case: every app running 8 hours a day for 22 days = A$178. Light case: 2 hours a day = A$37. Container Registry Standard adds A$29 to both.
- **Self-hosted Posit Connect VM:** a D4s v5 Linux VM at A$0.3411 an hour = A$249, before disks and backup.

**Other costs to note**

- **Posit licences:** Posit does not publish prices for Connect on its own. As a reference point, the Posit Team bundle (Workbench, Connect and Package Manager) is listed at [US$42,435 a year for 10 developers and 20 business users](https://aws.amazon.com/marketplace/pp/prodview-xmm6qreyjiafq) on AWS Marketplace.
- **Azure DevOps:** we are assumed to have an organisation already. Analysts need a Basic licence to use Azure Repos, which is [free for the first 5 users, then US$6 per user per month](https://azure.microsoft.com/en-us/pricing/details/devops/). The [free Microsoft-hosted pipeline allowance is 1,800 minutes a month](https://azure.microsoft.com/en-au/pricing/details/devops/). R image builds are slow, so budget US$40 a month for an extra parallel job, or use a self-hosted agent.
- **Monitoring:** Log Analytics ingestion is similar across the Azure options and is excluded.
- **Staff time:** this is the largest cost of options 3 and 4 in year one (3–6 weeks of build). Option 5 also needs a few days of server upkeep every month.

## Summary comparison

Container Apps scores best overall, and App Service is a close second. Connect Cloud is the easiest for analysts, but it fails on data residency and network access. Self-hosted Posit Connect is a strong product, at a much higher cost.

| Criterion | 1. Posit Connect Cloud | 3. App Service | 4. Container Apps | 5. Posit Connect, self-hosted |
| --- | --- | --- | --- | --- |
| Supportability | Medium: run by Posit, but outside our controls | Strong | Strong | Medium: we run the server, Posit supports the software |
| Maintainability | Strong: least effort | Good, once templates exist | Good, once templates exist | Medium: server patching and upgrades |
| Analyst experience | Strong: one-click publishing | Medium: Git push with a template | Medium: Git push with a template | Strong: one-click publishing |
| Running cost (10 apps) | Medium: from US$249, rises with every viewer | Medium: about A$315 a month | Strong: about A$65–207 a month | Weak: VM plus licence |
| Security and identity | Medium: Entra SSO, outside our network | Strong | Strong | Strong |
| Data residency | Weak: United States | Strong: Australia East | Strong: Australia East | Strong: Australia East |
| Vendor lock-in | High | Low | Low | High |
| Overall | Not suitable for internal data | Good alternative | **Recommended** | Revisit if publishing volume grows |

## Recommendation and next steps

Adopt Azure Container Apps, deployed through a shared Azure DevOps pipeline, as the standard hosting platform for the unit's Shiny and Streamlit apps. Keep App Service as the fallback, since it uses the same images and pipeline. Do not adopt shinyapps.io, which closes on 31 December 2026, or Connect Cloud, for any app that uses internal data.

**Pilot (about 6–8 weeks)**

1. Choose two pilot apps, one Shiny and one Streamlit, that each read internal data.
2. Build the R and Python template repos, the shared pipeline template, a Container Registry, and a Container Apps environment in Australia East on our VNet.
3. Turn on Entra ID sign-in limited to one group. Confirm that WebSockets work behind sign-in, and that the app can read the signed-in user's identity.
4. Connect to one internal data source using a managed identity and a private endpoint.
5. Measure cold-start time and actual monthly cost. Set a minimum of one running instance for any app where the cold start is not acceptable.
6. Complete a security review, and write a one-page publishing guide for analysts.

If WebSockets fail behind built-in sign-in, or cold starts are unacceptable, move the pilot apps to App Service. That is a configuration change.

**Risks and open questions**

- Does our data classification require apps and data to stay in Australia? This decides whether Connect Cloud could be used for public or low-risk apps.
- Who owns the platform: the platform team, the Data Analysis unit, or both? A short responsibility matrix is needed before go-live.
- How many apps and viewers are expected in 12 months? If most apps need an instance running at all times, the costs converge. That is about A$35 per app a month on Container Apps, against A$25–30 per app as a share of a P1v3 plan. Posit quotes also depend on user numbers.
- Do the analysts already have Azure DevOps Basic licences?
- Are any apps on shinyapps.io now that must move before 31 December 2026?

**Sources:** the links in each section. Azure prices come from the Azure Retail Prices API (Australia East, AUD), queried on 24 November 2026.
