# Marketing Automation Add-On — Plan v3 (code-audited)

Audited against `~/src/renterinsight_api` @ `staging` (4cb609c5) and
`~/src/Platform_DMS_8.4.25`, 2026-07-27. Every "reuses existing X" claim from v2
is confirmed with a file reference, corrected, or marked ❌.

---

## Headline finding

**v2 was written as if the campaign engine doesn't exist. It does.** There is a
complete, shipped campaign system (11 models, 10 controllers, 12 services, an AI
builder, suppression, link tokenization, unsubscribe, throttling, bounce
harvesting, analytics timeseries) and a complete, shipped **branching workflow
engine with a react-flow canvas**.

Weeks 1–3 of the v2 build plan are ~75% already in the repo. The genuinely new
work is much smaller than v2 claims — but it is *different* work, and one piece
of it (the campaign→workflow event bridge) is load-bearing for the entire demo
and appears nowhere in v2.

---

## Claim-by-claim audit

### 1. "Email campaigns via AWS SES — **New infrastructure**" ❌ half wrong

**What exists:** the entire send pipeline.
- `app/services/campaigns/campaign_sender.rb` — `#deliver_email` / `#deliver_sms`
- `app/jobs/process_campaign_send_job.rb`, `app/jobs/campaign_scheduler_job.rb`
- `app/services/providers/email/aws_ses_provider.rb` (+ `gmail_relay`,
  `microsoft_graph`, `smtp`), `app/services/providers/sms/twilio_provider.rb`
- `app/services/messaging/` — `email_renderer`, `sms_renderer`, `block_renderer`,
  `pixel_injector`, `link_tokenizer`, `unsubscribe_footer`, `merge_tag_resolver`,
  `send_window_calculator`, `throttle_checker`, `inventory_block_resolver`

**The correction that matters:** campaigns **deliberately do not bulk-send via
SES today.** `campaign_sender.rb:138-147` selects the provider from the *owner's
OAuth connection* (`oauth_gmail` → `:oauth_google`, `oauth_outlook` →
`:oauth_microsoft`, else `:smtp`). SES is reached only when
`test_platform_send?` is true (test sends). `Campaign#resolve_email_connection`
carries an explicit comment: *"NEVER falls back to platform."*

So the SES work is **not** "build a sending pipeline." It is:
1. A policy/config change — add an SES delivery mode alongside the OAuth mode,
   and a per-company switch for which one a campaign uses.
2. Real deliverability infra (domain, DKIM/SPF/DMARC, config set, dedicated IP).
3. Bounce/complaint SNS ingestion for the *campaign* path.

Note there is already SNS plumbing to copy: `app/controllers/webhook/inbound_mail_controller.rb`
(auto-confirms `SubscriptionConfirmation`, parses SES notifications) and
`app/jobs/process_webhook_job.rb:59-65`.

Also already built for bounces on the OAuth path:
`app/services/campaigns/inbound_bounce_harvester.rb`,
`app/jobs/harvest_campaign_bounces_job.rb`, `app/services/campaigns/bounce_handler.rb`.

**Revised estimate: 2 days, not 5.** Most of it is DNS/AWS console + one provider
branch, not code.

---

### 2. "SMS via Twilio — subaccount per company, 10DLC brand registration" ❌ wrong architecture — but **campaigns are approved; provisioning is unblocked**

> **Decision (2026-07-27):** A2P campaigns are approved on the master brand.
> Minor Twilio-side setup remains, then customer number provisioning can begin.

**The one config that gates it** — `TwilioProvisioningService.enroll_in_messaging_service`
(`twilio_provisioning_service.rb:188-200`) is **non-fatal**: if
`messaging_service_sid` is blank it logs
`"No MessagingServiceSid configured — NOT enrolled in A2P sender pool"` and
provisioning still reports success. A number provisioned in that state works but
sends outside the approved A2P sender pool, so carriers filter it — and nothing
in the API response says so.

Set it in either place (`twilio_provisioning_service.rb:48-53`):
- `TWILIO_MESSAGING_SERVICE_SID` env var, or
- Platform Settings → Communications → SMS → `twilioMessagingServiceSid`
  (`Setting.get('Platform', 0, 'communications')['sms']`)

⚠️ **Second thing to set before provisioning real customers:**
`configure_webhook_on_master` (`twilio_provisioning_service.rb:179`) points each
new number's inbound SMS webhook at
`ENV['API_BASE_URL'] || 'https://renterinsight-api-staging.onrender.com'`.
**If `API_BASE_URL` is unset in production, every number you provision routes
inbound SMS to staging** — same failure shape as the `APP_URL` issue. Verify
before the first customer number.

Worth adding after those two: fail (or at minimum surface a warning in the
provisioning response) when the Messaging Service SID is missing, rather than
silently returning success. ~1 hour.


`app/services/twilio_provisioning_service.rb:1-12` documents that the
sub-account approach **was tried and abandoned**:

> *"numbers are purchased directly on the MASTER Twilio account… Previous
> approach (sub-accounts) was abandoned because phone numbers owned by a
> sub-account cannot be enrolled in the master account's Messaging Service,
> making A2P compliance impossible without per-sub-account registration
> (~$4-8/mo each)."*

**What exists:** `TwilioProvisioningService.provision_client(company, area_code:)`
buys a number on the master account, enrols it in the master Messaging Service
(`twilio_provisioning_service.rb:190`), and writes a `TwilioAccount` row
(`company_id`, `location_id`, `phone_number` E.164, `phone_number_sid`, status
machine). `TwilioAccount.resolve_for(company_id:, location_id:)` does the
location→company waterfall. Inbound: `app/controllers/webhooks/twilio_controller.rb:136`
handles STOP/START for A2P.

**Corrections to the plan:**
- ❌ Per-company 10DLC brand registration ($44) + campaign registration ($10 +
  $1.50–10/mo) — **not how this works here.** One master A2P registration covers
  all numbers. Your cost model's "~$3/mo 10DLC per location" is wrong; it's a
  fixed platform cost amortised across all tenants.
- ✅ Per-location number provisioning with dealer-chosen area code — already
  built, including `AreaCodeUnavailableError`.
- ⚠️ Open question #2 ("do dealers pick an area code?") is already answered by
  the code: yes, `area_code:` is a parameter.

**Revised estimate: ~1 hour of code** (surface the missing-SID case), plus the
two env/settings values above. The marketing use-case registration that v2
budgeted for is already approved.

---

### 3. "Nurture sequence enroll — §20 Polymorphic Nurture System" ✅ exists / ❌ **linear only**

**Executor entrypoint:** `ProcessNurtureStepJob.perform_later(enrollment_id)`
(`app/jobs/process_nurture_step_job.rb`). Self-rescheduling:
`ProcessNurtureStepJob.set(wait: wait_days.days).perform_later(enrollment.id)` at
line 66.

**It is strictly linear.** `process_nurture_step_job.rb:60-67`:
```ruby
next_index = current_index + 1
if next_index < steps.count
  enrollment.update!(current_step_index: next_index)
```
Unconditional increment. `NurtureStep` has `position`, `wait_days`, `step_type`,
`subject`, `body`, `channel`, `attachments`, `include_inventory` — **no
condition, no branch, no edges, no next_step_id** (`db/schema.rb:4467-4486`).
Step types handled: `email`, `sms`, `wait`, `task`, `call`. Anything else logs
"Unknown step type".

`NurtureEnrollment` (`db/schema.rb:4438-4455`) is `enrollable_type/_id` +
`current_step_index` + `context` JSONB. Polymorphic ✅ (Lead/Contact/Account/Deal).

> ❌ **"Reuses existing `NurtureEnrollment` scheduling primitives — this is
> basically nurture++"** — this is the single most consequential wrong assumption
> in v2. Nurture cannot branch and was never designed to. Building branching on
> top of it means rewriting it.
>
> **The branching engine you want already exists and it is `WorkflowRule` /
> `WorkflowRun`.** See §4.

