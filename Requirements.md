# Request for Quote — Azure Managed Services
## Requirements Document

**Issued by:** [Organisation name], Information Management & Technology Services
**Date:** [Date]
**RFQ reference:** [Reference number]
**Response due:** [Date]
**Contact:** [Name, email]

---

## 1. Purpose

[Organisation name] (the Organisation) invites [Vendor name] (the Vendor) to provide quotes for the ongoing managed services of Azure resources under a new contract. The Organisation understands the Vendor no longer operates a resource-catalogue/unit billing model; the Vendor must therefore clearly describe its proposed commercial model as part of its response.

The Vendor is required to provide **three separately priced and separately itemised quotes**, corresponding to the three service packages defined in Section 4. Each package must be able to be accepted or declined independently of the others, and the Vendor must state any dependencies or price changes that would apply if only a subset of packages is taken up.

## 2. Background

The Organisation operates Microsoft Azure and Microsoft 365. The environment comprises multiple Azure subscriptions containing infrastructure, platform and data services supporting the Organisation's business solutions. Day-to-day management is performed by the Organisation's internal Cloud Engineering team, with the Vendor engaged for the defined services in this document.

The volumes of Virtual Machines and solutions in scope are being finalised by the Organisation and will be issued as **Appendix A (Virtual Machine Inventory)** and **Appendix B (Solution and Resource Inventory)**. Vendors must structure pricing so that final pricing can be calculated directly from the volumes in these appendices once issued (e.g. price per VM per month by OS type and tier, price per solution per month by size band). Where the Vendor's pricing is volume-banded, the bands must be stated explicitly.

## 3. Definitions

| Term | Definition |
|---|---|
| Business Hours | 8:00am – 5:00pm, Monday to Friday, [AEST/AEDT — local time], excluding [state/territory] public holidays |
| After Hours | 5:00pm – 8:00am on business days, and [24 hours on weekends and public holidays — **to be confirmed**] |
| ISM | Australian Government Information Security Manual (current release) |
| Essential Eight | ACSC Essential Eight Maturity Model, target Maturity Level [X — to be confirmed] |
| Solution | A logical grouping of Azure resources delivering a business capability, as defined in Appendix B |
| Managed Resource | An Azure resource or VM listed in Appendix A or B as under Vendor management |
| Uplift / Change | Any modification to a Managed Resource beyond steady-state maintenance, as described in Section 5 |

## 4. Service Packages and Scope

### Package 1 — Azure Virtual Machine Management (Australian Government Standards)

The Vendor will manage Windows and Linux Virtual Machines to Australian Government standards. The service must include, at minimum:

1. **Security compliance:** ongoing management of VMs in accordance with applicable ISM controls, including evidence to support the Organisation's compliance and audit obligations.
2. **Patching:** operating system and firmware/agent patching for Windows and Linux, with patch scheduling, testing/staging rings, deployment, verification, remediation of failed patches, and reporting against defined compliance targets (see Section 8). Patch timeframes must align with ACSC Essential Eight patching requirements at the Organisation's target maturity level.
3. **OS hardening:** implementation and ongoing maintenance of OS hardening baselines (e.g. ACSC hardening guidance / ISM-aligned baselines), including drift detection and remediation of deviations from the approved baseline.
4. **Standard application management:** deployment, upgrade and health management of enterprise-standard applications installed across the fleet — including enterprise security tooling and monitoring agents deployed to all VMs.
5. **Exclusions:** line-of-business applications installed on VMs (e.g. iManage) are excluded from application management unless separately agreed. The Vendor must state clearly in its response how it distinguishes in-scope standard applications from excluded applications, and how boundary disputes will be resolved.

The Vendor must state assumed responsibilities for antivirus/EDR alert response, vulnerability remediation beyond patching, backup monitoring, and certificate management on VMs — identifying which are included, optional, or excluded.

### Package 2 — Azure Solution Management

