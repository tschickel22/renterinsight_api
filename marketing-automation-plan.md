# Marketing Automation Add-On — Plan (v2)

**Product:** DMS add-on: AI-generated marketing campaigns fanned out across email, SMS, nurture, landing pages, and social — with a visual workflow view that shows the dealer *exactly what will happen* before they publish.
**Pricing:** 2 tiers, **per location**. Most dealers won't run many campaigns/month, so pricing is anchored on infrastructure + AI, not volume.
**Timeline:** ~4–5 weeks. We're rolling most of phase 2 into launch — workflow visualization + analytics + real infrastructure are non-negotiable for the differentiation to hold up.
**Positioning:** "HubSpot for MH/RV dealers who don't have a marketing team." One prompt in, full campaign out. HubSpot needs a marketer to draw workflows — this draws them for you.

---

## The demo (revised — the money shot)

Sales rep opens the dealer's DMS at the Anaheim location, clicks **Campaigns → New**, types:

> "New 2026 Clayton Homestead just arrived, 10% off list this month. Go."

Hits Enter. Progress ribbon walks through 7 steps in ~15 seconds:

1. ✓ Pulled 2026 Clayton Homestead from Anaheim inventory
2. ✓ Selected audience: 847 leads at this location tagged "MH-interested" + "active last 90d"
3. ✓ Drafted email (subject + body)
4. ✓ Drafted SMS
5. ✓ Drafted 3-step nurture sequence
6. ✓ Built landing page + 3 social posts (FB, IG, LinkedIn)
7. ✓ **Wired up the workflow** — 8 automated follow-ups based on how contacts respond

Screen lands on the **Campaign Review** page. Top of screen: **the Workflow Diagram** — a visual flowchart showing every branch of what happens after Publish. Below it: tabs for each asset (Email / SMS / Nurture / Landing / Social), all editable inline. **Publish All** button in the corner. **Test on my phone** button.

**The workflow diagram is the moment that closes the deal.** It's what HubSpot makes their customers spend 6 weeks building. Yours drew itself in 15 seconds.

Example rendering:

```
[Day 0]  ┌─ Email sent to 847 leads
         └─ SMS sent to 512 (SMS-opted-in subset)
              │
              ├──── OPENED (est. ~30%) ──────┐
              │                              ↓
              │                    [Day 2] Follow-up email:
              │                    "Still interested? Book a tour"
              │                              │
              │                              ├── CLICKED "Book a tour"
              │                              │        ↓
              │                              │   [Immediate] Workqueue task
              │                              │   → assigned to on-call rep
              │                              │   → "Call within 15 min"
              │                              │        ↓
              │                              │   [Auto] Appointment link sent
              │                              │
              │                              └── NOT CLICKED
              │                                       ↓
              │                              [Day 5] Nurture step 3:
              │                              SMS with photo + urgency
              │
              └──── NOT OPENED after 3 days
                              ↓
                    [Day 4] Re-send with new subject
                              ↓
                    Still not opened after 7 days? → tag as "cold", exit workflow
```

The dealer looks at this and their brain goes: *"Wait, it did all this from one sentence?"* That's the sale.

---

## What we build for v1 (~4–5 weeks)

Everything that matters ships in v1. Only truly-heavy items get punted to v2.

| Feature | v1 status | Reuses / notes |
|---|---|---|
| **Email campaigns via AWS SES** | Real | New infrastructure — see §Infrastructure below |
| **SMS campaigns via Twilio** | Real | Per-location provisioned number, 10DLC registered |
| **Nurture sequence enroll** | Real | §20 Polymorphic Nurture System |
| **Landing page on dealer site** | Real | §2 Public routes (`/c/:token`) |
| **Organic social posts** | Real | Already built — pending Meta/LinkedIn app approval |
| **Workflow visualization (planned + live)** | Real | New — the killer feature |
| **Workqueue integration (call reminders)** | Real | Already built — hook into it |
| **Automated appointment link sending** | Real | Reuses existing appointment feature |
| **Analytics dashboard** | Real | Opens, clicks, conversions, attribution to deals |
| **Compliance: CAN-SPAM footer, TCPA STOP, unsubscribe** | Real | Required, not optional |
| **Paid ads (Meta + Google)** | v2 | Ad account linking, budget approval — heavy lift |
| **A/B testing** | v2 | Nice-to-have, not core to the pitch |
| **Multi-campaign calendar view** | v2 | Add once dealers actually run overlapping campaigns |

