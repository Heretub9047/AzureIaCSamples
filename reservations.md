# Azure Reservations: Overview, Benefits, Risks and Recommendations

Oct 9, 2026 · @James

## Executive summary

Azure Reservations can cut the cost of steady, always-on workloads by roughly 30–70% compared with pay-as-you-go pricing, in exchange for a 1- or 3-year commitment. They are a billing discount, not a technical change: nothing is redeployed, and the discount applies automatically to any matching resource.

The trade-off is commitment and oversight. A reservation is paid for every hour of its term whether or not a matching resource exists, so it needs an owner, regular utilisation checks, and a clear purchasing process.

**Recommendation:** buy reservations only for workloads that have run at a stable size for at least 30–60 days and are expected to run for the full term. Start with Virtual Machines, App Service Plans, Azure SQL Database (vCore) and Fabric capacities, review utilisation monthly, and treat purchases as a joint decision between the platform team and procurement.

| Audience | What to read |
| --- | --- |
| Procurement and finance | Executive summary, What is a reservation, Pros, Cons, Recommendations, Glossary |
| Technical teams | All sections, especially Key considerations and Eligible resources |

## What is an Azure Reservation?

An Azure Reservation is a commitment to pay for a specific amount of a specific Azure service, in a specific region, for 1 or 3 years. In return, Microsoft charges a much lower rate than pay-as-you-go.

**Plain-English analogy:** pay-as-you-go is like paying for a hotel room night by night. A reservation is like signing a 12-month lease: each night is far cheaper, but you pay rent whether you sleep there or not. Unlike a lease, though, you are renting *a type of room*, not room 204 — any room of that type you use is covered.

### How it works

- **It is a billing discount only.** Buying a reservation does not create, change or reserve any resource. Your existing resources keep running exactly as before; the bill changes.
- **It is applied hour by hour.** Every hour, Azure looks for running resources that match the reservation (service, SKU/size, region, scope). Matching usage is billed at the reserved rate instead of the pay-as-you-go rate.
- **Unused hours are lost.** If in a given hour nothing matches, that hour of the reservation is wasted. It does not roll over.
- **Usage above the reservation is billed normally.** If you reserve 2 VMs and run 3, one is charged at pay-as-you-go.

### Purchase options

| Option | Choices | Notes |
| --- | --- | --- |
| Term | 1 year or 3 years | 3 years gives a larger discount but a longer commitment |
| Payment | Upfront or monthly | Monthly costs the same in total; it spreads the cash flow and does not reduce the commitment |
| Scope | Shared, management group, single subscription, or single resource group | Controls which resources are eligible for the discount (see Key considerations) |
| Auto-renew | On or off | If on, a new reservation is bought automatically when the term ends |

**Example:** a production web server runs 24×7 on a D4s v5 VM in Australia East. The team buys a 3-year reservation for one D4s v5 in Australia East, paid monthly. From the next hour, that VM's compute is billed at the reserved rate. Nothing about the VM changes, and nobody needs to touch it.

## Why use reservations?

Reservations make sense when a workload is predictable: it runs most of the time, at a known size, in a known region, and will still be needed in 1–3 years. For that kind of workload, pay-as-you-go means paying a premium for flexibility that is never used.

**Good candidates**

- Production servers and databases that run 24×7
- Shared platform services (domain controllers, gateways, monitoring, integration servers)
- App Service Plans hosting long-lived business applications
- Fabric capacities that support daily reporting and data pipelines

**Poor candidates**

- Dev/test environments that are shut down overnight or at weekends
- Workloads being migrated, re-architected or decommissioned in the next 12 months
- Anything that scales up and down heavily (cover only the steady baseline, not the peaks)
- New workloads whose size is still being tuned

**Rule of thumb:** if a resource runs more than about 60–70% of the hours in a month and will exist for the full term, a reservation will almost always save money. Below that, the discount may not cover the hours the reservation sits idle (see the break-even example under Cons).

## Pros

### 1. Cost savings (the main benefit)

Microsoft advertises savings of up to about 72% on VMs for a 3-year term, and up to about 80% when combined with Azure Hybrid Benefit. Typical savings vary by service: roughly 30–45% for 1 year and 50–65% for 3 years on compute. Fabric capacity reservations save roughly 40%. Always confirm the current rate in the Azure pricing calculator or the portal's purchase screen.

