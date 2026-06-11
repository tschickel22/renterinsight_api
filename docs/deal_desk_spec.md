# 25. Deal Desk Module — Complete Specification

**A sales-rep tool for structuring deals at point of sale: pull an existing deal, layer in trade/fees/F&I/lender program, and solve for the numbers the customer cares about — monthly payment, money down, term, or out-the-door price. Built primarily for RV, also serves MH. The "what-if" engine that turns a sticker price into a financeable, signable deal.**

---

## Core Mental Model

Every deal is the same equation viewed from different directions:

```
Amount financed = unit price − trade equity − cash down − rebates + fees + taxes + F&I products
Monthly payment = f(amount financed, APR, term)
```

The desk lets a rep lock any variables and **solve for the rest**. "Customer needs $650/mo" → the engine solves backward across levers to show what term, down, price concession, or lender tier gets there, ranked by dealer margin impact.

**Deterministic math runs server-side in a calculation engine. The LLM never does arithmetic** — AI interprets intent, picks levers, and explains; the engine computes.

---

## Placement & RBAC Philosophy

- **Standalone "Deal Desk" sidebar module**, positioned near Sales Deals (NOT buried inside Finance). Reps must reach it without inheriting Finance permissions.
- The desk **reads** finance config (default rate, lender programs) but does not **live inside** Finance.
- Resource keys: `deal_desk:read`, `deal_desk:write`, `deal_desk:quote`, `deal_desk:configure`, plus a **separate** `deal_desk:transfer_unit` (manager capability).
- **Default behavior: reps build/quote/compare freely, no approval gating.** Cross-location unit transfer is the one gated action (manager only). Full permission matrix underneath so manager-approval gating CAN be enabled per company later without code changes.
- This satisfies the standing RBAC priority: (1) reps build freely as default, (2) full matrix structurally available.

---

## Workflow (No Double Entry)

```
Deal built in Sales Deals (system of record)
   ↓  rep clicks into Deal Desk
Deal pulled into desk — buyer, unit, trade, fees PRE-FILLED (one-directional read)
   ↓  rep solves / compares / swaps units (autosaved scenarios)
Selected structure written back to the deal (structured write-back)
   ↓  on close
Enters NORMAL deal-close → GL-approval pipeline
   ↓
Commissions stay gated on GL-approval (UNCHANGED — see commission gating rule)
```

**Critical:** Deal Desk "no gating" applies ONLY to the quote/structure stage. Converting a desked deal into a closed deal still enters the existing approval pipeline. Commission gating on GL-approval is untouched.

---

## Calculation Engine (Phase 1 — pure, tested, no DB)

Foundation everything else trusts. Extract/reuse the **existing owner-financing amortization logic** (in the loans module under Finance) into a shared primitive so there is ONE tested amortization implementation, not two that drift.

**Engine responsibilities:**
- Standard amortizing loan: `APR + term + principal → monthly payment`
- Long RV terms supported (up to **240 months** on motorhomes; 144–180 on travel trailers/fifth wheels)
- Amount-financed assembly (price − trade equity incl. negative-equity payoff rollover − down − rebates + fees + F&I + taxes)
- **Tax modes** (state-configurable): tax on full price vs. price-minus-trade
- Title / license / doc / prep fees
- F&I product rollup (service contract, GAP, tire/wheel, paint/fabric)
- **Dealer gross calculation** — INTERNAL ONLY, never serialized into customer-facing outputs
- **Reverse solvers** — solve-for-payment across each lever: term, cash down, price/discount, lender rate/tier
- **Batch-solve** — run one deal structure against N candidate units, return payment + gross per unit
- **Guardrail checks** — minimum gross, max LTV, payment-to-income → pass/fail + reason

**Rate resolution order:** lender-program tier rate → company-settings default rate → manual override.

Full test coverage on every function. No DB dependencies in the engine.

**Lease/balloon: DEFERRED.** Rare even on high-end coaches. Structure the engine so balloon can drop in later without a rewrite.

---

## Data Model (Phase 2)