---

## Infrastructure (new — this is the real work)

The reason a $300–400/location add-on is defensible is that we own the sending infrastructure. If dealers had to bring their own Twilio + Mailchimp, they wouldn't be paying us for this.

### AWS SES (email)

**Setup:**
- Dedicated sending domain: `mail.renterinsight.com` (or per-dealer subdomain: `dealer-name.mail.renterinsight.com` — better for deliverability isolation, more DNS work)
- SPF, DKIM, DMARC records — automated via Route53 when a dealer onboards
- Configuration Set per company (event tracking, IP pool assignment)
- Bounce + complaint handling via SNS → webhook → `EmailEventJob` → updates asset metrics and marks the contact
- Suppression list (SES-managed) so bounced addresses can't be re-sent to

**Why SES not OAuth email:** OAuth email (what dealers already have connected) is 1-to-1 conversational — great for reply-catching from sales reps. It's terrible for bulk marketing: rate limits are ~250/day (Gmail), Microsoft flags anything looking bulk as spam, no analytics. SES is designed for this: $0.10 per 1k emails, no per-account rate limit inside your sending quota.

**Deliverability tiers:**
- Warm the sending domain first — SES accounts start with 200/day, 1/sec send rate
- Request production access + sending quota increase (24hr approval, we get to ~50k/day quickly)
- Long-term: dedicated IP ($24.95/mo per IP) for dealers sending >10k/mo. Shared pool for the rest.

**Sending limits per tier (see Pricing):**
- Starter: 10k emails/mo/location
- Pro: 50k emails/mo/location (soft — overage billed at $0.005/email)

### Twilio (SMS)

**Setup:**
- Twilio subaccount per company (billing isolation, sub-account SID stored on Company)
- **Per-location phone number provisioning** — dealer picks a local area code at onboarding, we auto-provision via Twilio API
- **10DLC registration required** (US regulatory since 2023):
  - Brand registration ($44 one-time per company, we pay + pass through in pricing)
  - Campaign registration ($10 one-time per use case + $1.50–10/mo)
  - Marketing use case + sample messages submitted for approval
  - We pre-fill everything from company profile → dealer just approves
- STOP/HELP compliance auto-handled by Twilio Advanced Opt-Out
- Inbound webhook (`/webhooks/twilio/inbound`) routes replies back to the sales rep's conversation

**Sending limits per tier:**
- Starter: 2k SMS/mo/location
- Pro: 10k SMS/mo/location (soft — overage billed at $0.02/SMS)