**Worked example (illustrative prices, AUD):** one VM costs $0.40 per hour on pay-as-you-go and runs all month (730 hours).

| Pricing | Effective hourly rate | Monthly cost | Annual cost | Saving vs pay-as-you-go |
| --- | --- | --- | --- | --- |
| Pay-as-you-go | $0.40 | $292 | $3,504 | — |
| 1-year reservation (\~40% off) | $0.24 | $175 | $2,102 | $1,402 per year |
| 3-year reservation (\~60% off) | $0.16 | $117 | $1,402 | $2,102 per year ($6,306 over 3 years) |

Across a fleet of 50 such VMs, the 3-year option would save around $105,000 per year.

### 2. Budget predictability

A reservation fixes the price of the committed portion of the bill for the whole term. Finance can forecast that spend with confidence, and it is protected from pay-as-you-go price rises during the term.

### 3. No technical change or downtime

The discount is applied by billing. No redeployment, no configuration change, no outage. Engineering teams can keep managing resources as normal.

### 4. Flexibility built in

- **Not tied to a single resource.** The discount moves automatically to any matching resource (see Key considerations).
- **Instance size flexibility (VMs).** A reservation can cover different sizes in the same VM series group, e.g. one D4s v5 reservation can cover two D2s v5 VMs.
- **Scope can be changed after purchase,** e.g. from one subscription to shared across the enrolment.
- **Exchanges and refunds.** Reservations can generally be exchanged for another of equal or greater value, and cancelled for a pro-rated refund, subject to a limit (currently USD 50,000 of refunds in a rolling 12 months). Microsoft has signalled changes to exchange rules for compute, so check the current policy before relying on it.

### 5. Cash-flow choice at no extra cost

Monthly payment costs the same in total as upfront. Upfront may suit capital budgeting or year-end spend; monthly suits operating budgets.

### 6. Stacks with other discounts

Reservations combine with Azure Hybrid Benefit (reusing existing Windows Server and SQL Server licences) and with Enterprise Agreement or negotiated pricing, so savings compound.

### 7. Built-in purchase recommendations

Azure Advisor and the Reservations purchase screen recommend what to buy based on the last 7, 30 or 60 days of actual usage, which reduces guesswork.

## Cons

### 1. It is a commitment

Once bought, the organisation pays for the reservation for the whole term (1 or 3 years), whether it is used or not. Paying monthly does not change this: it is a payment plan, not a monthly subscription that can be stopped. Exchanges and refunds exist but are limited, capped and subject to policy change, so they should be treated as a safety valve, not a plan.

### 2. Unused reservations are wasted money

If a matching resource is not running in a given hour, that hour is paid for and lost. A reservation only saves money when its utilisation stays above the break-even point.

**Break-even example (same illustrative VM):** a 1-year reservation costs $2,102. Pay-as-you-go for the same VM costs $292 per month. If the VM only runs for 7 months before being decommissioned, pay-as-you-go would have cost $2,044 — slightly *less* than the reservation. At a 40% discount, the reservation must be used at least about 60% of the time just to break even; at a 60% discount, about 40%.

### 3. Management overhead

Reservations need ongoing care that pay-as-you-go does not:

- Someone must own each reservation, check its utilisation and act on low usage.
- Purchases need analysis (what to buy, what size, which scope, which term) and approval.
- Renewals and expiry dates must be tracked, or the organisation silently falls back to pay-as-you-go prices.
- Engineering changes (resizing, moving region, switching VM series, migrating to PaaS) must be coordinated with the reservation portfolio.

### 4. Monitoring is required

Utilisation is not visible unless someone looks at it or sets up alerts. A reservation can sit at 0% for months unnoticed after a VM is resized or deleted. Regular reviews and utilisation alerts are needed (see Monitoring and governance).

### 5. Reduces technical agility

A large reservation commitment can create pressure to keep using an older VM series, region or architecture to "use up" the reservation, even when a better or cheaper option exists. Plans for modernisation should be checked before buying 3-year terms.

### 6. Cost allocation is less straightforward

