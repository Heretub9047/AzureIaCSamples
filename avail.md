# Azure Geo-Redundancy Risk Assessment

Nov 4, 2026 · @James

## Summary

**Risk as registered:** some Azure systems may not have geo-redundancy, which could lead to outages in the event of an Azure outage.

The risk is valid and should stay on the register. It should not be treated with a blanket "all systems must be multi-region" control. Each system should be assessed against the availability the business actually needs, and only systems whose required availability cannot be met in one region should carry the cost and complexity of a second region (Australia Southeast).

## 1. The risk is real

Azure outages have affected both of our Australian regions, and some failures are global rather than regional. A single 24-hour outage takes a single-region system to about 99.73% availability for that year, which is below three nines.

| Date (UTC) | Incident | Australian impact | Impact window |
| --- | --- | --- | --- |
| 30 Sep – 1 Oct 2026 | Gateway service degradation (ExpressRoute, VPN Gateway, Application Gateway, Firewall, Bastion, Virtual WAN), PIR 7Q30-010 ([Microsoft](https://azure.status.microsoft/en-us/status/history/)) | Australia Southeast and Australia Central 2 named as affected | 20:30 – 02:15, about 5 h 45 m |
| 29 – 30 Oct 2025 | Azure Front Door and CDN global disruption caused by incompatible configuration metadata, PIR YKYN-BWZ ([Microsoft retrospective](https://aka.ms/air/YKYN-BWZ)) | Global service, so apps in every region behind Front Door were affected, including Australia East and Southeast ([example](https://pingoru.io/providers/umbrellar/incidents/59132)) | 15:41 – 00:05, about 8 h 24 m |
| 30 Aug 2023 | Australia East: a utility power sag tripped cooling units in one datacentre in one availability zone, and storage shut down to protect hardware ([iTnews](https://www.itnews.com.au/news/bank-of-queensland-jetstar-among-australian-enterprises-impacted-by-azure-outage-599803)) | About half of the region's Cosmos DB clusters down or degraded; Bank of Queensland and Jetstar affected ([DCD](https://datacenterdynamics.com/en/news/microsofts-slow-outage-recovery-in-sydney-due-to-insufficient-staff-on-site)) | Some customers degraded for more than 24 h ([summary](https://medhacloud.com/blog/azure-outage-history)) |

What this means for the register:

- **Failure scope varies.** Microsoft rates hardware failures as high likelihood, datacentre failures as medium and full-region failures as low ([Well-Architected](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/regions-availability-zones)). Region-level events are rarer but longer and harder to work around.
- **A second region does not cover everything.** Global services such as Front Door, identity and DNS sit in front of both regions, so they need their own mitigation.
- **An SLA is not a guarantee of uptime.** Azure SLAs pay service credits when breached; Microsoft itself advises extra ingress paths for mission-critical apps for this reason ([Microsoft](https://learn.microsoft.com/en-us/azure/architecture/guide/networking/global-web-applications/mission-critical-global-http-ingress)).

## 2. Evaluate system by system

A single rule for every system would either leave critical systems under-protected or spend multi-region money on systems that do not need it. Microsoft's guidance is to prioritise each workload and give it its own uptime target, recovery time and data-loss tolerance ([Cloud Adoption Framework](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/manage/protect)); it also notes that most workloads do not need extremely high availability ([Well-Architected](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/regions-availability-zones)).

For each Azure system in scope, record:

- **Business owner and criticality tier** (high, medium or low).
- **Impact of an outage per hour**: revenue, safety, regulatory, customer or reputational.
- **Required availability (SLO)** and **maximum tolerable outage (RTO)**.
- **Tolerable data loss (RPO)**.
- **Current architecture**: single instance, redundant in one datacentre, zone-redundant, or multi-region, and which components lack zone support.
- **Critical-path dependencies**, including shared ones: Entra ID, DNS, Front Door, ExpressRoute or VPN, firewalls, on-premises links and third-party APIs.
- **Data residency constraints.** Australia East and Australia Southeast keep data onshore.
- **Gap and treatment**: the difference between required and achievable availability, and whether it will be remediated or formally accepted.

Only systems with a material gap need investment. The rest can be closed with a documented risk acceptance signed by the business owner.

## 3. Considerations based on required availability and uptime

Each extra nine cuts the allowed downtime tenfold, and the architecture needed changes at almost every step. The required availability should come from the business impact in section 2, not from what the platform can offer.

| Availability | Nines | Allowed downtime per year | Per month (30 days) | Design usually needed in Azure |
| --- | --- | --- | --- | --- |
| 99% | Two | 87.6 h (3.65 days) | 7.2 h | Single instance, restore from backup |
| 99.9% | Three | 8.76 h | 43.2 min | Single region, platform-managed services |
| 99.95% | Three and a half | 4.38 h | 21.6 min | Redundant instances, ideally across availability zones |
| 99.99% | Four | 52.6 min | 4.32 min | Zone-redundant in every tier, plus a second region with automated failover |
| 99.999% | Five | 5.26 min | 26 s | Active-active in two regions, redundant global routing; rarely justified |

Microsoft's own example tiers set 99.99% for mission-critical workloads using multiple regions with zones in each, and only 99% for low-priority workloads in a single zone-redundant region ([Cloud Adoption Framework](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/manage/protect)).

Things to weigh for each system:

- **The chain is weaker than its links.** Availability of a system is the product of everything on its critical path. Microsoft's example: App Service at 99.95% calling Azure SQL at 99.99% gives 99.94%.
- **RTO must fit inside the downtime budget.** Four nines allows 52.6 minutes a year. A manual failover that takes an hour uses more than the whole allowance, so four nines effectively requires automated failover. Microsoft suggests dividing the annual allowance by the expected number of failures: four failures a year at 99.99% means a 13-minute RTO.
- **Cross-region data is usually asynchronous.** Failing over to Australia Southeast can lose the most recent writes, so the RPO is above zero unless the design accepts the latency of synchronous replication.
- **Measure from the user's side.** An Azure SLA defines availability per service, which may not match how users experience the system ([Well-Architected](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/regions-availability-zones)).
- **Scheduled hours matter.** A system used 8 am to 6 pm on weekdays may tolerate outages outside those hours that a 24×7 customer system cannot.

## 4. Complexity and cost of true multi-region in Azure

A true multi-region system runs a second full set of resources and adds data, network and operational work that never goes away. Microsoft rates multi-region as high cost and high operational effort, against moderate cost and low effort for a zone-redundant single region ([Well-Architected](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/regions-availability-zones)).

**Australia-specific constraints**

- **Australia Southeast has no availability zones.** Australia East has three ([Microsoft regions list](https://learn.microsoft.com/en-us/azure/reliability/regions-list), updated October 2026). Microsoft has announced zones for Melbourne ([DCD](https://www.datacenterdynamics.com/en/news/microsoft-to-expand-melbourne-azure-region-with-more-availability-zones)), but none are listed yet. After a failover, the system runs at a lower availability until it fails back.
- **Not every service or size exists in both regions.** Each component must be checked against Australia Southeast, and a regional outage can cause capacity shortages as customers fail over at the same time ([Microsoft](https://learn.microsoft.com/azure/well-architected/mission-critical/mission-critical-application-platform)).
- **The two regions are a pair**, which helps: Azure staggers planned updates across them and prioritises recovery of one region in a pair during a wide outage ([Microsoft](https://learn.microsoft.com/en-ie/azure/reliability/cross-region-replication-azure)).

| Area | What multi-region requires | Cost and effort impact |
| --- | --- | --- |
| Compute | A second deployment in Australia Southeast, running (active-active) or on standby (active-passive) | Active-active pays for two full environments; standby is cheaper but fails over more slowly |
| Data | Geo-replication for databases and storage (SQL failover groups, GRS or object replication, Cosmos DB multi-region) | Secondary copies and inter-region data transfer are charged; asynchronous replication means some data loss on failover |
| Global routing | Azure Front Door or Traffic Manager with health probes and DNS changes | Adds a shared global dependency that can itself fail, as in October 2025 |
| Network and security | Duplicate hub network, firewalls, private endpoints, Key Vault, DNS zones, ExpressRoute or VPN to the second region | Often the most overlooked cost and the most common failover blocker |
| Application | Stateless tiers, retry logic, no hard-coded region settings, tolerance of replication lag | Development effort; legacy apps may need re-architecture |
| Operations | Infrastructure as code for both regions, runbooks, monitoring in both, regular failover and failback tests | Ongoing staff time; an untested failover often fails when it is needed |
| Licensing | Third-party licences for standby servers | Varies by vendor |

## 5. Examples

For a typical web application, Microsoft's financially backed SLAs give about three nines in a single region, about three and a half nines with availability zones, and four nines across Australia East and Australia Southeast. Each example uses the same workload: a web tier on virtual machines and an Azure SQL Database.

&#91;embedded content: example designs 1b, 2 and 3 · web tier + Azure SQL Database\]

In example 3, Front Door is the one component both regions share, which is why that design tops out at four nines.

| Example | Design | Critical path (SLA of each component) | Composite availability | Nines | Max downtime per year |
| --- | --- | --- | --- | --- | --- |
| 1a. Single region, single VM | Australia East or Southeast: 1 VM on Premium SSD + Azure SQL Database | VM 99.9% × SQL 99.99% | 99.89% | Just under three | 9.6 h |
| 1b. Single region, redundant VMs | Australia East or Southeast: 2 VMs in an availability set behind a Standard Load Balancer + Azure SQL Database | VM 99.95% × Load Balancer 99.99% × SQL 99.99% | 99.93% | Three | 6.1 h |
| 2. Single region with availability zones | Australia East: VMs across 2+ zones behind a zone-redundant Standard Load Balancer + zone-redundant Azure SQL Database (Business Critical) | VM 99.99% × Load Balancer 99.99% × SQL 99.995% | 99.975% | Three and a half | 2.2 h |
| 3. Multi-region | Example 2 in Australia East + Example 1b in Australia Southeast, SQL geo-replication, Azure Front Door in front of both | Front Door 99.99% × \[1 − (1 − 99.975%) × (1 − 99.93%)\] | 99.99% | Four | 53 min |

Component SLAs: VMs 99.9% single instance, 99.95% availability set, 99.99% across zones ([Microsoft Online Services SLA](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services)); Standard Load Balancer 99.99% ([Microsoft](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-best-practices)); Azure SQL 99.99%, or 99.995% when zone-redundant ([Microsoft](https://learn.microsoft.com/en-us/training/modules/azure-sql-high-availability/7-higher-availablity-options)); Front Door 99.99% ([Microsoft](https://azure.microsoft.com/en-gb/updates/azure-front-door-service-is-now-available/)). Components in a chain multiply; regions that can each serve the system combine in parallel ([Cloud Adoption Framework](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/manage/protect)):

```latex
A_{\text{chain}} = A_1 \times A_2 \times \cdots \times A_n
```

```latex
A_{\text{two regions}} = 1 - (1 - A_{\text{East}})\,(1 - A_{\text{Southeast}})
```

What the examples show:

- **Zones cut the downtime allowance by almost two-thirds** (6.1 h down to 2.2 h a year) at moderate cost, and they cover the most likely failures: a datacentre or zone, as in August 2023. This is only possible in Australia East.
- **Four nines per component is not four nines end to end.** Example 2 chains three 99.99%-class services and lands at 99.975%.
- **The global entry point caps a multi-region design.** The two regional stacks together reach 99.99998%, but every request passes through Front Door at 99.99%, so the system tops out at four nines. Five nines needs a second, independent ingress path such as Traffic Manager with Application Gateway, and Traffic Manager then becomes the global point of failure ([Microsoft](https://learn.microsoft.com/azure/architecture/guide/networking/global-web-applications/overview)).
- **Example 3 assumes fast, automated failover.** A manual failover taking an hour during one regional outage uses more than the year's four-nines allowance.
- **After failover the system runs at Example 1b levels** (99.93%), because Australia Southeast has no zones, until it fails back to Australia East.
- **These are SLA figures, not predictions.** Real availability also depends on the application, deployments, configuration changes and shared services such as identity.

## Recommendation for the risk register

Keep the risk open, reword it so it can be measured, and treat it through a system-by-system assessment rather than a blanket multi-region control.

**Proposed risk statement:** Azure-hosted systems may be deployed with less redundancy than their business availability requirement, so an Azure zone, region or global service outage could cause an outage longer than the business can tolerate.

**Proposed treatment:**

1. Give every Azure system a criticality tier, uptime SLO, RTO and RPO, agreed with its business owner.
2. Calculate each system's current composite availability and compare it with its SLO.
3. Set the default standard as zone-redundant in Australia East with backups to Australia Southeast, which Microsoft recommends as the starting point for many production workloads.
4. Use multi-region (Australia East and Australia Southeast) only where the default cannot meet the SLO or RTO, with automated failover and at least one failover test a year.
5. Record a formal risk acceptance for systems whose gap is tolerable.
6. Assess shared dependencies once for all systems: Front Door, Entra ID, DNS, ExpressRoute or VPN, and firewalls.

## Sources

- [List of Azure regions](https://learn.microsoft.com/en-us/azure/reliability/regions-list) (Microsoft, updated October 2026)
- [Using availability zones and regions](https://learn.microsoft.com/en-us/azure/well-architected/design-guides/regions-availability-zones) (Microsoft Well-Architected Framework)
- [Protect your Azure cloud estate](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/manage/protect) (Microsoft Cloud Adoption Framework, updated October 2026)
- [Azure status history](https://azure.status.microsoft/en-us/status/history/) (Microsoft, PIR 7Q30-010)
- [Azure Front Door incident retrospective YKYN-BWZ](https://aka.ms/air/YKYN-BWZ) (Microsoft)
- [Mission-critical global HTTP ingress](https://learn.microsoft.com/en-us/azure/architecture/guide/networking/global-web-applications/mission-critical-global-http-ingress) (Microsoft)
- [Global routing redundancy for web applications](https://learn.microsoft.com/azure/architecture/guide/networking/global-web-applications/overview) (Microsoft)
- [Application platform considerations for mission-critical workloads](https://learn.microsoft.com/azure/well-architected/mission-critical/mission-critical-application-platform) (Microsoft)
- [Azure region pairs and cross-region replication](https://learn.microsoft.com/en-ie/azure/reliability/cross-region-replication-azure) (Microsoft)
- [SLA for Virtual Machines](https://www.azure.cn/en-us/support/sla/virtual-machines/) and the [Online Services SLA](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services) (Microsoft)
- [Load Balancer best practices](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-best-practices) (Microsoft)
- [Azure SQL higher availability options](https://learn.microsoft.com/en-us/training/modules/azure-sql-high-availability/7-higher-availablity-options) (Microsoft Learn)
- [Azure Front Door general availability](https://azure.microsoft.com/en-gb/updates/azure-front-door-service-is-now-available/) (Microsoft)
- [Bank of Queensland, Jetstar among Australian enterprises impacted by Azure outage](https://www.itnews.com.au/news/bank-of-queensland-jetstar-among-australian-enterprises-impacted-by-azure-outage-599803) (iTnews)
- [Microsoft's slow outage recovery in Sydney](https://datacenterdynamics.com/en/news/microsofts-slow-outage-recovery-in-sydney-due-to-insufficient-staff-on-site) (DCD)
- [Microsoft to expand Melbourne Azure region with more availability zones](https://www.datacenterdynamics.com/en/news/microsoft-to-expand-melbourne-azure-region-with-more-availability-zones) (DCD)
- [Azure outage history 2020–2026](https://medhacloud.com/blog/azure-outage-history) (MedhaCloud)