Same linearity applies to campaigns: `CampaignEnrollment#advance_to_next_step`
(`app/models/campaign_enrollment.rb:32-46`) does `current_step_index + 1` against
`campaign_steps.active.ordered`. Campaign drips are linear too.

---

### 4. "Workflow visualization (planned + live) — **New — the killer feature**" ❌ ~70% already built

This is the biggest correction. Everything below already exists:

| v2 proposed | Already in repo |
|---|---|
| `CampaignWorkflow.nodes` JSONB (react-flow compatible) | `workflow_rules.steps` JSONB = `{nodes: [], edges: []}` (`db/schema.rb:7345`; read at `process_workflow_step_job.rb:37`, `workflow_engine.rb#rule_entry_step_id`) |
| `CampaignWorkflow.edges` JSONB | same column; traversed by `StepExecutors::Base#next_step_from_edges` (`source`/`target`) |
| `CampaignWorkflow.status draft\|active\|paused\|completed` | `workflow_rules.status` = `draft\|active\|paused\|archived` |
| `CampaignWorkflowEvent` append-only log | `WorkflowRunStep` — `step_id`, `step_type`, `status`, `input`, `output`, `error`, `duration_ms`, timestamps. Written by `WorkflowRun#record_step` on **every** step. |
| `WorkflowExecutorJob` every 15 min | `ProcessWorkflowStepJob` (event-driven, not polled) + `ResumeWaitingWorkflowRunsJob` + `WorkflowCronDispatcherJob` + `DispatchWorkflowEventsJob` |
| Node types: trigger / delay / action / condition | `trigger` = `workflow_rules.trigger` JSONB; `delay` = `wait` executor; `condition` = `branch` executor; 17 action executors |
| "AI auto-generates a default workflow from the prompt" | `app/services/workflows/ai_builder.rb` — already generates full nodes/edges graphs from a prompt, with a `TRIGGER_EVENT_TYPES` + `STEP_TYPES` catalog and per-company custom-field context |
| `react-flow` frontend, PlannedView editable | `src/modules/workflow-automation/pages/WorkflowCanvas.tsx` using `@xyflow/react` ^12.10.2, with `components/canvas/StepNode.tsx`, `NodePropertiesPanel.tsx`, `lib/canvasSerialization.ts` |
| Node drill-down to individual contacts | `src/modules/workflow-automation/pages/RunDetail.tsx` + `components/StepsTimeline.tsx`, `RunsTable.tsx`, `MetricsSummary.tsx` |

**Branching is real.** `WorkflowEngine::StepExecutors::Branch`
(`app/services/workflow_engine/step_executors/branch.rb`) evaluates
`config.condition_structured` via `ConditionEvaluator` against the **live**
entity and returns `on_true_branch` / `on_false_branch` as `next_step_id`.

Full executor set (`process_workflow_step_job.rb:4-21`): `send_email`,
`send_sms`, `update_field`, `create_activity`, `wait`, `wait_for_reply`,
`branch`, `require_approval`, `enroll_in_nurture`, `halt_nurture`,
`assign_owner`, `add_tag`, `remove_tag`, `call_webhook`, `score_entity`,
`classify_reply`.

Reply-driven branching already works end-to-end:
`Communication#notify_workflow_of_inbound` → `WorkflowEngine.handle_inbound_reply`
→ resume / cancel / set `reply_received` for a downstream branch
(`workflow_engine.rb:63-92`, `communication.rb` `after_create`).

> ❌ **Drop `CampaignWorkflow` and `CampaignWorkflowEvent` entirely.** They
> duplicate `WorkflowRule` and `WorkflowRunStep`. Adding them creates a second
> workflow engine in the same product.

**What's actually left to build here:**
- **Live metrics overlay** on the existing canvas (per-node aggregate counts).
  The data is already in `WorkflowRunStep` — this is a `GROUP BY step_id, status`
  rollup endpoint + a read-only canvas mode. ~2 days, not 5.
