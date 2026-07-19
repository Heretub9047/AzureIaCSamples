# Azure Managed Services — Options Assessment Brief

**Prepared by:** [Name], Information Management & Technology Services
**Date:** [Date]
**Purpose:** To assess whether to renew the service provider arrangement for managed Azure resources, expand it, or transition management fully in-house to the Cloud Engineering team.

---

## 1. Current State

The organisation operates Azure and M365 (no AWS/GCP). There are **19 Azure subscriptions** containing **9,064 resources** in total. Management is currently split between the internal Cloud Engineering team and an external service provider operating under a catalogue-based charging model.

The service provider manages **129 resources (~1.4% of the environment)** across 4 subscriptions:

| Subscription | Provider-managed | Total resources | % managed |
|---|---|---|---|
| ORG 1 CORE | 46 | 2,811 | 1.6% |
| EDH | 49 | 1,019 | 4.8% |
| ORG 2 PROD | 18 | 418 | 4.3% |
| ORG 2 DEV | 16 | 287 | 5.6% |
| **Total** | **129** | **4,535 (of 9,064 org-wide)** | **2.8% / 1.4% org-wide** |

**Support coverage today:**
- Service provider: 24/7 support for its managed resources. ~65–70 after-hours support events last financial year (~1–2 per week on average).
- Cloud Engineering team: **3 cloud engineers**, business hours only; no after-hours roster, processes, or escalation paths currently exist. The team manages ~8,935 resources (98.6% of the estate).

**Annual cost of the service provider:** $108,000 (~$837 per resource per year at current volumes).

---

## 2. Options

### Option A — Transition fully in-house (do not renew)

**Benefits**
- Greater internal ownership and visibility over the whole Azure platform, with the ability to reprioritise work directly.
- Builds durable internal knowledge of the Azure environments over time rather than renting it.
- Closer alignment with internal business priorities and the organisation's architecture direction.
- Direct control over day-to-day prioritisation where internal resourcing is available.
- Removes the "cost of change" ambiguity in the catalogue model (see §4) — internal changes are prioritised, not quoted.
- Simplifies privileged access, RACI and incident accountability (no split ownership within subscriptions).

**Risks**
- **After-hours gap:** the internal team has no after-hours support model. The provider handled 65–70 after-hours events last FY, so this demand is real and must be covered before cutover (on-call roster, allowances, escalation paths, runbooks).
- **Recruitment and retention** for Azure roles is a material market risk; loss of a key engineer concentrates risk.
- **Transition cost and effort:** overlap period, handover, documentation, runbook creation, re-pointing of monitoring/alerting, and access changes. Poor provider documentation would extend this.
- Internal team capacity: absorbing 129 resources may be small in number, but these may be among the more complex/critical services (e.g. Azure Front Door, EDH data platform components).

### Option B — Renew and expand the service provider's scope

**Benefits**
- Retains proven 24/7 coverage without standing up an internal on-call capability.
- Buffers against Azure recruitment/retention risk.
- Predictable per-resource pricing under the catalogue model (for steady-state management).

**Risks**
- **Cost does not scale well:** ~$837/resource/yr; expanding scope compounds an already expensive unit rate (see §3).
- **Cost of change is unclear:** the catalogue covers *management*, but changes (e.g. updating security rules on Azure Front Door) appear to fall outside it and may be billed as uplift at unknown rates.
- **Strategic friction:** major platform initiatives (e.g. Azure Landing Zones, CAF alignment, network redesign) will touch provider-managed resources, requiring provider effort, re-onboarding to their tooling, and likely additional charges — a hidden cost on every future transformation.
- Internal capability atrophies for the managed resources; knowledge sits with the provider.
- Split management within shared subscriptions blurs incident accountability and duplicates tooling.

### Option C — Hybrid (worth considering)

Bring day-to-day management fully in-house, but close the after-hours gap another way:
- Retain the provider (or an alternative) for **after-hours incident response only**, at a much smaller cost than full resource management; or
- Stand up an **internal on-call roster** with on-call allowances (65–70 events/yr may be manageable for a small roster); and/or
- Lean on **Microsoft Unified/Premier support** for after-hours break-fix on platform issues.

This captures most of Option A's ownership benefits while directly mitigating its primary risk.

---

## 3. Cost Analysis and Tipping Point

- Current provider cost: **$108,000 / 129 resources ≈ $837 per resource per year**.
- Fully loaded Azure engineer cost (working figure supplied): **~$420,000/yr**.
- **Tipping point:** at the current unit rate, the provider's fees equal one engineer at roughly **$420,000 ÷ $837 ≈ 500 resources**. Below ~500 provider-managed resources, the provider costs less than an additional hire *in raw dollars*.

