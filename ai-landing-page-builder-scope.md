# AI Landing Page Builder — Scope

Expands item **#10** of `marketing-automation-plan-v3-audited.md` ("Landing page
as a `WebsitePage` + a free public route prefix + campaign linkage — 1.5d").

That estimate was correct for what it described: a place to put a page. It did
not cover document ingestion, generation, visitor tracking, identity
resolution, standalone use, or cloning. **Revised: ~29 dev-days.**

**Domain management, DNS, SSL, custom hostnames, host resolution, SSR head tags,
robots/sitemap, and publishing are all inherited wholesale from the website
builder.** Zero new work — see §1 "Domains + serving". Verified 2026-08-06; this
is stronger than the audit implied and it deleted the `/lp/` route I had
originally scoped (D1).

**Two framing decisions, now settled (2026-08-06):**

1. **This ships standalone *and* as part of Campaign Desk.** It is sellable on
   its own module key. Campaign Desk is not the owner — it is the surface that
   builds a landing page *alongside* the email, SMS, and social assets from one
   prompt. Architecturally that makes the page builder a **service with two
   callers**, which is a constraint on §3 below, not a packaging detail.
2. **Cloning is first-class**, and it is not one feature — see §2/D5. Plain
   duplicate is table stakes; clone-to-locations is the one a dealer group
   actually pays for.

Audited against `~/src/renterinsight_api` and `~/src/Platform_DMS_8.4.25` @
`staging`, 2026-08-06.

---

## Headline

**Three of the four asks are mostly assembly. One is greenfield.**

| Ask | Status |
|---|---|
| Upload a doc, scan it, build a matching page | ~70% exists — the scan/profile/project machine is shipped, it just only eats URLs today |
| Add videos to complement | Block + storage exist; **playback tracking is new** |
| Linked to lead intake forms | ~90% exists — form model, public route, embed component, identity resolution, notification |
| **Full tracking** | **0% exists.** There is no page-view, visit, or visitor table anywhere in the schema |
| Clone | Two clone patterns already shipped to copy — but neither is safe for a page carrying tracking state (D5) |

The single highest-leverage decision below is **§2: reuse `SiteContentProfile`
for documents instead of inventing a parallel model.** It makes "upload a
product sheet → preview it in every layout" nearly free, because projection is
already deterministic and already tested.

---

## 1. What already exists (the leverage)

### The scan → profile → project machine — shipped

- `app/models/site_content_profile.rb` — durable, template-agnostic Client
  Content Profile. Statuses `pending|fetching|extracting|ready|failed`, preview
  token, expiry, rotation, per-profile visible template list.
- `app/services/site_profiles/` — `orchestrator`, `fetcher`, `page_digest`,
  `profile_builder` (Claude Messages API, `AiModel.for(:generation)`),
  `profile_schema` (versioned contract, coerce-never-raise), `brand_extractor`,
  `contact_extractor`, `asset_importer`, `vendor_detector`, `url_guard`.
- `app/jobs/site_profile_scan_job.rb`, `app/models/site_profile_projection.rb`
- FE: `src/modules/website-builder/utils/projectProfile.ts` — deterministic
  profile-section → template-block projection, plus
  `__tests__/projectProfile.test.ts`. Nine templates in `utils/templates-data/`.
- `SiteProfilesList.tsx`, `CreateSiteFromProfileModal.tsx`, `siteProfileApi.ts`

`ProfileSchema` is deliberately semantic (`hero`, `about`, `services`,
`testimonials`, `faq`, `team`, `stats`, `process`) and block-agnostic, which is
exactly why a second consumer (landing pages) can be added without touching it
structurally.

### Multimodal document upload to Claude — shipped, in the wrong module

`app/services/campaigns/ai_builder.rb` already does the hard part:

- `#partition_attachments` splits uploads into **images** (real Claude image
  content blocks — the model *sees* the layout) vs **documents** (text-decoded)
- `#decode_base64_text` sniffs `%PDF` magic bytes → `#extract_pdf_text` via
  `pdf-reader` (30 pages / 50K chars cap), with a raw-UTF8 fallback
- Monthly credit limiting (`CreditLimitError`, default 50), `AiQueryLog`
  logging, `CampaignAiGeneration` audit row with token counts