With shared scope, the discount lands on whichever matching resource Azure picks, which may be in another team's subscription. Chargeback and showback reports need the *amortised* cost view in Cost Management to allocate reservation costs fairly.

## Key considerations

### Reservations follow the SKU, not the resource

A reservation is not attached to a named VM, database or plan. It is attached to a **SKU (size/tier) in a region, within a scope**. Every hour, Azure applies it to whatever matching resources happen to be running.

&#91;embedded content: reservation matching · 1 match, 2 misses\]

Only VM-B gets the discount. VM-A and VM-C are billed at full price, and if VM-B did not exist the reservation would still be charged.

**Scenario walk-through** — one reservation for a D4s v5 VM in Australia East, shared scope:

| Situation | What happens to the reservation | Cost impact |
| --- | --- | --- |
| VM-A (D4s v5) is running | Discount applies to VM-A | Saving realised |
| VM-A is deleted; VM-B (D4s v5, same region, in scope) is created | Discount moves to VM-B automatically, no action needed | Saving continues |
| VM-A and VM-B both run | Discount covers one of them; the other is pay-as-you-go | Partial saving |
| VM-A is resized to E4s v5 | No match (different series) — reservation goes unused | Paying for the reservation **and** pay-as-you-go for the VM |
| VM-A is moved to Australia Southeast | No match (different region) | Reservation wasted |
| VM-A is deallocated (stopped) overnight | No match during those hours | Those hours are wasted |
| No D4s v5 runs anywhere in scope | Reservation sits idle | 100% wasted, still billed |

The last three rows are the most common cause of wasted reservation spend, and they are usually caused by routine engineering changes made without checking the reservation portfolio.

### Instance size flexibility (VMs)

VM reservations can flex across sizes within the same series group, using a ratio. For example, a reservation for one D4s v5 (4 vCPU) can instead cover two D2s v5 VMs, or half of a D8s v5. Flexibility does **not** cross series (D to E), generations (v4 to v5) or regions.

### Scope choice

| Scope | Discount applies to | Best for |
| --- | --- | --- |
| Shared | All eligible subscriptions in the billing account/enrolment | Maximising utilisation (recommended default) |
| Management group | Subscriptions under that management group | Business-unit level purchasing |
| Single subscription | One subscription | Clear chargeback to one team |
| Single resource group | One resource group | Tight cost ownership, highest risk of waste |

Narrower scopes make cost ownership clearer but increase the chance a reservation goes unused. Shared scope gives the best utilisation.

### Region

Most reservations are region-specific. A reservation in Australia East does nothing for resources in Australia Southeast, including DR resources that only run during a failover.

### What is (and is not) covered

A VM reservation covers **compute only**. Storage (disks), networking, and software licences (Windows Server, SQL Server, RHEL) are billed separately. Licences can be reduced with Azure Hybrid Benefit or separate software plans. Similar rules apply to SQL Database: the reservation covers vCore compute, not storage or backup.

### Reservations vs Azure Savings Plans

Azure Savings Plan for compute is a commitment to spend a fixed amount per hour (e.g. $10/hour) on compute for 1 or 3 years, across any region and VM series, plus some App Service and Container Apps usage.

|  | Reservation | Savings plan |
| --- | --- | --- |
| Commitment | A specific SKU in a specific region | A fixed hourly spend on eligible compute |
| Typical discount | Higher (up to \~72% on VMs) | Lower (up to \~65%) |
| Flexibility | Limited to the series group and region | Any region, series or size; some PaaS |
| Best for | Very stable workloads that will not change | Workloads likely to be resized, moved or modernised |

Many organisations use both: reservations for the very stable core, a savings plan for the changing remainder. Reservations are applied first, then the savings plan.

### Expiry and renewal

When a reservation expires, resources silently revert to pay-as-you-go pricing. Azure sends expiry emails, but they often go to the original purchaser. Decide per reservation whether auto-renew is on, and review each one 60–90 days before expiry.

### Permissions and purchasing process

Only users with the right billing roles (for example, Reservation Purchaser, or Owner on the subscription with purchasing enabled on the billing account) can buy reservations. Limit purchase rights to a small group, and route purchases through an agreed approval process with procurement, as each is a multi-year financial commitment.

### Capacity is not guaranteed