**However, the raw comparison understates the internal value proposition:**
- The internal team of 3 engineers already manages ~8,935 resources (98.6% of the estate) — roughly 2,980 resources per engineer, versus the provider's implied $837/resource rate. Absorbing 129 more resources is a ~1.4% increase in estate size and is unlikely to require an additional hire on volume alone; the question is the *complexity* of those specific resources, not their count.
- Conversely, **one engineer cannot provide 24/7 coverage**. A genuine like-for-like with the provider's 24/7 service requires an on-call roster or a supplementary arrangement — this is the true cost of matching the provider, and it applies whether or not the 129 resources move.
- **A 3-person on-call roster is viable but thin.** One-week-in-three on call is sustainable in the short term, but a single resignation or extended leave collapses it to one-in-two, which is a burnout and retention risk in an already tight Azure market. This makes the after-hours-only contract or Microsoft Unified support options more attractive as the primary model (or as roster backup), and is the strongest argument for a 4th engineer if after-hours is brought fully internal.
- Not all resources are equal: the provider likely manages higher-touch resources, so a simple per-resource rate flatters neither side. Per-resource cost is a useful sanity check, not a decision rule.

**Recommended framing for the business case:** compare (a) $108k/yr provider fee + hidden change/uplift costs + strategic friction, against (b) marginal internal effort to absorb 129 resources + the cost of an after-hours model (on-call allowances or a narrow after-hours-only contract).

---

## 4. Additional Decision Considerations

**Cost of change under the catalogue model.** Steady-state management is priced, but modifications are not clearly costed (e.g. updating WAF/security rules on Azure Front Door). Before renewal, obtain a rate card for changes, the definition of "management" vs "uplift," and historical spend on out-of-catalogue work.

**IT future direction.** Planned platform uplifts (Azure Landing Zones, policy/governance changes, identity or network redesign) will alter provider-managed resources. Assess: provider effort and charges for re-onboarding, changes to any specialised provider monitoring tooling, and whether the provider's model constrains or slows the roadmap. Every future initiative carries a provider "tax" while split management persists.

**Service boundaries and demand management.** Whichever option proceeds, the exact provider service scope must be defined and communicated org-wide to prevent management overlap, and to stop staff routing change requests to the provider that will be billed as uplift.

**Security, compliance and access (government context).**
- Provider privileged access model (e.g. Azure Lighthouse, guest accounts), personnel clearances, and offboarding assurance on exit.
- Alignment with PSPF/ISM/Essential Eight obligations; who holds evidence for audits over provider-managed resources.
- Data sovereignty and where provider monitoring telemetry is stored.

**Operational integration.**
- Incident RACI where a subscription is split between provider and internal team — who leads a cross-cutting incident?
- Tooling: does the provider use proprietary monitoring that disappears on exit? Plan migration to Azure-native tooling (Monitor, Sentinel, alert rules) as part of any transition.
- SLA comparison: what SLAs does the provider actually commit to and achieve, vs what the internal team can offer?

**Contract mechanics.** Renewal/expiry date, notice period, exit assistance obligations, ownership of documentation and runbooks, and price escalation clauses. Exit assistance clauses materially affect Option A's transition risk.

**Transition plan (if Option A/C).** Overlap period with the provider, documentation and runbook handover, knowledge-transfer sessions, monitoring re-pointing, access revocation, and a criticality-ranked cutover order (dev → prod).

---

## 5. Suggested Direction

The current arrangement pays a premium rate for a very small slice of the estate, carries unclear change costs, and adds friction to future platform work. Expanding it (Option B) compounds those issues. The primary genuine value the provider delivers is **after-hours coverage** — a capability gap that can be closed more cheaply and directly than by outsourcing resource management.

**Suggested direction: Option C (hybrid path to in-house), subject to validation:**
1. Confirm internal capacity to absorb the 129 resources and their actual complexity/criticality.
2. Cost an after-hours model (internal on-call roster vs a narrow after-hours-only contract vs Microsoft Unified support) against the $108k saved.
3. Confirm contract exit/notice terms and secure exit assistance and documentation handover.
4. Define and communicate final service boundaries during any overlap period.

## 6. Open Questions / Information Gaps

- What does the $420k engineer figure represent (base salary, fully loaded cost, or contractor rate)? This materially changes the tipping-point maths.
- Contract renewal date and notice period?
- Does the $108k include the 24/7 support and the 65–70 after-hours events, or were any billed separately?
- Which specific resources does the provider manage, and how critical are they (e.g. is Azure Front Door production-facing)?
- Historical spend on out-of-catalogue/uplift work with the provider?
- Current utilisation/headroom of the 3-person Cloud Engineering team — is there BAU capacity to absorb the provider's scope, and appetite among the team for an on-call roster?