**Cost pass-through:**
- Twilio: ~$1.15/mo per number + $0.0079/SMS
- Number provisioning: $0 (Twilio doesn't charge for standard local numbers)
- 10DLC campaign fees: $1.50–10/mo depending on use case tier

### Rate limiting + throttling

- Per-campaign send batch: max 200 emails/minute, max 60 SMS/minute (per location)
- Sidekiq queue per company (existing pattern) with rate-limited worker
- Failed sends retry 3× with exponential backoff, then hard-fail and log to `CampaignSendError`

---

## The Workflow Visualization (new killer feature)

This is the single most important thing in v1. It's what the dealer stares at before hitting Publish, and it's what makes them trust the automation.

### Two views

**1. Planned view (pre-publish, editable)**

Vertical flowchart, top-down. Each node is either:
- **Trigger**: campaign event (sent, opened, clicked, replied, form-filled)
- **Delay**: `wait N days` or `wait until N days after last action`
- **Action**: send email, send SMS, enroll in nurture, create workqueue task, send appointment link, tag contact, notify user
- **Condition**: if/else branch on contact state

The AI auto-generates a default workflow from the campaign prompt using best-practice patterns per campaign type:

| Campaign type | Default workflow |
|---|---|
| **New arrival / New model** | Email → nurture step 2 (day 3) → nurture step 3 (day 7 if not clicked) → workqueue call task if clicked |
| **Sale / Discount** | Email + SMS same day → workqueue call on click → SMS reminder day 3 if not clicked → final email day 6 with urgency |
| **Event announcement** | Email → SMS 1 day before → workqueue call to top 20 leads day-of → thank-you follow-up 2 days after |
| **Trade-in / Financing offer** | Email → landing page click → nurture step 2 with pre-approval CTA → workqueue task if pre-approval started |

User can drag nodes, add branches, delete steps, edit delays. **All inline, no separate builder tool.**

**2. Live view (post-publish, read-only, real-time)**

Same diagram, overlaid with live metrics per node:

```
[Day 0] Email sent  ─── 847 sent, 234 opened (27.6%), 47 clicked (5.5%)
   │
   ├── Opened  ─── 234 entering next step
   │      ↓
   │   [Day 2] Follow-up  ─── 234 sent, 89 opened, 21 clicked
   │      │
   │      ├── Clicked  ─── 21 entering workqueue
   │      │      ↓
   │      │   Workqueue task  ─── 21 created, 18 called, 12 booked, 4 deals ($47k)
   │      ...
```

Each node clickable → drills into the individual contacts + their state. The dealer can watch the workflow *breathe* in real-time. This is what nobody in MH/RV has ever seen.

### Technical implementation

**Data model:**

```
CampaignWorkflow (belongs_to :campaign)
├─ id, campaign_id
├─ nodes: JSONB (react-flow compatible)
│   [
│     { id, type: 'trigger'|'delay'|'action'|'condition',
│       config: {...}, position: {x, y} },
│     ...
│   ]
├─ edges: JSONB
│   [ { from_node_id, to_node_id, label } ]
├─ status: draft | active | paused | completed
└─ live_metrics: JSONB (materialized from CampaignWorkflowEvent — updated hourly)

CampaignWorkflowEvent (append-only event log)
├─ id, workflow_id, node_id
├─ contact_id, contact_type (Lead|Contact)
├─ event_type: entered_node | exited_node | action_completed | branch_taken
├─ occurred_at, metadata: JSONB
└─ (indexed for fast rollup queries)
```

**Frontend:** `react-flow` (already used elsewhere in the app for pipelines) — proven, small bundle, good animation support.

**Execution engine:**
- `WorkflowExecutorJob` runs every 15 min, checks for contacts due for next step
- Reuses existing `NurtureEnrollment` scheduling primitives — this is basically nurture++
- Every advance writes a `CampaignWorkflowEvent` for the live view

---

## Analytics (moved into v1)

Not a separate dashboard — lives inside the campaign detail page as tabs.

**Campaign KPIs (top of Review page):**
- Emails: sent / delivered / opened (%) / clicked (%) / unsubscribed
- SMS: sent / delivered / clicked / STOP replies
- Landing page: visits / form fills / conversion %
- Social: reach / engagement (populated when platform APIs return it)
- **Attributed pipeline**: leads created + deals attributed + dollar value in pipeline + closed-won $
- Workqueue tasks: created / completed / conversion to appointment

**Attribution rule (v1):** UTM tags on all links (auto-generated per campaign + channel). Leads/deals created within 30 days of first click get credited to the campaign. Simple, defensible, matches how HubSpot does it.

**Backend:**
- Reuses SES event webhooks (`open`, `click`, `bounce`, `complaint`)
- Reuses Twilio delivery status webhooks
- Meta/LinkedIn insights pulled on a cron once APIs are wired
- Attribution rollup runs nightly, materializes to `campaign_analytics_daily`

---

## Entity model (revised)

```
Campaign
├─ id, company_id (tenant-scoped, immutable — §16)
├─ location_id (per-location scoped — §9)
├─ name, prompt (free-text input)
├─ campaign_type: new_arrival | sale | event | financing | announcement | custom
├─ status: draft | reviewing | scheduled | active | completed | archived
├─ trigger_data: JSONB (parsed prompt → structured)
├─ audience_segment: JSONB (tag filters + saved lead/contact ids)
├─ scheduled_at, published_at
├─ created_by_user_id
├─ analytics_summary: JSONB (rolled up nightly)
└─ custom_field_values: JSONB (§24)

CampaignAsset (polymorphic children)
├─ campaign_id, asset_type: email | sms | nurture_sequence | landing_page | social_post
├─ platform: null | facebook | instagram | linkedin (social only)
├─ status: draft | approved | scheduled | sent | failed
├─ content: JSONB (per-type structure)
├─ ai_prompt_used, ai_model, ai_generated_at
└─ metrics: JSONB (per-asset opens/clicks/etc.)

CampaignWorkflow (see Workflow section above)
CampaignWorkflowEvent (append-only event log)

CampaignSendError (retry/dead-letter tracking)
├─ campaign_id, asset_id, contact_id
├─ channel, error_code, error_message, retry_count
└─ retryable_at, resolved_at
```

**Reuses:**
- Company + Location scoping (§3, §9, §16)
- Polymorphic asset shape mirrors your `Communication` and `NurtureEnrollment`
- Tagging (§19) for audience segmentation
- Custom fields (§24) for extensibility
- Public routes (§2) for landing pages
- Nurture engine (§20) as workflow execution primitive
- Existing workqueue for call task creation

---

## Frontend structure

```
src/modules/marketing-campaigns/
├─ pages/
│   ├─ CampaignsList.tsx        # §22 server-side search + stats tiles
│   ├─ NewCampaign.tsx          # prompt bar + wizard fallback
│   └─ CampaignReview.tsx       # workflow diagram on top + asset tabs below
├─ components/
│   ├─ PromptBar.tsx
│   ├─ GenerationProgress.tsx   # ActionCable subscription — §13
│   ├─ WorkflowDiagram/
│   │   ├─ PlannedView.tsx      # react-flow, editable
│   │   ├─ LiveView.tsx         # react-flow, read-only, real-time metrics
│   │   ├─ NodeTypes/           # TriggerNode, DelayNode, ActionNode, ConditionNode
│   │   └─ NodeConfigPanel.tsx  # right sidebar when node selected
│   ├─ AssetEditor/
│   │   ├─ EmailEditor.tsx      # rich text + regenerate
│   │   ├─ SmsEditor.tsx        # char counter, STOP footer preview
│   │   ├─ NurtureEditor.tsx    # reuses NurtureSequencesTab
│   │   ├─ LandingPageEditor.tsx  # §24 inline-edit pattern
│   │   └─ SocialPostEditor.tsx   # tabbed per platform
│   ├─ AudienceSelector.tsx     # tag + segment filter with live count
│   ├─ AnalyticsTab.tsx         # per-campaign KPIs + attribution
│   ├─ TestSendModal.tsx        # send to my phone/email
│   └─ ComplianceBanner.tsx     # CAN-SPAM, TCPA opt-in status
└─ services/campaignsService.ts # apiClient — §4
```

---

## Pricing (revised — 2 tiers, per location)

| | **Starter** | **Pro** |
|---|---|---|
| **Price** | **$299/location/mo** | **$449/location/mo** |
| Campaigns/month | Unlimited (soft-capped by send limits) | Unlimited |
| Email sends/mo/location | 10,000 | 50,000 |
| SMS sends/mo/location | 2,000 | 10,000 |
| Twilio number (per location) | ✓ | ✓ |
| SES sending domain | Shared | Dedicated subdomain |
| AI content generation | ✓ | ✓ |
| Workflow visualization | ✓ | ✓ |
| Landing pages | ✓ | ✓ |
| Organic social posting | ✓ | ✓ |
| Analytics dashboard | Campaign-level | + Multi-campaign rollup, custom reports |
| Attribution to pipeline | ✓ | ✓ |
| Overage rate | $0.005/email, $0.02/SMS | $0.005/email, $0.02/SMS |
| Setup fee | $0 (self-serve onboarding) | $299 (dedicated onboarding call) |

**Why 2 tiers, not 3:** Most dealers won't run enough campaigns to justify a middle tier. Starter is the on-ramp; Pro is for multi-location operators who want dedicated deliverability + reporting. Anchor pitch at $299 on the first sale, upsell to Pro once they hit send limits or add a second location.

**Cost pass-through structure (your margin):**

| Cost | Starter | Pro |
|---|---|---|
| Twilio number ($1.15/mo) | $1.15 | $1.15 |
| Twilio 10DLC fees | ~$3/mo | ~$3/mo |
| SES sending (~10k emails avg) | $1 | $5 |
| Claude API (est. 30 campaigns/mo) | $6 | $9 |
| Dedicated IP (Pro only) | — | $25 |
| **Total cost** | **~$11** | **~$43** |
| **Gross margin** | **~96%** | **~90%** |

Even at very heavy usage, you're pocketing $250+/location/mo.

**Multi-location math for pitch:**
- Evangeline (3 locations) = $897/mo Starter or $1,347/mo Pro
- That's HubSpot Marketing Hub Professional territory ($800–$3,600/mo *total*, not per-location) — and HubSpot doesn't touch their inventory or CRM.

---

## Compliance (v1 must-haves)

- **CAN-SPAM footer** auto-appended to every email: physical mailing address (from Company profile), one-click unsubscribe link, plain-text preference
- **Unsubscribe center** at `/u/:token` (public route — §2 checklist) with granular preferences (all campaigns, just this campaign, marketing only vs transactional)
- **TCPA compliance for SMS:** double opt-in on any web form → SMS consent recorded on `Consent` model with timestamp + IP + form ID. No SMS to any contact without a Consent record. STOP handled automatically by Twilio.
- **Suppression list** enforced at send-time: SES bounce, complaint, unsubscribe, TCPA opt-out — all block future sends automatically. Cross-company suppression on hard bounces (protect your sending reputation).
- **Audit log:** every send, every consent change, every unsubscribe stamped with user + timestamp for the next 7 years (legal retention).

Nothing here is negotiable — it's what keeps your SES account from getting suspended and your Twilio account from getting flagged.

---

## Content generation (unchanged from v1 draft)

Claude API + template library. Each asset type has a curated system prompt tuned for MH/RV dealer voice. Prompt parsing happens once at the top, then 5 asset generators fan out in parallel. Regenerate button on each asset (~$0.05 per regen).

Cost estimate: ~$0.15–0.30 per full campaign generation. Included in tier pricing.

---

## Revised 4–5 week build plan

**Week 1 — Infrastructure**

| Day | Work |
|---|---|
| 1 | SES setup: sending domain, DKIM/SPF/DMARC, config set, bounce/complaint SNS handlers |
| 2 | Twilio: subaccount provisioning per company, per-location number provisioning API, 10DLC brand + campaign registration flow |
| 3 | Suppression list model, unsubscribe center at `/u/:token`, Consent model, CAN-SPAM/TCPA footer templates |
| 4 | `Campaign` + `CampaignAsset` migrations, models, controllers (§16 audit) |
| 5 | Rate-limited send workers (Sidekiq), retry + dead-letter (`CampaignSendError`) |

**Week 2 — AI generation**

| Day | Work |
|---|---|
| 6 | Claude API integration, prompt parser, structured trigger_data extraction |
| 7 | Email + SMS asset generators + brand voice templates |
| 8 | Nurture asset generator (creates NurtureSequence + Steps), landing page generator |
| 9 | Social post generator (3 platforms — copy structure for existing social publishing) |
| 10 | Default workflow auto-generation per campaign_type (the 4 patterns in §Workflow) |

**Week 3 — Workflow engine + visualization**

| Day | Work |
|---|---|
| 11 | `CampaignWorkflow` + `CampaignWorkflowEvent` models, workflow executor job |
| 12 | Workflow-node action handlers (send email, send SMS, create workqueue task, send appointment link, tag contact) |
| 13 | react-flow `PlannedView.tsx` with node types (Trigger, Delay, Action, Condition) |
| 14 | Node config panels, drag-and-drop edit, add/delete branches |
| 15 | `LiveView.tsx` with real-time metrics overlay, node drill-down |

**Week 4 — Frontend + analytics**

| Day | Work |
|---|---|
| 16 | `CampaignsList.tsx` + `NewCampaign.tsx` prompt bar |
| 17 | `GenerationProgress.tsx` ActionCable, `CampaignReview.tsx` shell |
| 18 | Asset editors: Email, SMS, Nurture, Landing Page (§24 inline-edit) |
| 19 | Social post editor (real publishing wired up once app approval lands), test send modal |
| 20 | Analytics tab: KPIs, attribution rollup, deal-pipeline linkage |

**Week 5 — Polish + launch prep**

| Day | Work |
|---|---|
| 21 | End-to-end test with a real dealer's inventory + lead data |
| 22 | Deliverability warming: send test volumes from SES, confirm inbox placement |
| 23 | Compliance audit: CAN-SPAM, TCPA, unsubscribe flows, suppression list enforcement |
| 24 | Billing integration: Starter/Pro plan gating, overage tracking, Stripe metered billing |
| 25 | Demo dealer seeded, pitch practiced, launch checklist signed off |

**Buffer:** if 10DLC registration approval slows down (it can take up to 5 business days), we ship without SMS for the first pilot and add it in week 6.

---

## v2 (post-launch)

Explicitly out of scope until we see real usage:

- **Paid ads** (Meta Ads + Google Ads) — ad account linking, budget approval, creative asset upload, spend reconciliation
- **A/B testing** on subject lines / SMS copy
- **Multi-campaign calendar view**
- **AI voice campaigns** (outbound calls via Twilio ConversationRelay)
- **Deeper attribution** (multi-touch, view-through)
- **Custom domain for landing pages** (dealer wants `promo.dealername.com` instead of `dealer.renterinsight.com`)
- **Team collaboration** (approval workflows before Publish)

Track as tickets, don't build.

---

## Positioning vs HubSpot (unchanged, still strong)

| HubSpot | Renter Insight Marketing |
|---|---|
| $800–$3,600/mo Marketing Hub + implementation | $299–$449/location, live day one |
| Requires a marketer to configure workflows | Workflow drawn from one sentence |
| Generic templates | Trained on your inventory + brand voice |
| Separate system to keep in sync with CRM | Same system as deals, inventory, workqueue |
| Landing pages need designers | Auto-generated from campaign brief |
| Manual attribution setup | Automatic — every link UTM-tagged |
| SMS is a paid add-on ($75+/mo/user) | Included, with a dedicated number per location |

**One-liner:** *"HubSpot for MH/RV dealers — one prompt, full workflow, tied to your inventory. $299/location, live tomorrow."*

**Objection answers:**
- *"Can I edit before publish?"* → Yes. Every asset editable inline. Workflow diagram is drag-and-drop. Nothing sends until you hit Publish.
- *"What if AI writes something bad?"* → Preview + test-send before publish. Every dealer sets brand voice + blocked words.
- *"Does it work with my Mailchimp / Constant Contact?"* → Replaces it. Uses your provisioned Twilio number + your dedicated SES domain so deliverability is under our control, not shared with strangers.
- *"What about compliance?"* → CAN-SPAM footer auto-included. TCPA opt-in required for SMS. STOP handled automatically. Full audit log for 7 years.
- *"How much does the SMS cost?"* → Included in your tier. Twilio number, 10DLC registration, and per-message fees are all bundled.

---

## Open questions for you

1. **Sending domain strategy:** Shared `mail.renterinsight.com` for Starter and dedicated `dealer.mail.renterinsight.com` for Pro — or single shared for everyone until we see volume? (I recommend the tiered approach — better deliverability isolation.)
2. **Per-location number provisioning:** Do dealers get to pick their own area code, or do we auto-assign based on location? (Recommend: dealer picks area code from a list we show them, we grab whatever number is available.)
3. **Analytics attribution window:** 30 days from first click is my default. Some CRMs use 90. Which fits MH/RV sales cycles better? (My guess: 60 days — MH deals close slower than SMB SaaS but faster than enterprise.)
4. **Setup fee on Pro:** Included the $299 setup because Pro dealers need dedicated domain onboarding. If you'd rather keep it clean (no setup fee), we can absorb it — costs us ~2 hours of ops time per Pro dealer.

---

## Next actions

1. Read through, poke holes on the workflow visualization + infrastructure sections (biggest changes).
2. Answer the 4 open questions above.
3. When you're ready, say **"start week 1"** and I'll spin up:
   - SES infrastructure setup (Route53 records, config set, SNS handlers)
   - Twilio subaccount provisioning code
   - Initial `Campaign` + `CampaignAsset` migrations and models

---

## Claude Code audit prompt

Paste this into Claude Code running against `~/src/renterinsight_api` (and cross-reference the frontend repo where relevant):

```
Read marketing-automation-plan.md. Audit every claim I made about
"reuses existing X" against the actual code in this repo. For each
one, either:
  - Confirm it works as described (with the specific file/method/class),
  - Correct my assumption (what actually exists, what it can/can't do), or
  - Flag as "doesn't exist, needs to be built" and estimate cost.

Focus on these specifically:
  - NurtureEnrollment: can it execute branching workflows with
    conditional next-steps, or is it linear only? What's the executor
    entrypoint?
  - Workqueue: how are call tasks created? Is there an existing
    "notify on-call rep" primitive I can hook into?
  - Communication model: fields, polymorphic associations, whether
    it can carry campaign-attribution metadata cleanly
  - Social posting: which platforms are wired, what's the publishing
    method signature, where does it live
  - ActionCable channels: any collision risk with a new CampaignChannel
  - Appointment / booking flow: how a workflow node could trigger
    "send appointment link"
  - Landing page / public routes: are the §2 patterns (App.tsx,
    useBranding.ts, api.ts) actually implemented the way the
    instructions describe

Return a revised plan with:
  - Every reuse claim replaced with the actual code reference
  - Any assumption that's wrong marked ❌ and rewritten
  - A new "Missing primitives" section listing what genuinely needs
    to be built from scratch vs. what I underestimated as "reuse"
```