A standard reservation is a billing discount; it does not guarantee that capacity for that VM size is available. If guaranteed capacity is needed (e.g. for DR), use On-demand Capacity Reservations, which can be combined with a reservation.

## Eligible resources

The four services below are the priority for this organisation. Each has its own matching rules, so the "what must match" line is the key thing to check before buying.

### Virtual Machines

- **What is reserved:** compute hours for a VM size (e.g. D4s v5) in a region.
- **What must match:** VM series group and region, within scope. Instance size flexibility lets a reservation cover other sizes in the same series group.
- **Not covered:** OS/software licences, disks, networking, bandwidth.
- **Also applies to:** VM Scale Set instances, AKS node pools and Azure Virtual Desktop session hosts running the same size — a useful way to absorb reservations when standalone VMs are retired.
- **Example:** 10 domain controllers, jump hosts and app servers run 24×7 on D2s v5 and D4s v5 in Australia East. A 3-year reservation covering the equivalent of 14 D2s v5 units removes most of their compute cost from pay-as-you-go. Windows licence cost is addressed separately through Azure Hybrid Benefit.

### App Service Plans

- **What is reserved:** instances of an App Service Plan tier — currently Premium v3 (P0v3–P5mv3) and Isolated v2 tiers, plus the Isolated stamp fee.
- **What must match:** the plan tier and size, and region. Basic, Standard and Premium v2 tiers are not eligible.
- **Watch for:** autoscaling. Reserve only the minimum instance count that always runs; scale-out instances are billed pay-as-you-go. Moving a plan to Premium v2 or to a different size will stop the match.
- **Example:** a customer portal runs on a P1v3 plan with a minimum of 2 instances and scales to 6 at peak. Reserve 2 × P1v3, not 6.
- **Alternative:** App Service Premium v3 is also covered by Azure Savings Plan for compute, which is more forgiving if the plan may change size.

#### Consolidate first, then reserve

In this organisation, consolidating App Service Plans saves more than reserving them. Many plans run one or two lightly used apps, so the organisation pays for idle capacity whether or not it is reserved. Packing more apps into fewer plans removes that idle capacity outright, with no term commitment.

**Example (illustrative):** 10 apps each run on their own P1v3 plan, most below 15% CPU. Consolidating them onto 3 P1v3 plans removes 7 plans, cutting instance cost by about 70%. A reservation on the original 10 plans would save only about 35–55%. Reserving the 3 remaining plans afterwards adds a further discount on top.

**Check before consolidating:**

- Apps can only share a plan if they are in the same region, resource group and OS (Windows and Linux cannot mix).
- Apps in a plan share CPU, memory and scaling, so one busy app can slow the others. Keep high-load or business-critical apps separate.
- Security and network needs (VNet integration, isolation, compliance boundaries) may require separate plans.
- Deployments, restarts and platform maintenance affect every app in the plan.
- Monitor CPU and memory for 2–4 weeks after consolidating before buying a reservation for the new layout.

**Sequence:** right-size and consolidate first, let the new layout settle, then reserve only the plans that remain. Reserving before consolidating locks in the commitment to plans that may later be removed.

### Azure SQL Database (and Managed Instance)

- **What is reserved:** vCores for the vCore purchasing model — single databases, elastic pools and SQL Managed Instance, for General Purpose, Business Critical and Hyperscale tiers.
- **What must match:** deployment type, service tier, hardware generation, and region. vCore size flexibility applies within the same tier and hardware, so 8 reserved vCores can cover one 8-vCore database or two 4-vCore databases.
- **Not eligible:** the DTU purchasing model (Basic/Standard/Premium), serverless compute, and storage or backup costs.
- **Watch for:** combine with Azure Hybrid Benefit if the organisation has SQL Server licences with Software Assurance — the reservation covers compute, AHB covers the licence component.
- **Example:** a finance database runs on a General Purpose, 8-vCore provisioned database. A 3-year reservation for 8 General Purpose vCores covers it; if the team later splits it into two 4-vCore databases, the reservation still applies.

### Microsoft Fabric capacities