The Vendor will manage and maintain Azure resources comprising the solutions defined in Appendix B. The service must include, at minimum:

1. **Capacity management:** monitoring resource utilisation and consumption, forecasting capacity needs, and recommending scaling changes (up or down) with supporting data.
2. **Configuration review and drift management:** maintaining approved configuration baselines for managed resources, detecting configuration drift, and remediating or escalating deviations under the agreed change process.
3. **Azure service retirement and configuration currency:** proactively identifying Azure service, SKU, API and configuration retirements or deprecations affecting Managed Resources, notifying the Organisation with adequate lead time, and performing the required updates to keep resources supportable (for example, migrating Azure Storage Accounts from v1 to v2 where required for supportability).
4. **Performance and utilisation management:** identifying under-utilised or unused resources (e.g. a storage account receiving no traffic), informing the Organisation, and recommending retirement or right-sizing to reduce cost. The Vendor should state whether it offers proactive cost-optimisation reporting.
5. **Best-practice and Well-Architected review:** assessing Managed Resource configuration against Azure best practice and the Azure Well-Architected Framework at least **bi-annually**, delivering a written findings report with prioritised recommendations, and tracking remediation of accepted findings.

### Package 3 — After Hours Azure Solution Management

The Vendor will monitor Azure solution resources during After Hours (as defined in Section 3). The service must include, at minimum:

1. **Solution health monitoring:** monitoring solution status After Hours to confirm solution components are up and healthy, using agreed health checks and alert thresholds per solution.
2. **Incident response:** the Vendor must state its proposed After Hours response model — monitoring-and-alert-only, monitoring with triage and escalation to the Organisation, or monitoring with restoration/remediation — and price each tier separately if multiple models are offered.
3. **Escalation:** a documented After Hours escalation path, including the criteria and contact process for waking/engaging Organisation staff, and hand-back procedures at the start of Business Hours (shift-handover report of overnight events).
4. **Reporting:** all After Hours events, actions taken and outcomes must be logged in the agreed ITSM tooling and summarised in monthly service reporting.

The Vendor must confirm the location from which After Hours services are delivered and whether After Hours personnel meet the security requirements in Section 9.

## 5. Change and Uplift Cost Model (Mandatory Response Item)

Steady-state management (Section 4) is distinct from changes the Organisation requires to Managed Resources. The Vendor **must** provide a cost model for changes, including:

1. A **pricing guide or rate card** for changes to Managed Resources — at minimum, indicative pricing by change size (e.g. minor / standard / complex) with worked examples. An illustrative scenario the Vendor should price: *Solution A is under Vendor management; the Organisation requires an integration between Solution A and a new Solution B. What is the process and indicative cost for the Vendor's work on Solution A?*
2. A clear **definition of the boundary** between steady-state maintenance (included in the package price) and billable change/uplift, with examples of each. Ambiguity in this boundary was a deficiency of the previous arrangement and responses will be evaluated on the clarity of this definition.
3. The **process for requesting, quoting, approving and delivering** a change, including standard turnaround times for quotes and a commitment that no billable change work commences without written Organisation approval.
4. Treatment of **changes originated by the Vendor** (e.g. remediation of Well-Architected findings, service-retirement migrations under Package 2, patching-driven changes under Package 1): the Vendor must state which of these are included in the package price and which are billable, noting that work explicitly required by Sections 4.1–4.2 (e.g. retirement-driven updates, drift remediation) is expected to be included in the steady-state price unless the Vendor states and justifies otherwise.

## 6. Onboarding and Offboarding of Resources