**`deal_desk_scenarios`** — the working scratchpad; the unit of persistence.
- `belongs_to :deal` (a deal can have MANY scenarios — this IS the compare feature)
- References the unit (unit-swap = different unit per scenario)
- **Input snapshot:** trade/payoff, cash down, fees, F&I products, lender program + tier, rate, term
- **Computed outputs:** amount financed, monthly payment, OTD, dealer gross
- **Price snapshot** (NOT a live reference — remembers what was quoted even if the unit's price later changes; can flag "price has since changed")
- Aged/location metadata if cross-location unit
- `status` enum: `active` / `expired` / `selected`
- `valid_through` date (validity window)
- `created_by`, timestamps
- Scopes: `active`, `expired`, `selected`. `@company` + location scoped. `company_id` NEVER in params.

**`lender_programs`** — tier matrix: FICO band × collateral age × loan amount → rate, max term, max LTV.

**`fee_templates`**, **`fni_products`**.

**Company settings:**
- Comparable **price-band width** (default ±$15k or ±10%) — tunable, no code change
- Scenario **validity window** (default **30 days**)
- **Days-on-lot tiers** (90 / 120 / 180+)

**SEED required:** No real rate sheets exist. Seed plausible sample lender programs (a few lenders, full tier matrices), sample fees, sample F&I products — clearly marked as seeded, swappable when real sheets arrive.

---

## Persistence Model (Autosave + Validity Window)

- **Autosave** — scenarios persist as the rep works (matches scratchpad feel, nothing lost).
- **A desked structure is NOT a quote.** It is one or more scenarios on the deal. A **quote** is optionally *generated from* the selected scenario on deliberate intent (reuses existing quote system + public `/q/:token` views). Most scenarios never become quotes. This prevents quote pollution from exploratory desking.
- **Never hard-delete. Expire, don't prune.**
  - **Active** — within validity window, editable, shown in working desk.
  - **Expired** — past window. Read-only, hidden from default view, fully retrievable via history filter. This is the audit record + dispute protection.
  - **Selected/closed** — kept permanently regardless of window.
- **"You quoted me $X 45 days ago" is handled by design:** expired scenarios filtered from daily view, one toggle to surface, complete with date, unit, structure, who built it. The number stops being *offerable* after 30 days but never stops being *provable*.
- Scenarios ARE the deliberation audit trail (rep considered N units, chose the aged cross-location one) — useful for manager review and the commission/GL conversation.

---

## Unit-Swap + Side-by-Side Compare (the key differentiator)

The desk treats the home as a **swappable slot**, not a fixed unit. The customer wants "3/2 around $650/mo," not a specific VIN.

**Comparable match = bed/bath (hard filter) + price band (soft window, company-configurable).**

**Default compare set driven by the deal's current home status:**
- Deal home is **on-hand** → default shows other on-hand units matching bed/bath/price-band.
- Deal home is **available-to-order** → default shows orderable configs.
- Rep can toggle to widen the net (include orderable, include other locations).

**Aged cross-location inventory intelligence (the standout feature):**
- Matching units at OTHER locations appear in the compare view with **location + days-on-lot** attached.
- **Days-on-lot tiers (90/120/180+)** drive sort weight and visual treatment; aged units "light up" (the classic case: a 200-day unit at another lot that needs to move).
- Days-on-lot derives from the inventory record's lot-received date (Champion feed / inventory already tracks this).
- The AI solve becomes **two-dimensional**: not just "what levers hit $650 on this unit," but "*which unit* — across all locations, weighted toward aged stock — hits $650 with the best combined outcome (customer payment + dealer margin + inventory health)."

**Cross-location RBAC:** Reps SEE cross-location matches (so they can build the deal around an aged unit). **Initiating the inter-location transfer is `deal_desk:transfer_unit` — manager only.** Rep structures "move the Denver unit to hit $650," presents it, manager approves the move. Deliberately permissioned exception to the normal `for_current_location` scoping — without it, aged cross-location matches won't appear for location-tier reps.

---

## AI Structuring Layer (Phase 4)

- **Conversational solve-for-payment with explanation** — the gap even incumbents admit exists ("AI is everywhere, but where does it actually help?"). Rep types "get them to $650 and protect my gross" → ranked structures with plain-English reasoning: *"Option A: extend to 180 months, keeps full margin. Option B: $4k more down, shorter term, $1,100 better backend. Option C: move the 200-day Denver unit, discount $3k still lands $640/mo and clears aged stock."*
- Intent → lever selection (term/down/price/lender × candidate units) → engine call → ranked options with gross-impact + guardrail flags.
- **AI interprets and explains; the engine computes.** Use the Anthropic API pattern already used elsewhere in the app for AI features.

---

## Competitive Context (why these choices)

Table stakes (must match): payment calculator + what-if, F&I rollup/menu, tax/fee/title handling, margin/profit tracking per unit, document/contract generation.

Incumbent moats (DEFERRED — no rate sheets): live lender-network connectivity (700–1,000+ lenders), instant credit decisioning, e-contracting.

**Where RenterInsight wins:**
1. Conversational solve-with-explanation (not just a grid that recomputes).
2. Live payment grid with margin shading (the classic four-square, reimagined).
3. Margin/LTV/PTI guardrails AT STRUCTURE TIME (compliance-by-design, not by-audit).
4. **Native deal-to-everything integration** — desked deal pre-fills from inventory, pushes to purchase agreement, triggers project on close, flows into commissions (GL-gated). Incumbents bolt desking ON; ours is native.
5. Configuration-based unit-swap + aged cross-location inventory intelligence (no auto-derived tool does multi-lot aged-unit moving).
6. MH-specific awareness (land-home vs. chattel, longer terms) — auto-first tools handle this poorly.

---

## Customer-Facing Output: Printed Deal Summary ("Pencil")

**NOT exposed in the client portal.** The desk is an internal sales workspace (margin, deliberation, unselected scenarios). The portal's role stays post-close project transparency.

**The deliverable is a branded printable one-pager** — the leave-behind a rep slides across the desk:
- Generated from the **selected scenario only**, projected through a customer-safe template.
- **Margin / gross / deliberation / unselected scenarios NEVER appear.** Same membrane principle as a quote, rendered as a document.
- **Contents:** header (selling **location** logo/colors/name/address/phone + salesperson — per industry/label system, multi-location shows the *selling* location's brand); the home (description, stock/serial, bed/bath/sqft, photo if available); price breakdown (selling price, trade allowance less payoff, fees, taxes, F&I, down → amount financed); **the payment** (APR, term, monthly payment as the big bold number, OTD); footer ("**valid through [date]**" from the scenario's validity window, disclosures/disclaimer space, optional signature line).
- The "valid through" date prints on the leave-behind — sets customer expectation and makes the day-45 conversation easy.
- **Backend:** `deal_desk_scenarios/:id/summary.pdf` (Prawn — same pattern as Partner Kit PDFs). Location-scoped branding, `@company`-isolated, margin fields explicitly excluded from the serialization feeding the template.
- **RBAC:** printing = effectively `deal_desk:read` (any rep who sees the scenario can print). No new gating.
- v1: single selected-scenario pencil. Optional later: 2-/3-up compare sheet (fits the unit-swap feature).

**Customer-facing self-service desking** (buyer builds own payment online) is the separate **digital-retailing widget — ROADMAP**, reusing portal infrastructure, with no margin/internal scenarios. NOT the internal desk piped to the portal.

---

## Global Search Integration (Section 18 pattern)

- **No new `SearchResultType`.** Desked deals surface as **Deal results, badged "💲 Desked," deep-linking to the desk view** (no duplicate rows, no parallel result type).
- **Match paths:**
  1. Buyer/account/contact **name** → returns the deal (existing behavior + badge when active scenarios exist).
  2. **Unit/stock number in a scenario** → returns the parent deal EVEN when that unit isn't the deal's primary unit (the aged cross-location unit lives in a scenario, not on the deal record — this is the additive case).
- **Backend (`search_controller` Deals block):** JOIN/subquery against **active** `deal_desk_scenarios` so a scenario stock-number match pulls in the parent deal. Add `desked: true` flag, point URL at the desk tab. Scoped to active scenarios — expired ones excluded from everyday search (reachable via the deal's desk history). `@company.deals` with scenario JOIN, NEVER an unscoped scenario query.
- **Frontend (`GlobalSearch.tsx`):** conditionally render "💲 Desked" badge + deep-link when `desked` is true. No new type/icon/display-name entry.
- Known/accepted behavior: a stock# that only appeared in a now-expired scenario won't return the deal via that path (deal still findable by name; expired scenario one toggle away in desk history).

---

## Subscriptions

Register Deal Desk as a **gated module/feature flag** in the subscription system so it appears in the tier builder. Do **NOT** hardcode which tier — Tom assigns per tier.

---

## Deferred to Roadmap (explicitly out of v1)

- Live lender-network integration + instant credit decisioning (no rate sheets — seed samples instead)
- Customer-facing digital-retailing "build your payment" widget
- Lease / balloon financing
- Carrying-cost-based aged signals (v1 uses days-on-lot only)
- MH land-home vs. chattel as distinct deal types (v1: same amortization, different terms/fees)
- Multi-scenario compare-sheet PDF (v1: single selected pencil)

---

## Build Phasing Summary

| Phase | Backend | Frontend |
|-------|---------|----------|
| 0 | Discovery (read code, confirm integration points) | Discovery |
| 1 | Calculation engine (pure, tested) | Service layer + sidebar + routing |
| 2 | Data model + seed | Desk workspace (pull deal, inputs, live recap, autosave) |
| 3 | Matching + compare engine | Solve-for-payment + AI panel |
| 4 | API + RBAC + subscription gate + PDF endpoint | Unit compare + aged inventory + payment grid |
| 5 | Global search (scenario JOIN) | Print summary + global search badge |

**Cross-repo sequencing:** BE 0→1→2 before FE 1 (FE service needs real API shape). Then FE 0→1→2, then interleave BE 5 / FE 3→4→5 as endpoints land. STOP after each phase, confirm, no commit until explicit.