- Campaign-scoped filtering of runs (needs §9's bridge to exist first).

---

### 5. "Workqueue integration (call reminders) — Already built, hook into it" ⚠️ half right

**❌ There is no workqueue task creation, and no "notify on-call rep" primitive.**

`WorkqueueService` (`app/services/workqueue_service.rb`) is a **read-only
aggregator**. It maps ~30 queue ids to AR scopes and paginates/normalises them —
`QUEUES` constant at the top of the file. It creates nothing.

**How a "call task" actually gets created:** you create a
`LeadActivity`/`ContactActivity`/`DealActivity`/`AccountActivity` with
`activity_type: 'call'`, `assigned_to_id`, `due_date`. The queue
`activity_calls_due` (`workqueue_service.rb:412-417`) then surfaces it:
```ruby
WorkqueueActivity.where(company_id:, assigned_to_id: @user.id, activity_type: 'call')
                 .where.not(status: %w[completed cancelled])
                 .where('due_date <= ?', Date.current.end_of_day)
```

Two existing creation paths to copy:
- `WorkflowEngine::StepExecutors::CreateActivity` — the workflow path. Handles
  assignee resolution, creator FK fallback, and 4 due-date strategies
  (`due_date_field` / literal / `due_in_days` / `due_in_hours`).
- `ProcessNurtureStepJob#create_lead_call_activity` / `#create_contact_call_activity`
  — the nurture path.

**"On-call rep" — ❌ doesn't exist as such.** The closest primitive is
`RoundRobinAssignmentList#next_active_user!` (`app/models/round_robin_assignment_list.rb`)
— atomic cursor advance under `with_lock`, skips `status != 'active'`, wraps.
Used by the `AssignOwner` executor and inbound-webhook token configs.

But `CreateActivity#resolve_assignee` only understands `"owner"` or a literal
numeric user id — **it cannot take a round-robin list id.** That's a small, real
gap (~half a day) and it's exactly what the demo's "→ assigned to on-call rep"
node needs.

**"Notify" — ❌ no `notify_user` executor.** `NotificationService.create(...)`
exists and `ActivityNotificationService` broadcasts over ActionCable
(`activity_notification_service.rb:145`). Wrapping that as a workflow executor
is ~half a day.

**Bonus finding that helps the pitch:** the workqueue **already surfaces campaign
engagement** without any workflow at all —
`engagement_opened_today`, `engagement_opened_week`, `engagement_clicked_today`,
`engagement_hot_reopeners`, `engagement_contact_*` read `CampaignSend.opened_at` /
`clicked_at` directly (`workqueue_service.rb:625-642`). "They clicked, it's in
your queue" is live today.

---

### 6. "Polymorphic asset shape mirrors your `Communication`… can it carry campaign-attribution metadata?" ✅ — it already does

`Communication` (`app/models/communication.rb`):
- `communicable` polymorphic (Lead/Contact/Account/Quote/…), plus `company`,
  `communication_thread`, `template`, **`belongs_to :workflow_run`**
- `metadata` JSONB, normalised by `before_save :normalize_metadata` →
  `deep_stringify_keys` (matches the CLAUDE.md rule)
- `has_many :communication_events`, `has_many :tracked_links` (`dependent: :nullify`)
- channels `email|sms|portal_message`; providers include `aws_ses`, `twilio`,
  `gmail_relay`, `smtp`
- a `campaign_send_id` column (written at `campaign_sender.rb:178`)

**Campaign attribution is already written on every campaign send**
(`campaign_sender.rb:148-154`):
```ruby
metadata_hash = { campaign_id:, campaign_send_id:, campaign_step_id:,
                  source: 'campaign', attachments: [...] }
```
`CommunicationEvent` tracks `sent|delivered|opened|clicked|bounced|failed|unsubscribed|spam_report`
with `ip_address`, `user_agent`, `details` JSONB, and `after_create` syncs
`Communication#status`.

✅ Confirmed, no work needed. Do **not** add a parallel `CampaignAsset.metrics`
JSONB — it would immediately drift from `CampaignSend`/`CommunicationEvent`.

---

### 7. "Organic social posts — already built, pending Meta/LinkedIn app approval" ⚠️ Meta ✅ / LinkedIn ❌ doesn't exist

**Wired platforms: Facebook Page + Instagram Business. That's it.**
A repo-wide grep for `linkedin` returns two hits, both unrelated
(`custom_field.rb:157` keyword list; `websites_controller.rb:735` a social-links
field on the website builder). **There is no LinkedIn OAuth, client, or publish
path.**

**Publishing signature:** `PublishSocialPostJob.perform_later(post_id)`
(`app/jobs/publish_social_post_job.rb`). It:
- gates on `post.status == 'approved'` OR (`'scheduled'` AND `scheduled_at <= now`)
- resolves credentials from **`FacebookIntegration.active.where(company_id:)`** —
  note: *not* `SocialAccount`, which also exists and is unused on this path
- IG branch requires ≥1 `image_urls` entry + `metadata['instagram_business_account_id']`
- calls `MetaGraphApi.publish_page_post(page_id, token, message:, link:, photo_url:)`
  or `MetaGraphApi.publish_instagram_post(ig_id, token, caption:, image_url:)`
  (`app/services/meta_graph_api.rb`)
- typed errors: `ExpiredTokenError` → marks integration expired;
  `RateLimitError` → re-enqueue at +15 min; `Error` → mark post failed
- fires a `social_post.published` webhook

**Also already built** (v2 lists these as future work): `SocialPostSchedule` +
`GenerateScheduledSocialPostsJob` + `PublishDueSocialPostsJob` (scheduling),
`SyncSocialPostMetricsJob` (reach / impressions / engagement_count / link_clicks
→ columns on `social_posts`), `SyncSocialCommentsJob`, `FacebookTokenRefreshJob`,
`SocialPostGeneratorService` (AI copy), `AdCampaign` + `MetaAdSpendService` +
`SyncAdSpendJob` (**paid Meta ads — v2 puts this in v2-post-launch; it's partly
in the repo already**).

`social_posts` already has `utm_campaign`, `utm_content`, `tagged_url`,
`lead_count`, `deal_count`, `attributed_revenue`.

> **Decision (2026-07-27): Meta only. LinkedIn is out.** The demo script's
> "3 social posts (FB, IG, LinkedIn)" becomes **2 (FB + IG)**. Nothing to build —
> the Meta path is done.

⚠️ **One assumption to correct:** Microsoft app approval will **not** carry over
to LinkedIn. Microsoft owning LinkedIn doesn't mean shared app identity or
review. They are separate programs with separate portals:
- **Microsoft Entra ID app registration / publisher verification** (developer
  portal: Azure/Entra) — what gates `Providers::Email::MicrosoftGraphProvider`
  and Outlook OAuth for campaign sending. This is the approval you're close to,
  and it unblocks **email**, which matters for §1.
- **LinkedIn Developer app review** (developer.linkedin.com) — separate app,
  must be associated with a LinkedIn Page, and posting requires requesting a
  specific API product (`Share on LinkedIn` for member posts /
  `Community Management API` for organization posts, the latter gated behind its
  own review).

So the MS approval is genuinely valuable — just bank it against email
deliverability, not LinkedIn. When LinkedIn does come up, treat it as a full
from-scratch integration (OAuth + UGC Posts API + its own review cycle).

---

### 8. "ActionCable channels — collision risk with a new `CampaignChannel`?" ✅ no collision, ⚠️ different real risk

Only three channels exist: `UserNotificationsChannel` (streams
`user_notifications_<id>` **and** `lead_notifications_<id>`),
`LeadNotificationChannel`, `ImportProgressChannel` (`import_progress_<job_id>`).
No campaign channel, no name collision.

**The real risk is the adapter.** `config/cable.yml` is `adapter: async` in
development, staging, and production (CLAUDE.md mandates this and forbids
`solid_cable`). `async` is an **in-process** pub/sub — a broadcast only reaches
subscribers connected to the same Ruby process.

This currently works because background jobs run *inside the web process*:
`config/environments/production.rb:56-58` uses `solid_queue`, and
`config/puma.rb:37` loads `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]`.
So `GenerationProgress.tsx` will work today.

⚠️ Two caveats to write down before building on it:
1. If Render ever scales the API past one instance, every ActionCable broadcast
   silently reaches only the subscribers on the broadcasting instance. This
   already affects `ImportProgressChannel` and `ActivityReminderService`.
2. ❌ v2's "Sidekiq queue per company (existing pattern)" — **the app does not
   run Sidekiq.** `config/sidekiq.yml` is a leftover; the ActiveJob adapter is
   `solid_queue` (prod/staging) and `:async` (dev). There is no per-company
   queue pattern to copy.

**Broadcast convention to follow:** `ActionCable.server.broadcast("stream_name", payload)`
— see `activity_notification_service.rb:145`, `inbound_email/reply_notifier.rb:177`,
`import_export/importer.rb:532`.

---

### 9. ❌❌ **THE MISSING PIECE: campaign engagement does not reach the workflow engine**

This is the finding that matters most, and v2 doesn't mention it at all.

`WorkflowEngine.emit` is called from exactly these places (grep across `app/`
and `lib/`): `Lead`, `Contact`, `Account`, `Deal`, `ServiceTicket` (created /
updated / status_changed / deleted), `TagAssignment`,
`EmitsWorkflowActivityEvents` (the four `*_activity.*` events), and
`VehicleDaysOnLotCheckJob`.

The catalog confirms it (`app/services/workflows/ai_builder.rb:16-27`):
```
lead.* deal.* contact.* account.* service_ticket.*
lead_activity.* deal_activity.* contact_activity.* account_activity.*
inbound.webhook cron.minutely cron.hourly cron.daily cron.weekly
```

**No `campaign.opened`, `campaign.clicked`, `campaign.replied`,
`campaign.bounced`, `campaign.unsubscribed`.**

`CampaignTrackingController#click` and `Public::TrackedLinksController#show`
write `CampaignLinkToken`, `CampaignSend`, `CommunicationEvent` and a
`CampaignEvent` — but **never call `WorkflowEngine.emit`**. Same for
`Campaigns::ReplyHandler` and `Campaigns::BounceHandler`.

**Consequence:** the entire demo diagram — "OPENED → day-2 follow-up",
"CLICKED → workqueue task → on-call rep", "NOT OPENED after 3 days → resend" —
**cannot fire.** The workflow engine has no way to know a campaign email was
opened or clicked.

The only campaign-side reaction that exists is `Campaigns::GoalChecker`
(`app/services/campaigns/goal_checker.rb`), which marks `goal_met_at` on an
enrollment for `opened | clicked | replied | form_submitted | deal_created |
deal_stage_advanced | unit_sold`, with a `track`/`stop` action. That stops or
tracks — it cannot branch into arbitrary follow-up actions.

**This bridge is the single highest-leverage thing to build,** and it's small:
emit from the 4 existing tracking call sites, resolving the entity from
`campaign_enrollment.recipient` (already `Lead`/`Contact`/`Account` — the same
entity types `WorkflowRule.entity_type` accepts), add the event types to the
trigger catalog + AI builder prompt. **~2 days.** Everything downstream (branch,
wait, create_activity, add_tag, enroll_in_nurture, canvas, run history) is
already there.

---

### 10. "Landing page on dealer site — §2 Public routes (`/c/:token`)" ❌ path is taken

`src/App.tsx:276`:
```tsx
<Route path="/c/:token" element={<PublicConfiguratorView />} />
```
`/c/:token` is the public configurator. Backend counterpart:
`GET /api/public/configurations/:token` (`config/routes.rb:135`).

Also already taken: `/q/` quotes, `/w/` warranty, `/u/` unsubscribe, `/r/`
referral + SMS reply, `/t/` tracked links, `/f/` intake forms, `/b/` brochures,
`/l/` listings, `/s/` site preview, `/sign/`, `/pay/`, `/project/`, `/cl/`,
`/build/`. Pick an unused prefix (`/lp/` is free).

**And you probably shouldn't build a new landing-page model at all.** There is a
full website builder: `Website` (subdomain, custom domain, slug, theme,
`preview_token`, versioning), `WebsitePage` (path, parent/child, visibility,
nav/footer flags), `WebsiteMedia`, `WebsiteVersion`, `BlogPost`, plus
`CloudflareSaasService` for custom domains and `src/modules/website-builder` on
the FE. A campaign landing page is most naturally a `WebsitePage` on the dealer's
existing `Website` — which also kills the v2 item *"Custom domain for landing
pages — dealer wants promo.dealername.com"*, because `Website#domain` +
`CloudflareSaasService` already do that.

---

### 11. Compliance — mostly ✅ already built, two corrections

| v2 item | Reality |
|---|---|
| CAN-SPAM footer auto-appended | ✅ `CampaignStep#ensure_footer_unsubscribe` (`before_save`, injects a `footer_unsubscribe` block unless the step is raw HTML). Renderer: `Messaging::UnsubscribeFooter`. |
| Unsubscribe center at `/u/:token` | ✅ **already live.** `routes.rb:2119-2120` → `CampaignTrackingController#unsubscribe_show` / `#unsubscribe_confirm`; FE `src/modules/email-campaigns/public/PublicUnsubscribePage.tsx`; token signed via `message_verifier(:campaign_unsubscribe)`. ⚠️ It is **campaign-scoped only** — no granular "marketing vs transactional" preference centre yet. |
| TCPA STOP | ✅ `CampaignStep#ensure_sms_stop_footer` appends "Reply STOP to unsubscribe" (and errors if it won't fit in 1600 chars). `webhooks/twilio_controller.rb:136` handles STOP/START. `Campaigns::SmsInboundHandler` + `CampaignEvent` types `sms_stop|sms_help|sms_start`. |
| Suppression list | ✅ `CampaignSuppression` — reasons `unsubscribe\|bounce_hard\|complaint\|manual\|sms_stop`, email **or** phone (normalised to E.164), `.suppressed?(company_id, value)`, enforced in `CampaignSender#suppressed?`. |
| ❌ "Cross-company suppression on hard bounces" | **Does not exist and cannot without a schema change** — `validates :email_address, uniqueness: { scope: :company_id }` and every lookup is company-scoped. Deliberate tenant isolation. If you want it, it's a new platform-level table, not a tweak. |
| ❌ "`Consent` model with timestamp + IP + form ID" | **No `Consent` model — but `CommunicationPreference` is exactly this** and already exists: polymorphic `recipient`, `channel`, `category` (`marketing\|transactional\|quotes\|invoices\|notifications`), `opted_in`, `opted_in_at`, `opted_out_at`, `unsubscribe_token`, `ip_address`, `user_agent`, `compliance_metadata`. Use it. Separately, campaign SMS audience filtering reads the boolean columns `Lead#opt_in_sms` / `Contact#sms_opt_in` with an explicit override flag (`CampaignAudience#scope_for_sms_compliance`, `sms_compliance_override?`). The gap is **double-opt-in capture on web forms**, not the storage model. |
| 7-year audit log | ⚠️ Partial. `CampaignEvent`, `CampaignSend`, `CommunicationEvent`, `ActivityLog`, `WorkflowRunStep` all persist. But `WorkflowRetentionJob` exists and prunes — check its window before promising 7 years. No retention policy is defined for campaign tables. |

---

### 12. Rate limiting / retry — ❌ mostly wrong

- ❌ "Sidekiq queue per company (existing pattern)" — **no Sidekiq** (see §8).
  No per-company queue exists.
- ❌ "max 200 emails/minute" — there is no per-minute limiter. What exists is
  `Campaign#throttle_per_day` (default 500) enforced by
  `Messaging::ThrottleChecker` as a rolling 24-hour count of `CampaignSend`s,
  plus `SmsCapService.check!` for SMS. Per-minute pacing is genuinely new.
- ✅ Send windows: `Messaging::SendWindowCalculator` + `campaigns.send_window` JSONB.
- ❌ `CampaignSendError` doesn't exist. Failures are recorded on `CampaignSend`,
  `CampaignEnrollment.status = 'failed'`, and `CampaignEvent(event_type: 'failed')`.
  `CampaignSender` already classifies hard vs soft bounces
  (`#handle_hard_email_bounce`, `#handle_hard_sms_bounce`, `#handle_soft_bounce`,
  `#reschedule_to`). A dead-letter table is a reasonable add, but it's an
  addition to a working retry path, not the retry path itself.

---

### 13. Analytics / attribution — ✅ per-campaign exists, ❌ pipeline attribution doesn't

**Exists:** `CampaignStatsRollupJob` (writes `campaigns.stats_cache`:
sent/delivered/opened/clicked/replied/bounced/unsubscribed/goals_met/failed,
excluding test sends via the `.real` scopes), `Campaigns::AnalyticsTimeseries`,
`Campaigns::EngagementBreakdown`, `Campaigns::RecipientEngagement`. Endpoints:
`GET /api/v1/campaigns/:id/{stats,analytics_timeseries,engagement,engagement/by_step,engagement/by_link}`.
FE: `TimeseriesChart.tsx`, `LinkBreakdownPanel.tsx`, `StepBreakdownPanel.tsx`.

**UTM:** `campaigns.utm_source/utm_medium/utm_campaign` and
`social_posts.utm_campaign/utm_content` columns exist.

**❌ Missing:** no `campaign_analytics_daily`, no 30/60/90-day click→deal
attribution window, no dollar rollup. `GoalChecker` has `deal_created` /
`deal_stage_advanced` / `unit_sold` as *per-enrollment booleans* since enrollment
creation — not a windowed, revenue-weighted attribution model. This is real new
work (~3 days), and per your `unified-gp-source-of-truth` note it must consume
`Deal#front_gross` rather than recomputing GP, and gate cost columns on
`deals:read:view_cost_details`.

⚠️ **Latent bug worth knowing before you add a third link type:** `/t/:token` has
two claimants. `config/routes.rb:17` registers `t/:token` →
`Public::TrackedLinksController#show`, and `routes.rb:2118` registers `/t/:token`
→ `CampaignTrackingController#click`. First wins, so **`CampaignTrackingController#click`
is dead code.** `TrackedLinksController#show` compensates by explicitly falling
through to `CampaignLinkToken` (with a comment saying so). It works, but any new
tokenised link scheme must go through `TrackedLinksController`, not a new route.

---

### 14. Entity model — ❌ collides with the shipped one

`Campaign` already exists with a different shape (`db/schema.rb:1373-1411`):
`channel` (`email|sms`), `campaign_type` (`blast|drip|triggered|recurring_digest`),
`from_identity_type` (`User|Location|Company|Owner` — polymorphic, `Owner`
resolves per-recipient at send time), `goal_config`, `reply_handling`,
`send_window`, `throttle_per_day`, `utm_*`, `recurrence_cron`, `trigger_config`,
`stats_cache`, `seeded_from_template_id`, `generated_from_ai_generation_id`.

Children: `CampaignStep` (position, wait_days/hours, per-step `channel` for
mixed-channel drips, `body_blocks` JSONB, `sms_body`, `inventory_block_config`,
`attachments`), `CampaignAudience` (multi-source-type tag filters + saved
`Audience`), `CampaignEnrollment`, `CampaignSend`, `CampaignEvent`,
`CampaignLinkToken`, `CampaignSuppression`, `CampaignTemplate`,
`CampaignAiGeneration`.

**Deltas the pitch actually needs:**
- `campaigns.channel` is `email|sms` only — no `landing_page` or `social_post`.
  Either widen it or (better) link campaigns to `SocialPost` / `WebsitePage`
  rather than inventing `CampaignAsset`.
- No `prompt` column on `Campaign` — the prompt lives on
  `CampaignAiGeneration.prompt`, linked via `generated_from_ai_generation_id`.
  That's fine; just don't duplicate it.
- No `campaign ↔ workflow_rule` linkage. **Add one FK.** That plus §9 is the
  whole integration.
- ✅ `company_id` immutable, `location_id` present, tenant-scoped — matches
  CLAUDE.md §16/§9.

---

### 15. AI generation — ❌ "Week 2" is already shipped

`app/services/campaigns/ai_builder.rb`: `#generate(prompt:, channel:,
context_overrides:, attachment_context:)` and `#refine(generation:, feedback:)`,
Claude Messages API, model ids from `AiModel.for(:generation)` / `:refine`,
monthly credit limiting (`CreditLimitError`, default 50), multimodal — it
partitions uploads into images (real image content blocks) vs docs, logs to
`AiQueryLog`, and persists a `CampaignAiGeneration` audit row with token counts.

Routes already live: `POST /api/v1/campaigns/ai_generate`,
`ai_generate/:generation_id/accept`, `/refine`, `GET .../preview_render`.
FE: `src/modules/email-campaigns/components/AiBuilderModal.tsx`,
`AiAudienceBuilderModal.tsx`.

Siblings: `Workflows::AiBuilder`, `SocialPostGeneratorService`,
`Api::Crm::Nurture::AiSequencesController` + `AiTemplatesController`,
`AiDraftService`, `ReportAiService`, `AudienceAiGeneration`.

Remaining AI work: one orchestration layer that fans a single prompt out to
campaign + workflow + social + landing page and returns them together.

---

### 16. Frontend structure — ❌ would be a third campaign module

Existing: `src/modules/email-campaigns` (`CampaignsList`, `CampaignBuilder`,
`CampaignDetail`, `CampaignSuppressionsList`, `CampaignTemplateGallery`,
`AudiencesList`, `AudienceDetail`, `TestSendDialog`, `AiBuilderModal`,
`ChannelStepEditor`, `BlockComposer`, `GoalsEditor`, `RecurrenceEditor`,
`FromIdentityPicker`, `SmsComplianceAcknowledgmentModal`, `TimeseriesChart`,
`LinkBreakdownPanel`, `StepBreakdownPanel`, `AudienceConditionTree`,
`CampaignPreviewDrawer`, `public/PublicUnsubscribePage`), plus
`workflow-automation`, `social-media`, `website-builder`, `workqueue`,
`calendar-scheduling`.

v2's `TestSendModal`, `AudienceSelector`, `ComplianceBanner`, `AnalyticsTab`,
`CampaignsList`, `EmailEditor`, `SmsEditor` all have direct existing equivalents.

**§2 pattern check:**
- ✅ `App.tsx` public-route pattern — real, 30+ token routes.
- ✅ `useBranding.ts` — `src/hooks/useBranding.ts`, exports a `BrandKernel`
  (`name`, `shortName`, `supportEmail`, `salesEmail`, `fromEmail`, `fromName`,
  `websiteUrl`, `appUrl`, `privacyUrl`, `termsUrl`, `subdomainRoot`, `logoUrl`)
  that mirrors `Brand.current` server-side. Matches the CLAUDE.md brand kernel —
  no hardcoded platform strings in new campaign copy.
- ❌ **there is no single `api.ts`.** Four candidates coexist: `src/utils/api.ts`,
  `src/config/api.ts`, `src/utils/apiClient.ts`, `src/services/apiClient.ts`.
  Match whatever `src/modules/email-campaigns` already imports rather than
  picking one.

Also mobile: per your standing preference, the react-flow canvas needs a
mobile-usable mode from the first commit — a horizontally-scrolling graph is
exactly the failure mode to avoid.

---

### 17. "Automated appointment link sending" ✅ **already built — better than my first pass credited**

> **Decision (2026-07-27): no first-party appointment product.** Use the user's
> existing Booking / Scheduling Link from account settings.

**That decision means this line item is essentially already done.**
`User#booking_url` (`db/schema.rb:6693`) is not just a stored string — it is
already threaded through the entire content pipeline:

| Layer | Reference |
|---|---|
| Edited in user account settings | `api/v1/user_settings_controller.rb:25,34,68` (`booking_url` in the profile permit list) |
| Campaign AI generation context | `campaigns/ai_builder.rb:346` — plus explicit prompt guidance at `:367-369` and `:507` telling the model to render it as a `{ type: "button", text: "Book a time", href: booking_url }` block for email and raw-URL-with-framing for SMS, and *not* to shove it into every step |
| Workflow AI generation context | `workflows/ai_builder.rb:187`, guidance at `:378` for both `send_email` and `send_sms` steps |
| Nurture AI generation context | `api/crm/nurture/ai_sequences_controller.rb:244,266-272`; `ai_templates_controller.rb:181,203-205` |
| Runtime merge tag | `Messaging::MergeTagResolver.build_context` exposes **`{{rep_booking_link}}`** (`merge_tag_resolver.rb:26`, `rep&.try(:booking_url)`) |
| Rendered CTA block | `Messaging::BlockRenderer:71-98` — renders a "Schedule a tour →" anchor in the rep signature block when `booking_url` is present, falls back gracefully when absent |

So "workflow node triggers *send appointment link*" needs **no new node type**.
An AI-generated `send_email` / `send_sms` step already emits the booking CTA, and
a hand-authored campaign step can drop `{{rep_booking_link}}` into any body.

**The one real gap** is *whose* link gets sent, and it differs by engine:
- **Campaign steps** resolve `{{rep_booking_link}}` at send time from the
  `rep` in the merge context → correct per-send, and correct for `Owner`-mode
  campaigns where the sender is the recipient's own owner.
- **Workflow steps** get the URL **baked into the step body at generation time**,
  from `@user` (the rule author) — `workflows/ai_builder.rb:187`. A rule authored
  by one rep will send that rep's link to everyone.

Fixing that means adding `owner_booking_url` to
`WorkflowEngine#entity_as_hash_with_denormalized` (which already denormalizes
`owner_email` / `owner_phone` / `owner_name` the same way) so workflow templates
can use `{{entity.owner_booking_url}}` and resolve per-recipient at run time.
**~0.5 day, and only needed if a workflow will be shared across reps.**

For completeness, on the thing we're explicitly *not* building — there is no
`Appointment` model, booking flow, availability model, or self-scheduling
endpoint. A repo-wide grep for `appointment` returns only:
- `next_appointment` as a *custom field* on Evangeline's leads (handled by
  `WorkflowEngine::CustomFieldsAccess`)
- `'appointment'` as a nurture/AI template category string
- `operational_settings.require_appointment` — a boolean setting
- `ai_action_executor.rb:341` mapping the word "appointment" → `activity_type: 'meeting'`

Booked meetings are still tracked, just not self-served: `activity_type:
'meeting'` on `LeadActivity`/`ContactActivity`/etc. with `start_time` /
`end_time`, surfaced by `activity_meetings_today` / `activity_meetings_upcoming`
and `CalendarService`. When a prospect books through the rep's external link, the
meeting lands in that rep's own calendar tool — it does **not** flow back into
the DMS as an activity. That's the accepted trade-off of the booking-link
approach; if the workqueue needs to show those meetings later, a calendar
write-back is a separate future item, not part of this build.

---

### 18. Subscription gating — ⚠️ machinery is built, **the marketing modules aren't wired to it**

> **Requirement (2026-07-27):** the new tool must be sellable as an add-on —
> turn on / turn off per tenant.

**What's fully built (all of it reusable, nothing to design):**
- `PlatformModule::MODULES` registry (49 keys) + `CATEGORIES` + `PLAN_TEMPLATES`
  (starter / professional / enterprise) — `app/models/platform_module.rb`
- `ModuleAccessService` — `has_module?(key)` resolving **override → plan →
  legacy tier**, `module_configs` (plan config merged with per-tenant override),
  `set_override!` / `remove_override!`, `subscription_status` with trial + grace
  period + seat/location limits
- `TenantSubscription`, `SubscriptionPlan`, `SubscriptionPlanModule` (with a
  per-module `config` JSONB), `TenantModuleOverride` (per-tenant on/off with
  `override_reason` + `overridden_by`)
- `Company#has_module?` → delegates to `module_access`
- Platform Admin UI: `TenantSubscriptionTab.tsx`, `TenantModuleAccessCard.tsx`
- FE hook `useModuleAccess()` + `MODULE_KEYS`, and `<ModuleGate>`

**The gap — an "off" switch that doesn't turn anything off:**

`marketing.campaigns` and `marketing.social_media` exist in the registry and in
the professional/enterprise plan templates, and the sidebar honours them
(`Sidebar.tsx:139-140` attach `moduleKey`, filtered at `:335`). But:

- ❌ **Zero backend enforcement across the entire marketing surface.** None of
  `campaigns`, `campaign_audiences`, `campaign_steps`, `campaign_enrollments`,
  `campaign_sends`, `campaign_events`, `campaign_suppressions`,
  `campaign_templates`, `campaign_uploads`, `audiences`, `social_posts`,
  `websites`, or `ad_campaigns` controllers call `require_module!`. They gate on
  RBAC only (`authorize_action!('campaigns', 'read')`), which is a *who*, not a
  *what's purchased*.
- ❌ **No FE route gating.** `App.tsx:414` `/campaigns/*` and `:460-477`
  `/marketing/social-media/*` render unconditionally. Hiding the nav item does
  not stop a bookmark or a typed URL.
- ❌ **`<ModuleGate>` is dead code** — it appears nowhere in `src/` except its
  own docstring.

**Net effect today: flipping `marketing.campaigns` off hides one menu item and
leaves the whole API open.** That's not a sellable add-on boundary.

By contrast, `management.workflows` **is** properly enforced — all eight workflow
controllers (`workflow_rules`, `workflow_runs`, `workflow_events`,
`workflow_metrics`, `workflow_templates`, `workflow_approvals`,
`workflow_inbound_triggers`, `workflow_field_options`) declare
`require_module! 'management.workflows'`. Copy that pattern exactly.

⚠️ **Pick one concern first.** There are three overlapping implementations of the
same idea and they behave differently:

| Concern | Platform-admin bypass | Notes |
|---|---|---|
| `ModuleAccessRequired` | `platform_admin \|\| super_admin \|\| tenant?` | What the workflow controllers use. **Recommend standardising on this.** |
| `FeatureGating` | `platform_admin` only | Richest — also has `require_active_subscription!` returning **402**, useful for dunning |
| `ModuleGating` | **none** — would lock out platform admins | Also has `require_any_module!` |

`ModuleGating` having no admin bypass is a live footgun: gate a controller with
it and platform admins lose access to their own tenants. Consolidate rather than
adding a fourth.

**Work required:**

| # | Item | Est. |
|---|---|---|
| A | Add the new module key to `PlatformModule::MODULES` + `PLAN_TEMPLATES` (see §19 for the name). Because it's a **paid add-on**, put it in *no* plan template — sell it purely via `TenantModuleOverride`, or add a dedicated add-on plan. | 0.5d |
| B | `require_module!` on the new tool's controllers, using `ModuleAccessRequired`. | 0.5d |
| C | **Backfill `require_module! 'marketing.campaigns'` / `'marketing.social_media'` on the 13 ungated controllers above.** Without this, a dealer who doesn't buy the add-on can still hit every campaign endpoint. | 1d |
| D | FE route gating — wrap `/campaigns/*`, `/marketing/social-media/*`, and the new tool's routes in `<ModuleGate fallback="upgrade">` (the component already exists and is unused). | 0.5d |
| E | Starter/Pro **tier** differentiation inside the add-on (send limits, dedicated domain, multi-campaign rollup) via `SubscriptionPlanModule#config` — the mechanism already exists; `marketing.website` uses it for `website_access_level`. | 1d |
| F | Consolidate the three gating concerns onto `ModuleAccessRequired`; delete or alias the other two. | 0.5d |

⚠️ **Item C is a pre-existing revenue leak, not new work caused by this project** —
`marketing.campaigns` has been sellable-on-paper and unenforced. Worth fixing
regardless of whether the add-on ships.

#### ⛔ Blast radius — the plan-module data must be fixed BEFORE gating

Checked against production (2026-07-27). **A naive backfill would break live
tenants**, because `ModuleAccessService#has_module?` resolves a *missing* row as
`false` (`exists?(module_key:, is_enabled: true)`), not as "inherit".

`subscription_plan_modules` today:

| Plan | `marketing.campaigns` | `marketing.social_media` | `management.workflows` |
|---|---|---|---|
| enterprise | ✅ `t` | ❌ **`f`** | ✅ `t` |
| professional | ⛔ **no row** | ✅ `t` | ❌ `f` |
| demo_plan | ⛔ **no row** | ⛔ no row | ✅ `t` |
| starter | ⛔ no row | ❌ `f` | ❌ `f` |

`tenant_module_overrides`: **0 rows.** Nothing is being granted by exception.

Tenants with real campaign data, cross-referenced against their plan:

| Company | Plan | Campaigns | Effect of gating |
|---|---|---|---|
| 4 — Factory Direct Homes Center | enterprise | 3 | ✅ safe |
| 12 — Heartland Homes | enterprise | 1 | ✅ safe |
| 14 — DealerTide App | enterprise | 18 (latest today) | ✅ safe |
| 15 — Evangeline Home Center DEMO | enterprise | 1 | ✅ safe |
| 17 — Evangeline Home Center | enterprise | 2 | ✅ safe |
| **16 — Pete Test Account** | **professional** | **1** | ⛔ **loses campaign access** |

Plus **company 2 (Summit Park) and 13 (Breakthrough) are on `demo_plan`, which
has no `marketing.campaigns` row** — Summit Park is the primary demo tenant, so
gating without a data fix would break demos.

**`marketing.social_media` — mostly as intended, two gaps.** The intent is
*off everywhere except DealerTide's own tenant* until Meta approval lands.
`enterprise = f` and `starter = f` already implement that. Remaining gaps:

- ⛔ **`professional` is still `t`** — companies 9 (Sunshine Demo), 11 (Heartland
  Demo), 16 (Pete Test). All demo/test; none has a single social post or a
  `FacebookIntegration`, so nothing breaks by flipping it to `f`.
- ⛔ **DealerTide (company 14) currently has it OFF, which is backwards.** It sits
  on the shared `enterprise` plan alongside 10 real customers, so it **cannot be
  granted via the plan** — it needs a `TenantModuleOverride` on company 14. Its
  Social Media nav item is hidden today as a result.

Reassuring context: company 14 is the **only** tenant with any social posts (38,
5 published, latest today) and the **only** `FacebookIntegration` row. Since
`PublishSocialPostJob` hard-requires an active per-company `FacebookIntegration`
(marking the post failed with `no_integration` otherwise), **no other dealer
could have published to Meta regardless of the module flag.** The pre-approval
exposure was never real — the flag is belt-and-braces.

**Required sequence — do not reorder:**

1. **Data fixes** (Platform Admin UI — plan builder + tenant override card):

   | # | Change | Where | Blast radius |
   |---|---|---|---|
   | 1a | `marketing.social_media` → **`f`** on `professional` | Plan builder | Companies 9, 11, 16 — zero social posts, zero FB integrations. Safe. |
   | 1b | `marketing.social_media` → **`true` override on company 14 (DealerTide App)** | Tenant module override — **not** the plan; 14 shares `enterprise` with 10 real customers | Restores DealerTide's own Social Media nav. This is the piece a plan edit cannot do. |
   | 1c | `marketing.campaigns` → **`t`** on both `professional` and `demo_plan` | Plan builder | ✅ **Decided 2026-07-27: enabled on both**, still individually toggleable per tenant. Preserves access for company 16 (1 campaign) and for Summit Park (2) / Breakthrough (13) on `demo_plan`. |

2. Re-run the cross-reference above; confirm zero tenants with existing
   campaign/social data would be denied.
3. *Then* add `require_module!` to the controllers.
4. Ship behind a brief window where the denial path logs instead of 403s, so a
   miss surfaces before a dealer hits it.

Because `marketing.automation` (Campaign Desk) is **new**, it has no legacy users
and none of this applies — it can be gated from its first commit, sold purely by
tenant override. ✅ Registered in `platform_module.rb` with no `PLAN_TEMPLATE`
membership, exactly so it can't be inherited by landing on a plan.

---

### 19. Naming — ✅ **DECIDED: Campaign Desk**

> **Decision (2026-07-27): `Campaign Desk`.** Module key `marketing.automation`.
> Display name lives in the registry so a future rename is a data change.

Why it fits:
- It mirrors **Deal Desk** (`sales.deal_desk`), which is already in the product
  and already reads well to dealers. The house style is two-word concrete nouns:
  Deal Desk, Agreement Vault, Commission Engine, Tagging Engine, Lot Map,
  Website Builder. "Campaign Desk" drops straight into that list.
- "Desk" correctly implies *the place the work gets orchestrated* — which is
  exactly what this is. It sits **above** Email Campaigns, Social Media, and
  Workflow Automation rather than competing with them, and the name signals that
  hierarchy without claiming to replace them.
- A dealer principal reads it once and knows what it is. That matters more than
  cleverness on a $299–449/location line item.

**Strong alternative if you want the name to carry the pitch: `Groundswell`.**
A groundswell is a wave built by distant force that arrives all at once — which
is both the product's promise and a natural fit with **DealerTide**. It's
distinctive and ownable in a category full of "Marketing Hub" / "Campaign
Studio." The trade-off is that it needs a tagline to land ("Groundswell — one
prompt, the whole campaign"), whereas Campaign Desk needs none.

Runners-up: **Launch Desk** (leans on the verb dealers actually use — "launch a
campaign"); **Marketing Engine** (mirrors Commission Engine; clear but generic).

Two to avoid:
- ❌ **Current** — collides with `app/models/current.rb`, the `Current` request
  context used throughout this codebase. Internal naming would be miserable.
- ❌ **Autopilot** — already a martech product name; also oversells, since the
  whole differentiator is that the dealer *reviews the diagram before* publish.

**Keep the module key functional and stable** (`marketing.automation`), and let
the display name live in `PlatformModule::MODULES[...][:name]`. Same principle as
the brand kernel in CLAUDE.md — renaming the product should be a data change, not
a code sweep. Suggested registry entry:

```ruby
'marketing.automation' => {
  name: 'Campaign Desk',
  category: 'Marketing',
  icon: 'Wand2',
  description: 'One prompt to a full multi-channel campaign — email, SMS, social, landing page, and the follow-up workflow, drawn before you publish'
},
```

---

### 20. Module dependencies — what happens when Starter buys Campaign Desk

**The concern is real and one dependency is already broken in production.**
Campaign Desk drives four engines that are (or will be) separately gated:

| Campaign Desk needs | Module | Gated today? |
|---|---|---|
| Create/send campaigns, steps, audiences | `marketing.campaigns` | ❌ not enforced (§18) |
| Create the branching follow-up + canvas | `management.workflows` | ✅ **enforced on all 8 workflow controllers** |
| Generate + publish social posts | `marketing.social_media` | ❌ not enforced |
| Landing page as a `WebsitePage` (§10) | `marketing.website` | ❌ not enforced |

`PLAN_TEMPLATES[:starter]` contains **no marketing modules and no
`management.workflows`**. So a Starter tenant sold Campaign Desk today would get
**403s on every workflow endpoint** — the workflow canvas, the follow-up graph,
the run history. That's the headline feature, dead on arrival.

#### Recommendation: neither "require all" nor "cascade on" — grant *capability*, not *product*

Both options in the question have a real cost:

- **Hard prerequisite** ("must own all four first") makes the add-on unsellable
  to Starter, which kills the $299 on-ramp the pricing strategy depends on. The
  sales motion becomes "buy four things to buy one thing."
- **Cascade-on** ("enabling Campaign Desk enables the rest") silently hands a
  Starter customer the *entire standalone* Email Campaigns builder, Workflow
  Automation canvas, Social Media dashboard, and Website Builder — four products
  given away with a $299 add-on. Worse, it's **not cleanly reversible**:
  `TenantModuleOverride` has no notion of *why* a module was granted, so on
  cancellation nothing can tell whether Website Builder was owned outright or
  inherited from Campaign Desk. You'd be guessing at churn time.

**The distinction that resolves it: a module is a _navigable product surface_,
not an engine.** Campaign Desk should authorize the engines it drives without
granting the standalone surfaces.

Concretely — Campaign Desk is self-contained by design (§ the Review page has its
own asset tabs and its own workflow diagram; it never sends the user into the
Email Campaigns module). So:

1. **Campaign Desk's own controllers** require `marketing.automation` only.
2. **Shared engine controllers accept either key.** The workflow controllers
   become `require_any_module!('management.workflows', 'marketing.automation')`.
   Owning `management.workflows` additionally gets you the standalone canvas and
   its nav item; owning Campaign Desk gets you the engine, surfaced inside
   Campaign Desk.
3. **Nav items stay gated on the standalone key**, so a Starter + Campaign Desk
   tenant sees *Campaign Desk* in the sidebar — not Email Campaigns, Workflow
   Automation, Social Media, and Website Builder.

`require_any_module!` **already exists**, in `ModuleGating`
(`module_gating.rb:52-64`) — but that's the concern with **no platform-admin
bypass** (§18). Port it onto `ModuleAccessRequired` as part of the consolidation
in §18-F rather than adopting `ModuleGating`.

#### Plus: declare dependencies as data, so the UI can warn

Add a `requires:` key to the registry entry — declarative, no behaviour change:

```ruby
'marketing.automation' => {
  name: 'Campaign Desk', category: 'Marketing', icon: 'Wand2',
  requires: %w[marketing.campaigns management.workflows],
  optional: %w[marketing.social_media marketing.website],
  description: '...'
},
```

Then the Platform Admin override card and plan builder surface:
*"Campaign Desk needs Email Campaigns and Workflow Automation. Social posting
and landing pages need Social Media and Website Builder — without them, Campaign
Desk generates the copy but can't publish."* Offer a one-click "enable these
too", but **let the operator choose** — never auto-enable silently, so
provenance stays legible.

`requires` vs `optional` matters: without `marketing.social_media` Campaign Desk
should still work and simply skip the social asset, rather than erroring. Same
for landing pages. Only campaigns + workflows are hard requirements.

**Work:** `requires`/`optional` metadata + `require_any_module!` on
`ModuleAccessRequired` + the 8 workflow controllers + the admin UI warning.
**~1.5d**, folded into item #20 below.

---

## Missing primitives — what genuinely needs building

**Tier 1 — load-bearing for the demo, doesn't exist at all**

| # | Primitive | Why it's required | Est. |
|---|---|---|---|
| 1 | **Campaign → workflow event bridge.** Emit `campaign.opened/clicked/replied/bounced/unsubscribed` from `Public::TrackedLinksController#show`, `Messaging::PixelInjector`'s open path, `Campaigns::ReplyHandler`, `Campaigns::BounceHandler`; resolve entity from `campaign_enrollment.recipient`; add to `Workflows::AiBuilder::TRIGGER_EVENT_TYPES`. | §9 — without it **no branch in the demo diagram can fire.** | 2d |
| 2 | **`campaign_id` ⇄ `workflow_rule_id` linkage** + campaign-scoped run queries. | Ties the two engines; makes "this campaign's workflow" addressable. | 0.5d |
| 3 | **Live-metrics rollup + read-only canvas mode.** `GROUP BY step_id, status` over `WorkflowRunStep`, overlaid on the existing `WorkflowCanvas`. | The "watch it breathe" view. Data already exists; presentation doesn't. | 2d |
| 4 | **Per-minute send pacing.** Existing throttle is per-day only. | Deliverability + SES/Twilio rate limits. | 1d |
| 5 | **Windowed pipeline attribution** (`campaign_analytics_daily`, click→lead→deal within N days, $ from `Deal#front_gross`). | The "$47k attributed" number in the pitch. | 3d |
| 6 | **SES bulk-send mode for campaigns** + campaign-path bounce/complaint SNS. | Today campaigns can only bulk-send through owners' OAuth mailboxes (§1). | 2d |

**Tier 2 — underestimated as "reuse", small but real**

| # | Primitive | Est. |
|---|---|---|
| 7 | `CreateActivity` executor accepting a `RoundRobinAssignmentList` for "on-call rep" assignment (§5). | 0.5d |
| 8 | `notify_user` workflow executor wrapping `NotificationService` + ActionCable (§5). | 0.5d |
| 9 | ~~`send_booking_link` node~~ — **already built** (§17). Only `owner_booking_url` in the workflow entity hash, and only if workflows are shared across reps. | 0.5d *(optional)* |
| 10 | Landing page as a `WebsitePage` + a free public route prefix (**not `/c/`**) + campaign linkage (§10). | 1.5d |
| 11 | Double-opt-in capture writing `CommunicationPreference` w/ IP + user agent + form id (§11). | 1d |
| 12 | Granular preference centre on the existing `/u/:token` page (marketing vs transactional). | 1d |
| 13 | Single-prompt orchestrator fanning out to campaign + workflow + social + landing page (§15). | 2d |
| 14 | `GenerationProgress` ActionCable channel (no collision, but confirm the single-instance constraint in §8). | 0.5d |
| 20 | **Subscription gating for the add-on** — new module key, `require_module!` on its controllers, FE route gate, tier config via `SubscriptionPlanModule#config` (§18 A/B/D/E), **plus module-dependency handling: `requires`/`optional` metadata, `require_any_module!`, admin warning (§20)**. | 4d |
| 21 | **Backfill module gating on the 13 ungated marketing controllers** + consolidate the three gating concerns (§18 C/F). Pre-existing revenue leak. | 1.5d |

**Tier 3 — cut / deferred (decided)**

| # | Primitive | Status |
|---|---|---|
| 15 | **LinkedIn publishing** — zero code exists (§7). | ❌ **Cut.** Demo says FB + IG. Note MS approval does not carry over. |
| 16 | **First-party appointment booking** (§17). | ❌ **Cut.** Using `User#booking_url`, which is already wired end-to-end. |
| 17 | **Cross-company hard-bounce suppression** (§11). New platform-level table; breaks the current per-company isolation model. | Defer. |
| 18 | `CampaignSendError` dead-letter table (§12). | Nice-to-have on top of a working retry path. |
| 19 | Calendar write-back of externally-booked meetings into `activity_type: 'meeting'` (§17). | Defer — consequence of the booking-link decision. |

**Tier 0 — ops, not code (unblocks Twilio + email)**

| Item | Where |
|---|---|
| Set `TWILIO_MESSAGING_SERVICE_SID` (or Platform Settings → Communications → SMS) so provisioned numbers join the approved A2P sender pool | §2 |
| Verify `API_BASE_URL` is set in **production** before provisioning any customer number, or inbound SMS routes to staging | §2 |
| Finish Microsoft app approval → unblocks Outlook/Graph campaign sending (§1), **not** LinkedIn (§7) | §1, §7 |

**Explicitly delete from the v2 plan** (duplicates shipped code):
`CampaignWorkflow`, `CampaignWorkflowEvent`, `WorkflowExecutorJob`,
`CampaignAsset`, `src/modules/marketing-campaigns/`, "Twilio subaccount per
company", "per-company 10DLC brand registration", "Sidekiq per-company queue",
"build unsubscribe center at /u/:token", "build suppression list", "Claude API
integration / prompt parser", "email + SMS asset generators", most of week 3's
canvas work.

---

## Revised timeline

v2 said 4–5 weeks. With the audit, **~2.5 weeks** — and the shape changes
completely: it's integration work, not greenfield.

**Week 1 — the bridge (this is the whole product)**
| Day | Work |
|---|---|
| 0 | *(ops, parallel)* Tier 0: Messaging Service SID, prod `API_BASE_URL`, then begin customer number provisioning |
| 1–2 | Campaign→workflow event bridge (#1) + trigger catalog + AI builder prompt update |
| 3 | Campaign⇄workflow linkage (#2), round-robin assignee (#7), `notify_user` (#8), Twilio missing-SID warning (§2) |
| 4–5 | Live-metrics rollup + read-only canvas overlay (#3) |

**Week 2 — sending + attribution**
| Day | Work |
|---|---|
| 6–7 | SES bulk mode + campaign SNS bounce/complaint (#6) |
| 8 | Per-minute pacing (#4) |
| 9–10 | Windowed pipeline attribution (#5) |

**Week 3 — surface + packaging + launch**
| Day | Work |
|---|---|
| 11–12 | Single-prompt orchestrator (#13) + generation progress channel (#14) |
| 13 | Landing page as `WebsitePage` (#10) |
| 14 | Subscription gating (#20) + backfill the ungated marketing controllers (#21) |
| 15 | Double opt-in (#11) + preference centre (#12) |
| 16 | E2E on Summit Park data, deliverability warm-up, demo rehearsal |

Gating lands in week 3 because the add-on can't be sold without it — but item #21
(the pre-existing leak on `marketing.campaigns` / `marketing.social_media`) is
independent and can ship any time.

Mobile-usable canvas is a constraint on days 4–5 and 11–12, not a follow-up.

---

## Answers to your open questions (from the code)

1. **Sending domain strategy** — unchanged recommendation (tiered), but note
   `INBOUND_EMAIL_DOMAIN` already defaults to `mail.renterinsight.com`
   (`campaign_sender.rb:137`) and `Brand.current.subdomain_root` is the
   rebrand-safe source for anything auto-generated. Don't hardcode the domain in
   new code — CLAUDE.md brand kernel rule.
2. **Per-location number provisioning** — already answered by the code: dealers
   pass an `area_code` and `TwilioProvisioningService` grabs what's available,
   raising `AreaCodeUnavailableError` if none. Ship it as-is.
3. **Attribution window** — no existing precedent to match; `GoalChecker` uses
   "since enrollment creation," unbounded. 60 days is a fine default, but make it
   a `PlatformSetting` so it's tunable without a deploy.
4. **Pro setup fee** — no code implication. Your call.

## Pricing implication

Two corrections to the cost table:
- **10DLC is a fixed platform cost, not ~$3/location/mo** (§2). Campaigns are
  already approved on the master brand, so there's no per-dealer registration
  fee to pass through. Margins are *better* than v2 claims.
- Per-number Twilio cost (~$1.15/mo) stands — that one is genuinely per-location.

Offsetting: the SES bulk path is less built-out than v2 assumed (§1), and
LinkedIn is out (§7), so **"Organic social posting" should be sold as Facebook +
Instagram**, not three platforms.