1. **New resource onboarding:** the Vendor must describe its end-to-end process for bringing a newly built resource (e.g. a new server built by the Organisation) under Vendor management, including prerequisites, lead time, and acceptance criteria.
2. **No onboarding fees:** the Organisation will not pay per-resource onboarding or setup fees. On onboarding a new VM or resource, only the updated ongoing maintenance price (per the pricing model) will apply, effective from the date management commences. Vendors unable to meet this requirement must state so explicitly and explain their alternative.
3. **Offboarding:** the Vendor must equally describe the process and confirm pricing treatment for removing a resource from management (e.g. on decommissioning), including pro-rata billing adjustments. No offboarding fees will be paid.
4. **Volume flexibility:** the pricing model must accommodate month-to-month movement in volumes (additions and removals) with a defined true-up mechanism, and must state any minimum volume commitments or floor charges.

## 7. Commercial Requirements

1. Three separately itemised quotes per Section 1, each showing the pricing structure, unit rates or bands, and all assumptions.
2. Full disclosure of the proposed commercial model (fixed fee, per-resource, tiered, consumption-based, or hybrid), including what happens to pricing as volumes grow or shrink.
3. All costs disclosed — no fees beyond those quoted (no onboarding, offboarding, tooling, licence, or account-management fees unless itemised in the quote).
4. Proposed contract term, extension options, price-review mechanism and any indexation. The Organisation's preference is [term — to be confirmed] with termination for convenience on [X days'] notice.
5. Any transition-in costs from the current arrangement to the new contract must be separately itemised (the Organisation expects these to be nil or minimal given the Vendor is the incumbent).
6. Invoicing frequency and the level of invoice itemisation (invoices must be reconcilable to the resource inventories and any monthly true-up).

## 8. Service Levels and Vendor Accountability

The Vendor must propose, and will be contractually held to, the following:

1. **Service Level Agreement:** response and restoration targets by priority (P1–P4) for each package, with definitions of each priority level. After Hours SLAs must be stated separately.
2. **Patch compliance targets:** e.g. % of fleet patched within ISM/Essential Eight timeframes by patch criticality, reported monthly. The Vendor must state the targets it will commit to.
3. **Service credits:** a service-credit or abatement regime for SLA and KPI breaches, applied automatically to invoices without requiring the Organisation to claim.
4. **Key performance indicators:** proposed KPIs per package — at minimum: patch compliance %, hardening-baseline compliance %, incident SLA attainment, drift findings raised/closed, retirement notifications lead time, Well-Architected review delivery and remediation tracking, After Hours alert acknowledgement time, and quote turnaround time for changes.
5. **Reporting:** monthly written service reports covering SLA/KPI performance, incidents and problems, patch and compliance posture, capacity and utilisation findings, changes delivered and billed, risks, and forward maintenance schedule. Reports must be delivered within [X] business days of month end.
6. **Governance:** monthly operational service review and quarterly strategic review with a named Vendor service delivery manager; a documented escalation matrix; and an annual contract performance review.
7. **Continuous improvement:** a standing obligation to identify cost, performance and security improvements, reported quarterly.

## 9. Security, Compliance and Access Requirements

1. **Standards:** services delivered in accordance with the ISM, PSPF and the Organisation's security policies. The Vendor must state its ability to support Essential Eight target maturity for the controls within its scope.
2. **Personnel:** Vendor personnel with access to the Organisation's environment must [hold/be eligible for] [Baseline/NV1 — to be confirmed] security clearance and be located in Australia. Any offshore delivery component must be explicitly declared and is subject to Organisation approval.
3. **Access:** Vendor access must use the Organisation's identity and access controls (e.g. Entra ID accounts or Azure Lighthouse as approved), with least privilege, just-in-time/PIM elevation where available, MFA, named individual accounts (no shared credentials), and full audit logging retained by the Organisation. The Organisation may revoke access at any time.
4. **Security incidents:** the Vendor must notify the Organisation of any actual or suspected security incident affecting the Organisation's environment or data within [X hours] and cooperate fully with Organisation and ACSC incident-response processes.
5. **Data sovereignty:** all Organisation data, logs and monitoring telemetry held by the Vendor must remain within Australia. The Vendor must disclose all systems/tools that will hold Organisation data.
6. **Subcontracting:** any subcontractors must be disclosed in the response and approved by the Organisation; the Vendor remains fully responsible for subcontractor performance.
7. **Audit:** the Organisation (or its nominee) may audit the Vendor's compliance with these requirements on reasonable notice.

