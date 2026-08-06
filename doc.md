1. Executive Summary
The organisation's on-premise iManage environment is being retired by the vendor. iManage has quoted $1,000,000 for a one-off transition to iManage Cloud plus $2,000,000 per year in ongoing subscription costs — against a current on-premise run cost of roughly $300,000–$500,000 per year (excluding infrastructure). This is a substantial step-up in cost and the trigger for this options paper.
The organisation already holds Microsoft 365 E5 licensing for all users, with devices managed through Intune. E5 already entitles the organisation to the advanced capabilities of Microsoft Purview — including Records Management, Data Lifecycle Management, Information Protection, DLP and auto-labelling — at no incremental licensing cost[1,2]. This makes a Microsoft-native approach worth serious evaluation alongside iManage Cloud.
This paper compares two options:
•	Option A — iManage Cloud: lift-and-shift the existing DMS to iManage's SaaS offering.
•	Option B — Microsoft 365 Native: retire iManage and rebuild document and records management on SharePoint Online, Purview and related Microsoft 365 capabilities the organisation already owns.
On a 5-year total cost of ownership basis, Option A is estimated at approximately $11.0M, while Option B is estimated in the range of $1.3M–$2.9M (indicative — see Section 5 and Appendix A for assumptions). The gap is large enough to warrant formal validation, but cost is not the only consideration: Option B is not a like-for-like replacement of iManage's core document-management functionality (matter-centric workspaces, check-in/check-out at the workspace level, conflict/ethical-wall enforcement) — it requires the organisation to design and build that functionality on a general-purpose platform. Section 4 sets this out in detail.
This paper recommends the organisation commission a short, time-boxed discovery and proof-of-concept engagement (Section 8) before committing to either path at full scale, given the scale of the cost differential and the residual functional and migration risks on the Microsoft-native option.
2. Purpose and Scope
This paper presents options for the organisation's future records and document management platform, following notice that the current on-premise iManage deployment is being phased out by the vendor. It is intended to support an investment decision and covers: cost estimates for transition and ongoing operation, a feature comparison between the two options, user training considerations, and a recommended next step.
This paper does not constitute a procurement document, a vendor quote, or a final architecture. Cost figures for the Microsoft-native option in particular are planning-level estimates and should be validated through the discovery activity recommended in Section 8 before being used for budget approval.
3. Current State and Background
3.1 Current environment
•	Document and records management is currently provided by iManage, hosted on-premise.
•	iManage is discontinuing meaningful investment in, and eventually support for, the on-premise product, and is directing customers to iManage Cloud.