- **What is reserved:** Capacity Units (CUs). Fabric F SKUs are measured in CUs (F2 = 2 CUs, F64 = 64 CUs).
- **What must match:** Fabric capacities in the same region and scope. Because the reservation is in CUs, it is flexible across F SKU sizes — 64 reserved CUs can cover one F64, or two F32s.
- **Saving:** roughly 40% compared with pay-as-you-go for a 1-year term.
- **Watch for:** pausing. Pay-as-you-go Fabric capacities are often paused out of hours to save money; with a reservation, paused hours still cost the same, so the pausing saving disappears. Scaling above the reserved CUs is billed at pay-as-you-go. Compare the reserved cost against current pay-as-you-go-with-pausing cost before buying.
- **Example:** the analytics team runs an F64 capacity 24×7 for scheduled refreshes and Power BI reports. Reserving 64 CUs in Australia East covers it. If they also stand up an F8 for testing, reserve only the F64 and leave the test capacity on pay-as-you-go so it can be paused.

### Other services that support reservations

These are worth reviewing once the four priority services are in place.

| Service | What is reserved |
| --- | --- |
| Azure Database for PostgreSQL / MySQL (Flexible Server) | vCores of compute |
| Azure Cosmos DB | Provisioned throughput (RU/s) |
| Azure Cache for Redis | Cache instances (Premium and Enterprise tiers) |
| Azure Blob Storage and Data Lake Storage Gen2 | Storage capacity in 100 TB or 1 PB blocks |
| Azure Files | Storage capacity in 10 TB or 100 TB blocks |
| Azure Managed Disks | Premium SSD disks (P30 and larger) |
| Azure Databricks | Pre-purchased Databricks Commit Units (DBCU) |
| Azure Synapse Analytics | Dedicated SQL pool data warehouse units (cDWU) |
| Azure Data Explorer | Markup units |
| Azure Dedicated Host | Host compute |
| Azure VMware Solution | Dedicated hosts |
| Red Hat / SUSE software plans | Linux software licence cost for VMs |
| Azure Backup | Backup storage capacity |

The list of eligible services changes over time; the Azure portal's Reservations > Add screen shows the current list for the organisation's billing account.

## Monitoring and governance

The goal is to keep every reservation above 95% utilisation and never let one expire or sit idle unnoticed. That needs named owners, built-in Azure tooling, and a monthly review.

### Tools available in Azure

| Tool | What it shows | Use it for |
| --- | --- | --- |
| Azure portal – Reservations | Each reservation's daily and 30-day utilisation, scope, expiry | Spotting under-used reservations |
| Cost Management – reservation utilisation alerts | Email when utilisation drops below a threshold (e.g. 90%) | Early warning after resizes or deletions |
| Cost Management – amortised cost view | Reservation cost spread across the resources that used it | Chargeback/showback to teams |
| Azure Advisor / purchase recommendations | Suggested purchases from 7, 30 or 60 days of usage | Finding new savings |
| Cost Management Power BI app or exports | Utilisation and savings trends over time | Monthly reporting to management |

### Roles and responsibilities

| Role | Responsibility |
| --- | --- |
| Platform / cloud team | Identifies candidates, sizes purchases, monitors utilisation, coordinates engineering changes |
| Workload owners | Tell the platform team before resizing, moving region or decommissioning reserved resources |
| Procurement / finance | Approves purchases, holds the commitment register, chooses upfront vs monthly payment |
| Reservation administrators | Small named group with rights to buy, exchange, change scope and set auto-renew |

### Recommended process

1. **Identify:** monthly, review Advisor recommendations and resources running steadily for 30–60+ days.
2. **Validate:** confirm with the workload owner that the resource will keep its size, series and region for the term.
3. **Approve:** submit a short business case (cost, saving, term, risk) to procurement/finance.
4. **Purchase:** buy with shared scope by default; record it in a reservation register (owner, SKU, region, term, expiry, auto-renew).
5. **Monitor:** utilisation alerts below 90%; monthly review of every reservation.
6. **Remediate:** for low utilisation, move a workload onto the reserved SKU, widen scope, or exchange.
7. **Renew:** review 60–90 days before expiry; renew, resize or let lapse.

### Key measures to report

- Reservation utilisation (%), overall and per reservation — target above 95%
- Reservation coverage (%) — the share of eligible steady-state usage that is reserved
- Savings realised versus pay-as-you-go, per month and year to date
- Reservations expiring in the next 90 days