## 10. Operational Integration Requirements

1. **Tooling:** the Vendor must state the monitoring/management tooling it will use. The Organisation's preference is Azure-native tooling (Azure Monitor, alert rules, etc.) with the Organisation retaining full visibility of all alert rules, dashboards and telemetry. Any proprietary Vendor tooling must be disclosed, must not create dependency that impedes exit, and associated data must be exportable to the Organisation.
2. **ITSM:** all incidents, requests, changes and After Hours events must be logged in [the Organisation's ITSM tool / an agreed integrated tool — to be confirmed], visible to the Organisation in real time.
3. **Change management:** all Vendor changes to the environment must follow the Organisation's change-management process, including CAB approval where required.
4. **Documentation:** the Vendor must create and maintain current runbooks, as-built documentation and configuration records for all Managed Resources, stored in the Organisation's repository. **All documentation and artefacts produced under the contract are the property of the Organisation.**
5. **RACI:** the Vendor's response must include a proposed RACI matrix per package covering the boundary between Vendor and the Organisation's Cloud Engineering team, including incident leadership for events spanning Vendor-managed and Organisation-managed resources.
6. **Knowledge sharing:** the Vendor will conduct [quarterly] knowledge-transfer sessions with the Organisation's Cloud Engineering team covering the managed environment and material changes.

## 11. Exit and Transition-Out

1. On expiry or termination, the Vendor must provide transition-out assistance for up to [X months], priced in the response (or confirmed as included).
2. All documentation, runbooks, configurations, credentials handover, and exportable monitoring/alerting configuration must be delivered to the Organisation as a condition of final payment.
3. No exit, data-export or termination administration fees will be paid.
4. The Vendor must remove its access and confirm destruction/return of Organisation data within [X days] of exit, with written certification.

## 12. Response Requirements and Evaluation

The Vendor's response must include:

1. Three itemised quotes (Section 4 packages) with the full pricing model and assumptions.
2. Change/uplift cost model and worked example (Section 5).
3. Onboarding/offboarding process description and confirmation of the no-fee requirement (Section 6).
4. Proposed SLAs, KPIs, service-credit regime and sample monthly report (Section 8).
5. Security compliance statement addressing each item in Section 9, including personnel and data locations.
6. Tooling description, ITSM approach and proposed RACI matrix (Section 10).
7. Transition-out approach and pricing (Section 11).
8. Assumptions, dependencies and exclusions register.
9. Two referee organisations of comparable scale and sector (preferably Australian Government).

Responses will be evaluated on: value for money; clarity of the change-cost boundary and pricing transparency; ability to meet security and sovereignty requirements; strength of SLA/KPI commitments and accountability mechanisms; and quality of the operational integration and exit approach.

## 13. Appendices (to be issued)

- **Appendix A — Virtual Machine Inventory:** VM counts by OS (Windows/Linux), environment (Prod/Non-Prod), size/tier, and any special-handling notes. *[Placeholder — under management discussion; will be issued as an addendum. Pricing must be structured so final pricing is directly calculable from this appendix.]*
- **Appendix B — Solution and Resource Inventory:** solutions in scope with their constituent Azure resources by type and environment. *[Placeholder — as above.]*
- **Appendix C — Organisation policies and standards referenced** *(change management, security policies, hardening baselines, ITSM details)*.

---

*Items marked "to be confirmed" require an Organisation decision before issue: after-hours coverage of weekends/public holidays; Essential Eight target maturity level; clearance level required; contract term and notice period; ITSM tooling; incident-notification and report-delivery timeframes.*