3.2 The trigger for this paper
iManage has quoted $1,000,000 as a one-off cost to transition to iManage Cloud, with ongoing subscription costs of $2,000,000 per year thereafter. This represents roughly a 4–6x increase in annual run cost compared to the current on-premise arrangement, which has prompted the organisation to evaluate whether existing Microsoft 365 investment can meet its records management obligations at lower cost.
3.3 Why this matters beyond cost
Records management is not a discretionary capability — the organisation has ongoing regulatory, legal and business obligations to retain, protect and dispose of records appropriately. Any option must be assessed on its ability to meet these obligations, not on cost alone. Both options below are evaluated against that requirement.
4. Option A — iManage Cloud
Migrate the existing iManage deployment to iManage's cloud-hosted (SaaS) offering, retaining the same core product, matter-centric information architecture, and user experience.
What this involves
•	Vendor-led migration of existing workspaces, matters, documents, profiles and metadata to iManage Cloud.
•	Decommissioning of on-premise iManage infrastructure.
•	Re-establishment of integrations (Outlook, Word/Excel, DMS plug-ins) against the cloud tenant.
•	Minimal change to end-user workflow, filing conventions or information architecture.
Strengths
•	Lowest disruption: staff already know iManage; the change is primarily where it is hosted, not how it is used.
•	Purpose-built for legal/matter-centric work: workspace/matter structure, check-in/check-out, conflict checking and ethical walls are native, mature features, not something the organisation has to design.
•	Vendor-managed: upgrades, patching, uptime and cloud infrastructure are iManage's responsibility under an SLA.
•	Fastest path to compliance with the on-premise end-of-life notice.
Weaknesses
•	Cost: ~4–6x the current annual run cost, for a platform that is functionally similar to what the organisation already operates.
•	Duplicate spend: the organisation continues paying for a separate DMS platform on top of its existing, largely unused-for-this-purpose Microsoft 365 E5 investment.
•	Ongoing vendor lock-in 
•	Two ecosystems to secure and administer: iManage and Microsoft 365 remain separate identity, security and compliance surfaces (though iManage Cloud does support Entra ID integration for authentication).
5. Option B — Microsoft 365 Native
Retire iManage and deliver document and records management using capabilities already licensed within Microsoft 365 E5: SharePoint Online as the content platform, and Microsoft Purview (Records Management, Data Lifecycle Management, Information Protection) as the governance layer. A full high-level design for this option is provided as a companion document.
What this involves
•	Designing an information architecture in SharePoint Online to organise content (by matter, case, project or business unit, depending on the organisation's model).
•	Configuring Purview Records Management: file plan, retention labels, retention/disposition policies, event-based retention, and disposition review workflows.
•	Configuring Purview Information Protection and DLP to control sensitive content.
•	Migrating content and metadata out of iManage into the new structure.
•	Establishing governance roles (records manager, site owners, disposition reviewers) and a records management framework/policy.
Strengths
•	No incremental licensing cost: advanced Purview Records Management, Data Lifecycle Management, auto-labelling, disposition review and eDiscovery Premium are already included in Microsoft 365 E5 for every licensed user.[1,2]
•	Single ecosystem: one identity platform (Entra ID), one device management platform (Intune, already in place), and one compliance/security surface across email, Teams, SharePoint and OneDrive.
•	Strong native records/retention engine: Purview's retention labelling, event-based retention, adaptive scopes and disposition review are mature and arguably more capable than iManage's native retention tooling.
•	Copilot/AI readiness: content governed by sensitivity labels and DLP from day one is safer to expose to Microsoft 365 Copilot than content sitting in a separate, ungoverned system.
•	Materially lower ongoing run cost (see Section 6).
Weaknesses
•	Not a drop-in DMS replacement: SharePoint has no native concept of a "matter" or "workspace" the way iManage does. Matter-centric structure, workspace-level check-in/check-out behaviour, and automatic email filing to a matter must be designed and configured — SharePoint provides the building blocks, not the finished capability.
•	Conflict checking and ethical walls: iManage provides these natively for legal-style practice. Microsoft 365 does not have a direct equivalent out of the box; achieving equivalent control requires custom permission design, and in some cases a third-party ISV add-on, adding cost and complexity not captured in a bare Purview/SharePoint estimate.
•	Migration effort: moving matter structures, profiles, security models and version history out of a purpose-built legal DMS into SharePoint is a genuine content-migration project, not a simple file copy.
•	Change management: staff familiar with iManage's matter-first filing model will need to learn a different way of working.
•	Internal capability required: the organisation takes on design, build and ongoing governance responsibility that iManage Cloud would otherwise carry as a vendor service.
Important scoping note
iManage is a full legal Document Management System (DMS); Microsoft Purview is primarily a records/retention governance layer, not a DMS in its own right. "Microsoft-native records management" in practice means SharePoint Online acting as the DMS, with Purview providing retention and disposition on top. If the organisation's requirement includes matter-centric practice-management features (conflict checking, ethical walls, matter budgeting), those need to be scoped and costed as part of the SharePoint build, or sourced from a third-party ISV product that sits on top of Microsoft 365 — this paper's cost estimate for Option B assumes a records/retention-led build, with basic matter-style organisation via metadata, not a full practice-management replacement.
6. Cost Comparison
Figures below are planning-level estimates for comparison purposes. iManage figures are the vendor's quoted numbers as provided to the organisation. Microsoft-native figures are indicative ranges built from typical SharePoint/Purview DMS-replacement engagements of comparable scope and should be firmed up through the discovery activity in Section 8. All figures are exclusive of GST/tax and assumed to be in the organisation's local currency.
6.1 Headline figures
Cost element	Option A — iManage Cloud	Option B — Microsoft 365 Native
One-off transition cost	$1,000,000	$450,000 – $1,000,000
Ongoing annual cost	$2,000,000 / year	$200,000 – $450,000 / year
Incremental licensing cost	New SaaS subscription (full cost)	$0 (covered by existing M365 E5)*
5-year total cost of ownership	≈ $11,000,000	≈ $1,250,000 – $2,900,000
* Assumes optional add-ons (e.g. SharePoint Syntex for advanced auto-classification at scale, or a third-party matter-management overlay) are not required. If required, add an estimated $30,000–$150,000/year depending on scope — see Section 4 note above.
6.2 Five-year cost projection
Period	Option A — iManage Cloud	Option B — Microsoft 365 Native
Year 1	$3,000,000	$650,000 – $1,450,000
Year 2	$2,000,000	$200,000 – $450,000
Year 3	$2,000,000	$200,000 – $450,000
Year 4	$2,000,000	$200,000 – $450,000
Year 5	$2,000,000	$200,000 – $450,000
5-Year Total	$11,000,000	$1,250,000 – $2,900,000

6.3 What sits inside the Microsoft-native estimate
•	Implementation & design ($150K–$300K, one-off): discovery, information architecture, file plan and retention policy design, site/library build, security model.[4]
•	Migration ($250K–$600K, one-off): content/metadata extraction from iManage, transformation and mapping, migration tooling, load, validation and reconciliation. This is the single biggest cost driver and is highly sensitive to data volume, number of matters, and how much historical content must move versus be archived.[4,5]
•	Change management & training ($50K–$120K, one-off): see Section 7.
•	Ongoing governance & support ($200K–$450K/year): largely people cost — a records manager and SharePoint/Purview administration capability (in-house or via managed service), plus incremental Azure storage for any content requiring immutable (WORM) retention beyond what SharePoint provides natively.
As a sense check, a comparable published case study of an organisation replacing iManage with a SharePoint-based DMS (matter-centric structure, Purview retention rollout, legal-hold workflow, conflict-of-interest workflow) reported a project cost of approximately $385,000 and a year-one all-in cost of approximately $560,000[3], broadly consistent with the ranges above. Actual cost for this organisation will depend on data volume, number of users/matters, and how closely it needs to replicate iManage's practice-management features.
Caution on the estimate
These figures are directional. They are built from public benchmarks and typical engagement patterns, not a quote for this organisation's specific data volumes, matter counts, integration requirements or regulatory context. Treat the gap between Option A and Option B as directionally significant, not as a precise number to take to a budget committee without further validation.
7. Feature Comparison
The comparison below focuses on capabilities most relevant to records and document management. "Native" means the capability is built-in and mature; "Partial" means it exists but requires configuration or falls short of the other option; "Gap" means there is no direct equivalent.
Capability	iManage Cloud	MS 365 Native	Notes
Matter/workspace-centric structure	Native	Partial	SharePoint via custom metadata/site design, not a native concept
Check-in / check-out & version history	Native	Native	SharePoint document libraries provide this natively
Email filing (Outlook to matter)	Native	Partial	Requires configuration; less seamless than iManage's DMS plug-in
Conflict checking / ethical walls	Native	Gap	No direct Microsoft 365 equivalent; needs custom design or 3rd-party ISV add-on
Document comparison / redlining	Native	Partial	Available via Word native compare; less integrated than iManage
Retention labels & disposition (records mgmt)	Native	Native	Purview arguably stronger: adaptive scopes, event-based retention, proof of disposal
Legal hold / eDiscovery	Native	Native	Purview eDiscovery Premium included in E5
Sensitivity labelling / DLP	Add-on / limited	Native	Purview Information Protection included in E5
Full-text search across content	Native	Native	Microsoft Search across SharePoint/Exchange/Teams
Mobile & offline access	Native (app)	Native (app)	Both platforms provide mobile apps
AI-assisted drafting / summarisation	iManage Insight+ (paid)	Copilot (E5-adjacent)	Copilot licensing is separate in both ecosystems; governance readiness favours M365
Single identity/security platform with rest of M365	No (separate identity surface)	Yes	iManage Cloud can federate to Entra ID for auth, but remains a separate compliance surface
Vendor-managed hosting/upgrades	Yes	Shared responsibility	Microsoft manages the platform; org manages configuration/governance
Incremental licensing cost	Full SaaS subscription	Included in existing E5	Primary cost driver of this paper
8. User Training Considerations
8.1 Option A — iManage Cloud
•	Training burden: Low. Core workflow, filing conventions and matter structure are unchanged — most staff will experience this as "the same system, hosted differently."
•	Refresher training may be needed for any UI differences between the on-premise version and the current Cloud release, and for any new features iManage Cloud offers that the organisation chooses to adopt (e.g. Insight+ AI features).
•	IT/records administration staff will need training on the new cloud admin console and support model.
8.2 Option B — Microsoft 365 Native
•	Training burden: Moderate to high, concentrated in the transition period. Staff need to learn a new filing model (metadata/site-based rather than matter-number-based), new email-filing habits, and new search behaviour.
•	Records managers / disposition reviewers need targeted training on the Purview Records Management workflow: applying retention labels, running disposition reviews, and using the file plan.
•	Site owners need training on SharePoint permissions and library structure to avoid governance drift (a common SharePoint risk without strong guardrails).
•	Change management is the bigger risk than technical training — staff moving from a purpose-built legal DMS to a general-purpose platform is a workflow change, not just a tool change, and should be resourced as a change program (communications, champions network, floor support at go-live) rather than a single training event.
•	Recommend building short role-based guides (e.g. "filing an email to a matter", "applying a retention label", "running disposition review") rather than relying on generic Microsoft 365 training content.
9. Key Risks
Option	Risk	Mitigation
A	Recurring cost growth locks in a $2M+/year commitment with limited leverage to reduce it later.	Negotiate multi-year price protection; benchmark against Option B before signing.
A	Continued duplicate spend on a second platform alongside already-licensed M365 capability.	Quantify the "do we actually need two DMS platforms" question explicitly in the business case.
B	Underestimating migration complexity (matter structure, security, version history) leads to cost/schedule overrun.	Run a data-volume and complexity assessment before committing to a fixed migration budget; pilot with one practice group/business unit first.
B	Conflict-checking / ethical-wall requirements turn out to be a hard compliance requirement, not a nice-to-have, and Microsoft 365 cannot meet it natively.	Confirm this requirement explicitly and early with legal/compliance stakeholders — it materially changes the cost and viability of Option B.
B	SharePoint governance drift over time (uncontrolled site sprawl, inconsistent permissions) erodes records integrity.	Establish a governance framework and a records manager role before go-live, not after.
B	Staff resistance / productivity dip during transition away from a familiar, purpose-built legal DMS.	Invest properly in change management (Section 8); consider a phased, business-unit-by-business-unit rollout.
10. Recommendation and Next Steps
Given the scale of the cost differential — an estimated $8M–$9.5M over five years — the Microsoft-native option warrants formal validation before the organisation commits to iManage Cloud's ongoing subscription. At the same time, Option B carries real functional and delivery risk that a cost comparison alone does not capture, particularly around matter-centric practice features and migration complexity.
Recommended next steps:
•	1. Confirm hard requirements with legal/compliance and business stakeholders — specifically, whether conflict checking and ethical walls are a genuine compliance requirement or a convenience feature. This single question materially changes Option B's viability and cost.
•	2. Commission a discovery and proof-of-concept (4–8 weeks): assess current iManage data volumes and complexity, validate the Microsoft-native architecture (companion High-Level Design document) against a real practice group or business unit, and produce firm, quotable cost estimates for implementation and migration.
•	3. Seek a short-term extension or bridge arrangement from iManage if the on-premise end-of-life timeline is tighter than the discovery/decision timeline allows, to avoid being forced into a full commitment under time pressure.
•	4. Re-run this cost comparison with firm numbers from step 2 before seeking final investment approval.
This paper does not recommend committing to iManage Cloud's full multi-year subscription, nor does it recommend committing to a full Microsoft-native rebuild, without the validation steps above. The cost gap is large enough, and Option B different enough in kind (not just cost), that a time-boxed proof of concept is a proportionate and low-risk next step relative to either $11M or a large internal build committed on estimates alone.
Appendix A — Assumptions and Basis of Estimates
•	All monetary figures are as supplied by the reader or estimated for planning purposes; currency and GST/tax treatment should be confirmed locally before use in a business case.
•	iManage Cloud figures ($1,000,000 transition; $2,000,000/year ongoing) are the vendor quote as provided to the organisation and have not been independently verified or negotiated in this paper.
•	Microsoft-native cost ranges are built from: (a) the entitlement position that Microsoft 365 E5 already includes Microsoft Purview's advanced Records Management, Data Lifecycle Management, Information Protection/DLP, auto-labelling and eDiscovery Premium capabilities at no incremental licence cost [1,2], and (b) publicly available benchmarks for comparable SharePoint-based DMS-replacement projects (implementation, migration and change management), including a published case study of an iManage-to-SharePoint DMS replacement with matter-centric structure and Purview retention rollout [3,4,5].
•	Microsoft-native estimates exclude any third-party ISV overlay product that may be required for conflict-checking/ethical-wall functionality, as this depends on a requirement that has not yet been confirmed (see Recommendation, step 1).
•	Both options exclude the cost of underlying network/device infrastructure, which the organisation already carries.
•	Figures should be treated as planning-level and refined through the recommended discovery/proof-of-concept engagement before being used for final budget approval.
Appendix B — Sources
The following sources were used to verify Microsoft 365 E5/Purview licensing entitlements and to benchmark indicative implementation and migration costs for Option B. All were accessed 30 July 2026. Cost figures drawn from these sources are third-party estimates/benchmarks, not quotes for this organisation, and are used here for planning purposes only (see Section 6 caution note).
[1] Records management overview (Microsoft 365 compliance training module) — Microsoft Learn. https://learn.microsoft.com/en-us/training/modules/m365-compliance-information-manage-records/records-management-overview  — confirms records management is included with Microsoft 365/Office 365 E5/A5/G5 and related Compliance/Security SKUs.
[2] Microsoft Purview Records Management: AI-Ready Governance Guide — Nikki Chapple (nikkichapple.com), updated 16 May 2026. https://nikkichapple.com/microsoft-purview-records-management-guide/  — confirms advanced features (event-based retention, disposition review, proof of disposition, adaptive scopes, auto-labelling) require Microsoft 365 E5 or the E5 Compliance add-on.
[3] SharePoint Pricing Guide 2026 — Beyond Intranet. https://www.beyondintranet.com/blog/sharepoint-pricing/  — published case study of an iManage-to-SharePoint DMS replacement (matter-centric structure, Purview retention rollout, conflict-of-interest workflow, legal hold); reports project cost ≈$385,000 and year-one all-in cost ≈$560,000.
[4] SharePoint Migration Cost Guide: What Does It Really Cost — SharePoint Support, February 2026. https://sharepointsupport.com/blog/sharepoint-migration-cost-guide  — enterprise SharePoint migration cost benchmarks (e.g. $150,000–$350,000+ for regulated/complex migrations) used to inform the implementation and migration ranges in this paper.
[5] How much SharePoint Migration will cost? — Zelite Solutions. https://zelitesolutions.com/how-much-sharepoint-migration-will-cost/  — lower-end SharePoint migration benchmarks (≈$20,000–$70,000 for smaller/simpler migrations) used as a lower bound in this paper's ranges.