### Change management

Add a check to the change process: any change that resizes, moves, stops or deletes a VM, App Service Plan, SQL database or Fabric capacity should ask "is this covered by a reservation?" This single step prevents most wasted reservation spend.

## Recommendations and next steps

Start small with the most stable workloads, prove the savings and the monitoring process, then expand.

1. **Baseline:** export the last 60–90 days of usage for VMs, App Service Plans, SQL Database and Fabric capacities, and list resources running more than 70% of hours.
2. **Agree the policy:** default to shared scope, monthly payment unless finance prefers upfront, and 1-year terms for anything with modernisation plans; 3-year terms only for workloads confirmed stable.
3. **First purchase wave:** cover the steady baseline only (aim for 70–80% coverage of steady usage, not 100%), leaving headroom for change.
4. **Set up monitoring:** utilisation alerts, a reservation register, and a monthly review with the platform team and procurement.
5. **Consider a savings plan** for compute that is likely to change size, region or series.
6. **Review after 3 months:** report realised savings and utilisation, then plan the next wave.

### Pre-purchase checklist

- [ ] Resource has run at a stable size for at least 30–60 days
- [ ] Workload owner confirms it will run for the full term in the same region and series
- [ ] No planned migration, re-architecture or decommission within the term
- [ ] Utilisation (hours running per month) is well above break-even
- [ ] Scope chosen (shared by default) and documented
- [ ] Azure Hybrid Benefit considered for Windows/SQL licences
- [ ] Savings plan considered as an alternative
- [ ] Business case approved by procurement/finance
- [ ] Owner, expiry date and auto-renew setting recorded in the register
- [ ] Utilisation alert configured

## Glossary

| Term | Meaning |
| --- | --- |
| Pay-as-you-go (PAYG) | Standard Azure pricing: pay per hour of use, no commitment |
| Reservation (Reserved Instance, RI) | 1- or 3-year commitment to a specific service SKU in a region, in exchange for a discount |
| SKU | The specific size or tier of a resource, e.g. D4s v5 VM or P1v3 App Service Plan |
| Region | The Azure data centre location, e.g. Australia East |
| Scope | Which subscriptions or resource groups a reservation's discount can apply to |
| Utilisation | Percentage of reserved hours actually used by matching resources |
| Coverage | Percentage of eligible steady usage that is covered by reservations |
| Instance size flexibility | Ability of a VM reservation to cover different sizes in the same series |
| vCore | A virtual CPU core, used to size SQL Database and other PaaS databases |
| Capacity Unit (CU) | The unit of compute for Microsoft Fabric capacities |
| Azure Hybrid Benefit (AHB) | Reusing existing Windows Server/SQL Server licences to reduce Azure cost |
| Savings plan | Commitment to a fixed hourly spend on eligible compute, more flexible than a reservation |
| Amortised cost | A cost view that spreads reservation charges across the resources that used them |

## References

Prices and percentages in this paper are approximate and illustrative, based on Microsoft's published guidance; confirm current rates and policies in the Azure pricing calculator and portal before purchase.

- [What are Azure Reservations?](https://learn.microsoft.com/azure/cost-management-billing/reservations/save-compute-costs-reservations)
- [Self-service exchanges and refunds for Azure Reservations](https://learn.microsoft.com/azure/cost-management-billing/reservations/exchange-and-refund-azure-reservations)
- [Virtual machine size flexibility with Reserved VM Instances](https://learn.microsoft.com/azure/virtual-machines/reserved-vm-instance-size-flexibility)
- [Save costs with Azure App Service reserved instances](https://learn.microsoft.com/azure/cost-management-billing/reservations/prepay-app-service)
- [Save costs for Azure SQL Database resources with reserved capacity](https://learn.microsoft.com/azure/azure-sql/database/reserved-capacity-overview)
- [Save costs with Microsoft Fabric Capacity reservations](https://learn.microsoft.com/azure/cost-management-billing/reservations/fabric-capacity)
- [Azure savings plan for compute](https://learn.microsoft.com/azure/cost-management-billing/savings-plan/savings-plan-compute-overview)
- [Reservation utilisation alerts](https://learn.microsoft.com/azure/cost-management-billing/costs/reservation-utilization-alerts)