- Routes live: `POST /api/v1/campaigns/ai_generate`, `.../refine`, `.../accept`
- FE: `AiBuilderModal.tsx` with the upload UX already built

This is the "upload a product sheet" mechanic, already proven in production.

### Domains + serving — shipped, and more complete than the audit implied

This is worth stating in full, because it removes work I had scoped:

- **`CompanyDomain`** — full lifecycle: `verify`, `check_dns`, `activate`,
  `deactivate`, `enable_email`, `check_email`, `hostname_advice`,
  `domain_connect`, `assignable_websites`. Domains are assigned **to a website**.
- **`CloudflareSaasService`** — custom hostnames, ownership verification, SSL
  provisioning, status monitoring, `cname_target`, and a `configured?` guard so
  the feature hides rather than raises when unconfigured.
- **`Dns::ApexAdvisor` / `Lookup` / `Registrar`**, **`DomainConnect::Discovery` /
  `ApplyLink`** — one-click DNS setup at supporting registrars.
- **`Websites::HostResolver`** — resolves an inbound Host, most specific first:
  verified `CompanyDomain` → `websites.domain` → `<subdomain>.<brand root>`.
  **Only published sites resolve.**
- **`Constraints::TenantWebsiteHost` + `Public::SitesController`** — a host-based
  catch-all (`get '*path'`) registered *first* in `routes.rb`. Rails answers on
  tenant hostnames so title/description/canonical/OG are in the first response;
  the body is still the React renderer via `spa_shell` + `inject_head`, with a
  `prerendered_body` hook as the static upgrade path.
- **Publish is a status flip**, not a build. `netlify_site_id` and `build_status`
  are vestigial — nothing in `#publish` touches Netlify.

Two details that directly shape this scope:

⚠️ **Aggressive edge caching.** `EDGE_MAX_AGE` 5min, `stale-while-revalidate`,
`stale-if-error` 1 day, ETag revalidation, and `strip_session_cookie` which
**deletes `Set-Cookie` from every response**. The controller's own comment: the
origin sees "a trickle rather than the full firehose." See D3 — this decides the
tracking design, it doesn't merely inform it.

✅ **`RESERVED_PREFIXES` already includes `/t/` and `/f/`** — tracked links and
intake forms punch through the tenant catch-all and work correctly on a dealer's
own hostname today. Those are the two things a landing page depends on most.

### The page substrate — shipped

`Website` (subdomain, custom domain, theme, `preview_token`, versioning,
`tracking_config`), `WebsitePage` (path, blocks, per-page SEO/OG, visibility),
`WebsiteMedia` (S3, `file_type: image|video|document`), `WebsiteVersion`,
`CloudflareSaasService` for custom domains, `SiteRenderer.tsx` rendering **21
block types** including `video`, `cta`, `contact`, `inventory`, `calculator`,
`stats`, `comparison`.

### Lead intake — shipped, and better than expected

`IntakeForm` (public_id, `/f/` route, embed code, Turnstile captcha, bound
`Source`, bound `Location`, `notified_user`, field mappings, `auto_create_lead`,
`auto_create_activity`) → `IntakeSubmission#create_lead_from_submission`, which
runs **`IdentityResolver`** and then either:

- absorbs into an existing non-converted lead (fill-empty merge + "🔁 REPEAT
  INQUIRY" note), or
- attaches the inquiry to an existing contact/account/converted lead and fires
  `notify_existing_customer_inquiry`

`SiteRenderer`'s `contact` block already renders `EmbeddedIntakeForm` from
`content.intakeFormId`. The `inventory` block already carries a `leadFormId`.

### Workqueue — already engagement-aware

`src/modules/workqueue/types.ts:22-25` — `engagement_opens`,
`engagement_clicks`, `last_engagement_at`, `engagement_source`. A landing-page
queue is a backend query plus a queue registration, not new UI architecture.

### Click identity — shipped

`TrackedLink` / `TrackedLinkEvent` / `CampaignLinkToken`. A recipient clicking
from a campaign email is already resolvable to their `CampaignEnrollment`, and
therefore to a `Lead`/`Contact`/`Account`.

### Clone — two existing patterns, and they disagree

- **`CampaignsController#duplicate` (`campaigns_controller.rb:188`)** — server
  side, in a transaction. `dup`s the record, prefixes the name, forces
  `status: 'draft'`, nulls `started_at` / `completed_at` /
  `audience_snapshot_at`, **empties `stats_cache`**, reassigns
  `created_by_user_id`, then deep-copies `campaign_steps` and
  `campaign_audience`.
- **`SiteEditor.handleDuplicatePageFromList` (`SiteEditor.tsx:642`)** — frontend
  only. Deep-clones blocks with fresh IDs, appends "(Copy)", timestamps a new
  slug. Copies `canonical_path` and every SEO field verbatim.

Siblings on the campaign pattern: `social_posts`, `agreement_templates`,
`agreements`, `project_templates`, `roles#clone`, `vehicles#clone`.

**Landing pages must follow the campaign pattern, not the page pattern.** The FE
page clone is fine for a static marketing page and wrong for one that owns
visits, events, a bound intake form, a campaign link, and a canonical URL.
Cloning `canonical_path` alone would point every copy's SEO at the original.

---

## 2. Architecture — the decisions

### D0. One builder, two callers. Not two builders.

Audit §16's warning about Campaign Desk ("would be a third campaign module")
applies here with more force: a standalone landing page module that duplicates
the block editor would be a *second website builder*.

So:

- **The editor is `website-builder` in landing-page mode.** Reuse `SiteEditor`,
  `EditorCanvas`, `AddBlockMenu`, `BlockEditorModal`, `SiteRenderer`. Landing
  mode hides page-tree/nav/footer controls and surfaces the conversion panel
  (form, CTA, tracking, video) instead.
- **`LandingPages::AiBuilder` is a headless service.** It must accept an
  externally-supplied brief and profile — it cannot own the prompt, because
  Campaign Desk's single-prompt orchestrator (plan item #13) needs to call it
  with the *same* brief it hands the campaign, SMS, and social generators.
  Getting this wrong means the campaign's landing page argues with the
  campaign's email copy.
- **Two entry surfaces, one code path:** a standalone "Landing Pages" list under
  its own module key, and Campaign Desk's orchestrator deep-linking into the
  same editor.

Contract sketch — the orchestrator fans one brief out to N generators:

```ruby
brief = Marketing::Brief.new(          # offer, audience, tone, inventory scope,
  company:, location:, prompt:,         # location, dates, source, profile ref
  site_content_profile: profile
)
Campaigns::AiBuilder.new(...).generate(brief:)
LandingPages::AiBuilder.new(...).generate(brief:)   # ← same brief
SocialPostGeneratorService.new(...).generate(brief:)
```

**Gating:** new module key `marketing.landing_pages`, sellable standalone.
Campaign Desk (`marketing.automation`) declares it in `optional:`, not
`requires:` — per audit §20, without it Campaign Desk skips the landing asset
rather than erroring.

### D1. A landing page is a `WebsitePage`. Don't build a `LandingPage` model.

Confirms audit §10. You inherit theme, blocks, media, SEO/OG, versioning,
preview tokens, custom domains, and the entire `SiteRenderer` for free.

**But** buyers of either surface may not own the Website Builder module, and may
have no `Website` row at all. So:

- Add `websites.kind` (`site` | `marketing`). Auto-provision one **system
  marketing site** per company on first landing-page creation — subdomain from
  `Brand.current.subdomain_root`, hidden from `WebsitesList`, not editable as a
  site. It is a container, not a product surface; users never see it.
- Add `website_pages.page_kind` (`page` | `landing`) and nullable
  `website_pages.campaign_id`. A standalone page has no campaign.

This removes the audit's "Campaign Desk generates the copy but can't publish"
degradation for landing pages, and it is what makes the standalone product
sellable to a dealer who has no website with us at all. Owning
`marketing.website` then becomes an *upgrade* — put the page on your real
domain — rather than a prerequisite.

**Correction to my first draft: there is no `/lp/` route, and no new public
route at all.**

I had scoped a `/lp/:slug` prefix plus the three-file frontend public-route
checklist. Both are unnecessary. `Constraints::TenantWebsiteHost` already puts a
catch-all `get '*path'` on every host that `Websites::HostResolver` resolves,
and resolution order 3 is `<subdomain>.<Brand.current.subdomain_root>`. So:

| Case | Serves at | New work |
|---|---|---|
| Dealer owns a verified `CompanyDomain` | `dealer.com/spring-sale` | **none** |
| Dealer has a `Website` but no domain | `<subdomain>.<brand root>/spring-sale` | **none** |
| No `Website` at all (the standalone buyer) | system marketing site's subdomain | auto-provision only |

A landing page is a `WebsitePage` with a path. The existing router serves it,
`Public::SitesController` gives it SSR head tags, `robots.txt` and `sitemap.xml`
come along, Cloudflare terminates SSL, and `enforce_canonical_host` handles the
www/apex split. The three-file checklist governs **SPA routes on the platform
host** — a different thing from a tenant-hostname path, and not in play here.

⚠️ The one real constraint: `HostResolver#published_scope` only resolves
websites with `status: 'published'`. The system marketing site must be
provisioned **published**, since it is a container the user never sees and will
never think to publish. Page-level visibility is what gates a draft landing page,
not site status.

### D2. A document is just another profile source.

Add `site_content_profiles.source_kind` (`url` | `manual` | `document`).
`SiteProfiles::DocumentIngestor` replaces `Fetcher` for that source kind and
emits the same page-digest shape into the same `ProfileBuilder`.

Consequences, all good:
- Projection into every layout stays free and deterministic
- One profile can be re-projected into layouts that don't exist yet
- A scanned *website* and an uploaded *product sheet* become interchangeable
  inputs to the same builder
- `SiteProfilesList` and the shareable preview token work unchanged

`ProfileSchema` needs product-shaped sections it doesn't have today — a spec
sheet is not a dealer homepage. **Bump `ProfileSchema::VERSION` to 2** and add:

```ruby
'product'  => %w[name model_number summary msrp],
'specs'    => %w[label value unit group],
'features' => %w[title description icon_hint],
'options'  => %w[title description price],
'floorplan'=> %w[name beds baths sqft dimensions image_url]
```

The version field already exists and old profiles must stay projectable — the
model documents this as a deliberate contract.

### D3. Tracking is new. Build it once, for pages generally.

Nothing exists. Schema grep for `page_view` / `visitor` / `session_id` /
`website_analytics` returns zero. Two tables:

```
page_visits          company_id, website_page_id, visitor_token, session_token,
                     referrer, utm_{source,medium,campaign,content,term},
                     campaign_link_token_id, campaign_enrollment_id,
                     identified_entity_type/_id, device, country, ip_hash,
                     first_seen_at, last_seen_at, duration_ms
page_visit_events    page_visit_id, event_type, occurred_at, payload jsonb
```

`event_type`: `view`, `scroll_25/50/75/100`, `cta_click`, `video_play`,
`video_25/50/75/complete`, `form_start`, `form_submit`, `outbound_click`.

**Edge caching makes a client beacon the only option — this is not a preference.**

`Public::SitesController` serves published pages with `EDGE_MAX_AGE` 5min,
`stale-while-revalidate`, `stale-if-error` 1 day, and ETag revalidation. Its own
comment says the origin sees "a trickle rather than the full firehose." So:

- ❌ **Origin-side view counting is impossible.** Most page views never reach
  Rails. Any design that counts requests in the controller undercounts by
  whatever Cloudflare's hit rate is — silently, and worst on the most popular
  pages.
- ❌ **The origin cannot set the visitor cookie.** `after_action
  :strip_session_cookie` deletes `Set-Cookie` from every response, and a
  per-visitor `Set-Cookie` would make the HTML uncacheable anyway — poisoning
  the cache for everyone to identify one person. **The visitor token must be
  minted client-side** (JS, first-party cookie or `localStorage`) or returned by
  the beacon endpoint, which is uncached.
- ✅ The beacon endpoint must live under a path the tenant catch-all won't
  swallow. `RESERVED_PREFIXES` is the list to extend, and it needs a
  `no-store` cache header.

⚠️ **Write path.** Prod/staging run `solid_queue`, a *Postgres-backed* queue. One
ActiveJob per beacon puts beacon volume and job rows on the same database. Write
the visit as a single cheap INSERT on the beacon request, batch events
client-side (flush on interval + `visibilitychange`), and roll up async.

⚠️ **Do not add a new tokenised route.** Audit §13: `/t/:token` already has two
claimants and `CampaignTrackingController#click` is dead code as a result. Any
new tokenised link must go through `Public::TrackedLinksController`.

✅ **Where the instrumentation lives.** `Public::SitesController` renders
`spa_shell` + `inject_head` — the page *body* is still the React `SiteRenderer`.
So client instrumentation does belong in the React renderer, as originally
scoped. But it must survive a `prerendered_body` future, so hang it off the
rendered DOM, not off React lifecycle internals.

### D4. Identification has two paths, and both already have their hard half built.

**Path A — arrives known.** Campaign email → `/t/:token` → redirect to
`/lp/:slug?rt=<token>`. `CampaignLinkToken` resolves the enrollment → recipient.
Stamp the visit, bind `visitor_token` → entity.

**Path B — anonymous, then identified.** Visitor browses anonymously, then
submits the page's intake form. `IntakeSubmission` already runs
`IdentityResolver`. On resolve, **back-stamp every prior visit carrying the same
`visitor_token` onto the resolved entity** — that retro-attributes the whole
pre-identification session, which is the actual differentiator here.

Both paths then emit onto the campaign→workflow event bridge and set
`engagement_source = 'landing_page'` for the workqueue.

### D5. Clone is four operations. Name them separately or they collide.

Follow the **campaign** pattern: `POST /api/v1/landing_pages/:id/duplicate`,
server-side, transactional, resetting derived state. Not the FE page pattern.

**What carries vs what resets:**

| Carries | Resets / re-derived |
|---|---|
| Blocks (deep-copied, **fresh block IDs**) | `path` / slug — uniqueness enforced |
| Theme + layout overrides | `status` → `draft`, `published_at` → nil |
| `WebsiteMedia` references (same S3 rows — no re-upload) | **All visits, events, `stats_cache`** — never copy |
| `site_content_profile_id` (provenance: which doc built this) | **`canonical_path`** — inheriting it tanks the copy's SEO |
| Video config, CTA targets | `campaign_id` → nil, or re-pointed if cloning into a campaign |
| Field *shape* of the intake form | The `IntakeForm` itself → new form (see below) |
| | UTM defaults, `preview_token`, `created_by` |

**The intake form is the subtle one.** Sharing one `IntakeForm` across clones
co-mingles submissions and makes per-page attribution impossible — which
defeats the tracking in D3. Default to **cloning the form** (bound to the new
page's location, source, and `notified_user_id`), with an explicit "share the
original form" opt-out for people who genuinely want one pooled inbox.

**The four operations:**

1. **Duplicate** — same company + location, new slug. Iterating on an offer.
2. **Clone to locations** *(the valuable one)* — one offer fanned across N
   locations, each copy re-resolving location-bound content: phone, address,
   hours, inventory block `location_ids`, `IntakeForm.location_id` +
   `notified_user_id`, and the assigned rep. `Location` is already threaded
   through `IntakeForm`, `Campaign`, `Website`, and the inventory blocks, so the
   re-resolution has real hooks to hang on. For a dealer group this is the
   difference between one page and twelve.

   **Copy stays identical** (decided 2026-08-06). Only bound data varies. This
   is a fast way to spin up a new version, not a per-market rewrite.

   Two consequences worth having on purpose:
   - **The whole operation is deterministic.** No AI call, no token spend, no
     `CreditLimitError` path, instant even at twelve locations. Clone-to-
     locations does not touch `LandingPages::AiBuilder` at all.
   - **Identical copy on N URLs is duplicate content.** See the `robots`
     default in D6 — this is why that default exists.
3. **Save as template / start from template** — company- or platform-scoped,
   strips company-specific content, keeps structure. Direct precedent:
   `CampaignTemplate` + `CampaignTemplateGallery`. **Defer to v1.1.**
4. **Re-project** — *not a clone.* Same `SiteContentProfile`, different layout,
   already free via `projectProfile.ts`. Surface it distinctly in the UI or
   people will clone-then-restyle and lose the profile link.

⚠️ **Tenant isolation.** The duplicate endpoint must derive company from the
request's tenant context and **never** accept `company_id` in params — CLAUDE.md
critical rule #4. Cross-company cloning (platform admin seeding a new tenant) is
a separate, platform-admin-only path or it is out of scope; it is not a flag on
this endpoint.

🔗 **Hard dependency:** the campaign→workflow event bridge is **Tier-1 item #1**
of the campaign desk plan (2d, not yet built). Without it, landing-page
engagement can be *recorded* but cannot *trigger* anything. Phase 4 below
assumes it lands first.

---

### D6. Landing pages default to `noindex`.

A direct consequence of D5 op #2: twelve location clones sharing identical copy
on twelve URLs is textbook duplicate content, and Google will pick a winner for
you.

⚠️ **Correction (2026-08-06): `website_pages.robots` does not exist.** I said it
did. It doesn't — `robots` is a column on `blog_posts`. Neither
`canonical_path` nor `parent_page_id` exists on `website_pages` either, yet
`WebsitePagesController#page_params` permits all three (`:parent_page_id` with
the comment *"Will be ignored if column doesn't exist"* — Rails raises on
unknown attributes rather than ignoring them), the FE `WebsitePage` type
declares all three, and `SiteEditor`'s page clone copies `seo?.robots` and
`canonical_path` into the create call.

**Per-page SEO controls on website pages are non-functional today.** Phase 0
adds the columns; that fixes an existing bug and unblocks D6 in one move.
`WebsitePage#parent_page` / `scope :top_level` reference `parent_page_id` and
would raise if ever called — the index action has the lookup commented out with
a note saying exactly that.

Set the default per page kind:

- **Campaign-linked pages** (`campaign_id` present) → `noindex, nofollow`.
  Traffic arrives from an email, SMS, or ad. There is nothing to gain from
  indexing and a real ranking risk in letting a dozen near-identical pages
  compete with the dealer's actual site.
- **Standalone pages** → author's choice, defaulting to `noindex` until they
  publish deliberately.
- **Location clones** → inherit `noindex` regardless. If someone wants a set
  indexed, that is the point at which the copy has to be differentiated, and the
  UI should say so rather than silently shipping twelve competing pages.

This also retires the duplicate-content half of the `canonical_path` reset in
D5 — the reset still matters, but noindex is the load-bearing protection.

---

## 3. Phases

| # | Phase | Work | Est. |
|---|---|---|---|
| 0 | **Substrate** | `websites.kind` + system marketing site auto-provision (**created published** — D1); `website_pages.page_kind` + nullable `campaign_id`; per-page publish/unpublish. **No new public route** — existing host resolution serves it | 2d |
| 1 | **Document → Profile** | `source_kind` column; `SiteProfiles::DocumentIngestor`; S3 upload endpoint; `ProfileSchema` v2 product sections; PDF page rasterization → vision pass; embedded image extraction → `WebsiteMedia`; FE upload modal reusing `AiBuilderModal` UX + existing status states | 5d *(incl. 1d spike — see R1)* |
| 2 | **Projection → layouts** | 4–6 dedicated single-page LP layouts (above-fold CTA, no nav — the 9 site templates are the wrong shape); extend `projectProfile.ts` with an LP target + product sections; preview-all-layouts picker; commit to a `WebsitePage` | 3d |
| 3 | **Tracking** | 2 tables; beacon endpoint + first-party visitor cookie; client instrumentation in `SiteRenderer`; scroll depth, CTA, outbound; video quartiles (self-hosted + YouTube/Vimeo); rollup job; analytics panel reusing `TimeseriesChart` / `LinkBreakdownPanel` shapes | 5d |
| 4 | **Identity + workqueue** | Tracked-link → visit binding; anonymous→known back-stamping via `IdentityResolver`; emit onto the campaign→workflow bridge; `engagement_source='landing_page'`; "Landing page engaged" workqueue queue | 4d |
| 5 | **Generation loop** | `LandingPages::AiBuilder` as a **headless service taking an external brief** (D0) — generate + refine + credit limit + `AiQueryLog`; auto-create the `IntakeForm` from the generated field list, bound to the page's `Source` + location; video slot suggestion + picker; SEO/OG from profile | 4d |
| 6 | **Standalone surface** | `marketing.landing_pages` module key + `require_module!` + FE route gate; "Landing Pages" list page (`EnterpriseListHeader` + `SelectableTable` + `PaginationControls` + stats tiles); permissions; landing-mode editor chrome | 2d |
| 7 | **Clone** | Server-side `#duplicate` on the campaign pattern — fresh block IDs, reset canonical/status/stats, form clone-vs-share (D5); **clone to locations** fan-out with location re-resolution | 3d |
| 8 | **Orchestrator integration** | `Marketing::Brief` shared contract; Campaign Desk item #13 calls `LandingPages::AiBuilder` with the same brief; campaign→page linkage + "Landing Page" tab on `CampaignDetail` | 1d |
| | | | **≈29d** |

Phases 0–2 are demoable on their own ("upload a spec sheet, get a live page in
six designs"). Phases 3–4 are what make it a *marketing* product rather than a
page generator. **Phases 6–8 are what make it two products instead of one** —
and phase 8 is small only because D0 forces the headless-service shape in phase
5. If phase 5 ships owning its own prompt, phase 8 becomes a rewrite.

Deferred to v1.1: save-as-template / template gallery (D5 op #3, ~2d).

---

## 4. Risks

**R1 — PDF imagery. Biggest unknown; spike it first.**
`pdf-reader` extracts **text only**. A product sheet is mostly photography,
floor plans, and layout. Matching a doc's *look* needs pixels. Two paths, both
probably needed:
- Rasterize each page → PNG → Claude image blocks (`AiModel.for(:vision)`
  already exists) for design/layout cues. Needs poppler or ImageMagick on
  Render — **verify the buildpack before committing to this**.
- Walk embedded raster XObjects to recover the actual photos for reuse as page
  media. Fiddlier, but without it the generated page has no imagery.

Fallback if the spike fails: text-only extraction + an explicit "add your
images" step. Degrades the demo but doesn't block the feature.

**R2 — Beacon volume vs `solid_queue`.** See D3. Get the write path right up
front; retrofitting it after a customer's page goes viral is painful.

**R3 — Video quartiles on third-party players.** Self-hosted S3 video
instruments trivially off the `<video>` element. YouTube needs the IFrame API,
Vimeo needs player.js — both external scripts on a published page. Check
whatever CSP the published sites serve under.

**R4 — Bot traffic.** Inflated view counts destroy trust in the numbers on
day one. Filter known crawlers; Turnstile is already available if needed.

**R5 — Privacy.** First-party visitor cookies + IP + retroactive
de-anonymization is exactly the surface CCPA/CPRA cares about. Needs a decision
on consent banner and a documented retention window before launch, not after.

**R6 — Brand kernel.** Auto-provisioned campaign-site subdomains must come from
`Brand.current.subdomain_root` / `PLATFORM_SUBDOMAIN_ROOT`. Hardcoding a domain
here re-introduces exactly what the rebrand branch fixed.

---

## 5. Decisions I need from you

**Settled 2026-08-06:** standalone *and* Campaign Desk (D0, own module key,
`optional:` from Campaign Desk); pages default to the system marketing site so
neither surface requires the Website Builder module (D1); cloning is in, four
operations, three of them in v1 (D5); **clone-to-locations keeps copy
identical** and varies only bound data, which makes it deterministic and forces
the `noindex` default (D5 op #2, D6).

Still open:

1. **Dedicated LP layouts, or reuse the 9 site templates?** I recommend
   dedicated — a landing page is single-purpose, no nav, one CTA. Reusing the
   site templates is cheaper but produces pages that convert worse.
2. **Track anonymous visitors pre-identification?** Yes, in my view — the
   retro-attribution in D4/Path B is the feature people actually pay for. But
   it's the main driver of R5, so it's your call.
3. **Attribution window.** Audit §5 recommends 60 days as a `PlatformSetting`.
   Same setting should govern how far back visits get back-stamped.
4. **Scope of "upload"** — product sheets only, or also brochures, floor plan
   PDFs, and manufacturer spec packets? All four project into the same profile,
   but each wants slightly different `copy.product` extraction prompting.
5. **Does a standalone landing page get its own pricing tier**, or ride the
   Campaign Desk per-location price when bundled? Affects nothing technical
   beyond `SubscriptionPlanModule#config`, but it needs answering before
   phase 6.

---

## 6. Explicitly out of scope

- A/B testing / multivariate — worth doing later, needs the tracking from
  Phase 3 to exist first
- Form logic branching (conditional fields) — `IntakeForm.schema` is a flat
  field array today
- Save-as-template / template gallery — deferred to v1.1 (D5 op #3)
- Cross-company cloning — platform-admin-only path if wanted at all, never a
  flag on the tenant-facing duplicate endpoint (D5)
- Multi-language pages
