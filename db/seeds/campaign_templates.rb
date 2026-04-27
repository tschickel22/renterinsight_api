# frozen_string_literal: true

# Email Campaign Templates — Phase A seeded templates.
# These are platform-level (company_id: nil, is_seeded: true). Tenants see them via
# CampaignTemplate.for_company_or_seeded(company.id).
#
# Block format reference (campaign_step.body_blocks):
#   { "type" => "text",      "html" => "..." }
#   { "type" => "button",    "label" => "...", "url" => "...", "style" => "primary" }
#   { "type" => "divider" }
#   { "type" => "image",     "url" => "...", "alt" => "..." }
#   { "type" => "inventory", "ref" => "step.inventory_block_config" }
#   { "type" => "footer_unsubscribe" }   # auto-injected by CampaignStep callback if missing

puts "🌱 Seeding campaign templates..."

# ---------------------------------------------------------------------------
# Helper for plain text + button blocks
def text_block(html); { "type" => "text", "html" => html }; end
def button_block(label, url, style = "primary"); { "type" => "button", "label" => label, "url" => url, "style" => style }; end
def divider_block; { "type" => "divider" }; end
def inventory_block; { "type" => "inventory", "ref" => "step.inventory_block_config" }; end
def footer_block; { "type" => "footer_unsubscribe" }; end

# ============================================================
# 1. mhi-show-module-tour (B2B SaaS sales — 8-step module tour)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "mhi-show-module-tour", company_id: nil) do |t|
  t.name = "MHI Show Follow-up: Module Tour (8-step drip)"
  t.description = "Long-form B2B drip walking through every RenterInsight module after meeting at MHI. 60-day tour."
  t.category = "b2b_saas_sales"
  t.vertical = "b2b"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "source", "operator" => "equals", "value" => "MHI Show" }] } }
  t.goal_config_template = { "primary_goal" => "replied", "remove_on_goal_met" => true, "additional_goals" => ["form_submitted"] }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu], "hour_start" => 9, "hour_end" => 16 }
  t.steps_template = [
    {
      "wait_days" => 0, "wait_hours" => 0,
      "subject" => "Great meeting you at MHI, {{first_name}}",
      "preheader" => "Quick recap and a 20-minute demo offer",
      "body_blocks" => [
        text_block("<p>Hi {{first_name}},</p><p>Good talking with you at the show. You mentioned the day-to-day pain of running your dealership across spreadsheets, email threads, and three different tools that don't talk to each other.</p><p>RenterInsight is one DMS for MH/RV retailers — CRM, inventory, sales deals, project management, finance, warranty claims, parts, and customer portal — all stitched together.</p><p>Over the next few weeks I'll send a short note on each module — one a week, no fluff. If something hits, reply and we'll book 20 minutes.</p>"),
        button_block("Book a 20-minute demo", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 4, "wait_hours" => 0,
      "subject" => "How [Module: CRM] saves dealers 6 hours a week",
      "preheader" => "Your contacts, leads, and accounts in one shared view",
      "body_blocks" => [
        text_block("<p>Most MH/RV retailers we talk to keep customer info in three places: a spreadsheet, the salesperson's inbox, and someone's head. When that salesperson is out, deals stall.</p><p>The RenterInsight CRM is built for the way dealerships actually work — every lead, contact, and account is shared across the team with full activity history, communication threads, and assignment rules. New rep on Monday? They have full context on every open opportunity by lunch.</p>"),
        button_block("See the CRM in action", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 4, "wait_hours" => 0,
      "subject" => "Your inventory, finally in one place — Inventory module",
      "preheader" => "One source of truth for every unit on the lot",
      "body_blocks" => [
        text_block("<p>Half the dealers we onboarded last quarter were syncing inventory across their website, MHVillage, RVTrader, and an internal spreadsheet — by hand.</p><p>The RenterInsight inventory module is the source of truth. List once, syndicate everywhere. Track every cost, photo, video, brochure, and unit history. Public listings update the moment you change a price internally.</p>"),
        button_block("Walk through the inventory module", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 6, "wait_hours" => 0,
      "subject" => "Sales Deals: pipeline visibility your team will actually use",
      "preheader" => "Stage progression, commissions, and forecasting without spreadsheets",
      "body_blocks" => [
        text_block("<p>If your sales pipeline lives in someone's email, deals get lost. We've heard it dozens of times — a hot prospect goes cold because nobody followed up after the holiday weekend.</p><p>RenterInsight Sales Deals gives you a real pipeline: stages tied to your sales process, automated follow-up tasks, commission calculation as deals close, and forecast reports so you know what's coming next month.</p>"),
        button_block("See pipeline reporting", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 7, "wait_hours" => 0,
      "subject" => "Project Management: client transparency from PA to keys",
      "preheader" => "Stop fielding 'where's my home?' phone calls",
      "body_blocks" => [
        text_block("<p>The single biggest complaint at MH dealerships isn't pricing — it's communication. Buyers wait 6 to 14 weeks between PA and delivery, and most of that time they're calling the dealership for updates.</p><p>RenterInsight Project Management gives every buyer a self-serve portal showing exactly where their home is in the process: factory build, transport, site prep, set, finish-out, walk-through. They get the answer without dialing your front desk.</p>"),
        button_block("See the buyer portal", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 7, "wait_hours" => 0,
      "subject" => "Finance & Loans: fewer dropped applications",
      "preheader" => "Application abandonment is solvable",
      "body_blocks" => [
        text_block("<p>Dealers tell us 30-40% of credit applications abandon partway through. Either the form is too long, or it's a separate website, or the buyer can't pick back up where they left off.</p><p>The RenterInsight Finance module embeds inside your portal. Buyers save and return. F&I sees real-time progress. Dropped apps go down — closed deals go up.</p>"),
        button_block("Walk through Finance & Loans", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 12, "wait_hours" => 0,
      "subject" => "Warranty Claims that don't take 90 days",
      "preheader" => "Manufacturer AR and claim turnaround",
      "body_blocks" => [
        text_block("<p>Open warranty claims that age past 60 days at the manufacturer are a daily grind. Phone calls, email chains, lost paperwork.</p><p>RenterInsight Warranty Claims tracks every submission with photo evidence, manufacturer routing, AR reconciliation, and an aging report so you know exactly what's stuck where. Median claim turnaround for our customers is 19 days.</p>"),
        button_block("See claim management", "{{demo_url}}"),
        footer_block
      ]
    },
    {
      "wait_days" => 18, "wait_hours" => 0,
      "subject" => "Ready when you are, {{first_name}}",
      "preheader" => "Whenever you're ready, the door's open",
      "body_blocks" => [
        text_block("<p>Hi {{first_name}},</p><p>That's the full module tour. Everything I described is in production at dealerships your size. None of it is roadmap.</p><p>If any of it sounded relevant, the easiest next step is a 20-minute screen share where I show your data, not a generic deck. Otherwise, I'll go quiet — but I'm an email away whenever you're ready.</p>"),
        button_block("Book a 20-minute demo", "{{demo_url}}"),
        footer_block
      ]
    }
  ]
end

# ============================================================
# 2. cold-retailer-pain-points (B2B SaaS — 5-step cold)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "cold-retailer-pain-points", company_id: nil) do |t|
  t.name = "Cold MH/RV Retailer Outreach (5-step pain points)"
  t.description = "Pain-point first, no MHI hook. For cold-list outreach to dealerships."
  t.category = "b2b_saas_sales"
  t.vertical = "b2b"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => {} }
  t.goal_config_template = { "primary_goal" => "replied", "remove_on_goal_met" => true }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[tue wed thu], "hour_start" => 9, "hour_end" => 14 }
  t.steps_template = [
    { "wait_days" => 0, "wait_hours" => 0, "subject" => "How are MH dealers handling [pain] in 2026?", "preheader" => "Quick question",
      "body_blocks" => [text_block("<p>Hi {{first_name}},</p><p>Saw {{company.name}} on the MH retail directory. Most dealerships your size are juggling a separate CRM, inventory tool, and finance app — and losing context across them.</p><p>Curious how you're handling it today. If it's working, great. If it isn't, we should talk.</p>"), button_block("15-minute call", "{{demo_url}}"), footer_block] },
    { "wait_days" => 4, "wait_hours" => 0, "subject" => "5 things slowing your dealership down", "preheader" => "Things we hear most often",
      "body_blocks" => [text_block("<p>Top 5 things we hear from MH retailers your size:</p><ol><li>Inventory listed in 4 different places, all slightly out of sync</li><li>Buyer calls asking 'where's my home in the process?'</li><li>F&I apps that abandon halfway through</li><li>Warranty claims sitting open at the manufacturer past 60 days</li><li>New salespeople taking 60 days to ramp because customer history is in someone's inbox</li></ol><p>RenterInsight is one DMS for all five.</p>"), button_block("See it", "{{demo_url}}"), footer_block] },
    { "wait_days" => 5, "wait_hours" => 0, "subject" => "What if your CRM, inventory, and finance talked to each other?", "preheader" => "Single source of truth",
      "body_blocks" => [text_block("<p>The reason dealerships use 4 tools is because nobody built one that does everything. We did. CRM, inventory, sales deals, project mgmt, finance, warranty, parts, customer portal — one DMS, one schema, one login.</p>"), button_block("20-min walkthrough", "{{demo_url}}"), footer_block] },
    { "wait_days" => 6, "wait_hours" => 0, "subject" => "Quick question, {{first_name}}", "preheader" => "If now's not the time",
      "body_blocks" => [text_block("<p>Hey {{first_name}},</p><p>If now isn't the right time, totally get it. Just hit reply with 'not now' and I'll quiet down. If anyone else at {{company.name}} should be on this thread, point me to them.</p>"), footer_block] },
    { "wait_days" => 5, "wait_hours" => 0, "subject" => "Last note from RenterInsight", "preheader" => "Closing the loop",
      "body_blocks" => [text_block("<p>Closing the loop. If timing changes, you have my email.</p><p>Either way, good luck this season.</p>"), footer_block] }
  ]
end

# ============================================================
# 3. competitive-switch-trove (B2B competitive — 6-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "competitive-switch-trove", company_id: nil) do |t|
  t.name = "Switch from Trove (6-step migration story)"
  t.description = "For dealerships currently on Trove. Side-by-side comparison and switch-assistance pitch."
  t.category = "b2b_saas_sales"
  t.vertical = "b2b"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "current_dms", "operator" => "equals", "value" => "Trove" }] } }
  t.goal_config_template = { "primary_goal" => "replied", "remove_on_goal_met" => true }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu], "hour_start" => 9, "hour_end" => 16 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "How {{company.name}} can leave Trove without the headache", "preheader" => "Migration that doesn't take 6 months", "body_blocks" => [text_block("<p>Hi {{first_name}},</p><p>If you're on Trove and feel boxed in by their roadmap, you're not alone. We've migrated several dealerships off Trove in the last 12 months. The bottleneck is always data export — we built a Trove migration tool to handle it.</p>"), button_block("See the migration story", "{{demo_url}}"), footer_block] },
    { "wait_days" => 5, "subject" => "Trove vs RenterInsight — side by side", "preheader" => "Where each one is strong", "body_blocks" => [text_block("<p>Quick comparison:</p><ul><li><strong>Trove:</strong> strong on legacy F&I, weak on customer portal, no integrated PM, no warranty AR</li><li><strong>RenterInsight:</strong> CRM + inventory + deals + PM + finance + warranty + portal, all native</li></ul>"), button_block("Get the full comparison", "{{demo_url}}"), footer_block] },
    { "wait_days" => 5, "subject" => "What dealerships actually said after switching", "preheader" => "References on request", "body_blocks" => [text_block("<p>Three retailers who switched in the last year (we'll connect you with any of them):</p><ol><li>Cut data entry by 4 hours/day</li><li>Shipped a customer portal in week 2 that took 8 months on Trove</li><li>Closed Q4 with the highest deal velocity in their history</li></ol>"), button_block("Talk to a reference", "{{demo_url}}"), footer_block] },
    { "wait_days" => 7, "subject" => "How long does a Trove → RI migration actually take?", "preheader" => "Not 6 months", "body_blocks" => [text_block("<p>Median migration: 18 days from contract signature to go-live, including data import, training, and parallel run. Largest one was 31 days.</p>"), button_block("See the migration plan", "{{demo_url}}"), footer_block] },
    { "wait_days" => 6, "subject" => "Pricing without the multi-year contract", "preheader" => "Month to month if you want", "body_blocks" => [text_block("<p>We don't make you sign a 3-year deal. Month-to-month is fine. Most dealerships move to annual once they see the value.</p>"), button_block("Get pricing", "{{demo_url}}"), footer_block] },
    { "wait_days" => 7, "subject" => "If you want to talk", "preheader" => "Open invite", "body_blocks" => [text_block("<p>Whenever you're ready. No pressure.</p>"), button_block("Book a call", "{{demo_url}}"), footer_block] }
  ]
end

# ============================================================
# 4. competitive-switch-cirrus (B2B competitive — 6-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "competitive-switch-cirrus", company_id: nil) do |t|
  t.name = "Switch from Cirrus (6-step migration story)"
  t.description = "For dealerships currently on Cirrus. Side-by-side comparison and switch-assistance pitch."
  t.category = "b2b_saas_sales"
  t.vertical = "b2b"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "current_dms", "operator" => "equals", "value" => "Cirrus" }] } }
  t.goal_config_template = { "primary_goal" => "replied", "remove_on_goal_met" => true }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu], "hour_start" => 9, "hour_end" => 16 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Cirrus → RenterInsight: a real migration story", "preheader" => "How dealerships switch", "body_blocks" => [text_block("<p>Hi {{first_name}},</p><p>If Cirrus's lack of a real customer portal is biting you, you're not alone. We've migrated several dealerships off Cirrus in the last 12 months — the customer portal was the #1 reason in every case.</p>"), button_block("See the migration", "{{demo_url}}"), footer_block] },
    { "wait_days" => 5, "subject" => "Cirrus vs RenterInsight — what's actually different", "preheader" => "Beyond the marketing", "body_blocks" => [text_block("<p>Cirrus does deals well. They lack: real customer portal, integrated project mgmt, warranty AR, native parts module. RenterInsight has all four.</p>"), button_block("See the comparison", "{{demo_url}}"), footer_block] },
    { "wait_days" => 5, "subject" => "Three things you can't do in Cirrus", "preheader" => "That you can in RenterInsight", "body_blocks" => [text_block("<p>1. Give buyers a self-serve portal with PA-to-keys progress<br>2. Track manufacturer warranty AR with aging reports<br>3. Tie parts inventory to service tickets and warranty claims</p>"), button_block("See those features", "{{demo_url}}"), footer_block] },
    { "wait_days" => 7, "subject" => "How a Cirrus migration actually goes", "preheader" => "Median 22 days", "body_blocks" => [text_block("<p>22 days is our median Cirrus → RI migration. Data export from Cirrus is reasonable; the slow part is staff training, which we run live.</p>"), button_block("See the migration plan", "{{demo_url}}"), footer_block] },
    { "wait_days" => 6, "subject" => "Pricing — month-to-month available", "preheader" => "No long lock-ins", "body_blocks" => [text_block("<p>Month-to-month is available. Most dealerships move to annual once they see value.</p>"), button_block("Get pricing", "{{demo_url}}"), footer_block] },
    { "wait_days" => 7, "subject" => "Anytime, {{first_name}}", "preheader" => "Open door", "body_blocks" => [text_block("<p>Whenever you're ready, the door's open.</p>"), button_block("Book a call", "{{demo_url}}"), footer_block] }
  ]
end

# ============================================================
# 5. new-lead-welcome-mh (B2C — 5-step welcome with inventory)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "new-lead-welcome-mh", company_id: nil) do |t|
  t.name = "MH New Lead Welcome (5-step buyer education)"
  t.description = "Educational sequence for new manufactured home buyers. Day 6 includes a personalized inventory block."
  t.category = "mh_buyer_journey"
  t.vertical = "manufactured_home"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "status", "operator" => "equals", "value" => "new" }] } }
  t.goal_config_template = { "primary_goal" => "replied", "additional_goals" => %w[form_submitted deal_created] }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu fri sat], "hour_start" => 8, "hour_end" => 19 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Welcome, {{first_name}}! Here's how home buying works.", "preheader" => "Your buyer guide",
      "body_blocks" => [text_block("<p>Welcome, {{first_name}}!</p><p>Buying a manufactured home is different from buying a stick-built. The basic path:</p><ol><li>Pick a home you love</li><li>Get pre-qualified for financing</li><li>Secure a site (your land, our community, or land we help you find)</li><li>Sign the purchase agreement</li><li>Site prep + factory build run in parallel — 6 to 14 weeks</li><li>Delivery, set, finish-out, walk-through, keys</li></ol><p>Over the next two weeks I'll send a short note on each step. Reply anytime — I'm a real person.</p>"), footer_block] },
    { "wait_days" => 3, "subject" => "Financing 101 for manufactured homes", "preheader" => "What pre-qualification looks like",
      "body_blocks" => [text_block("<p>Most buyers wait too long to talk to a lender. The earliest you should think about financing is right now — even if you haven't picked a home.</p><p>Pre-qualification is a soft credit pull. It tells you what monthly payment range you'd qualify for, which means you shop in a price range that actually fits.</p>"), button_block("Get pre-qualified", "{{prequalify_url}}"), footer_block] },
    { "wait_days" => 3, "subject" => "Homes in your budget", "preheader" => "Picked specifically for you",
      "body_blocks" => [text_block("<p>Hi {{first_name}}, here are homes we have on the lot right now that match what you told us:</p>"), inventory_block, button_block("Browse all homes", "{{public_inventory_url}}"), footer_block],
      "inventory_block_config" => { "mode" => "segment_based", "max_units" => 6, "sort" => "best_match", "fallback" => "show_cta" } },
    { "wait_days" => 4, "subject" => "Have you visited the community?", "preheader" => "Walking through is different",
      "body_blocks" => [text_block("<p>Photos online are great. Standing inside a home is different. Let's set up a visit.</p>"), button_block("Schedule a tour", "{{tour_url}}"), footer_block] },
    { "wait_days" => 4, "subject" => "Ready to talk?", "preheader" => "When you are",
      "body_blocks" => [text_block("<p>{{first_name}}, whenever you're ready to take the next step — pre-qualify, schedule a tour, or just have a question — I'm one click away.</p>"), button_block("Schedule a call", "{{call_url}}"), footer_block] }
  ]
end

# ============================================================
# 6. budget-inventory-digest (recurring weekly digest)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "budget-inventory-digest", company_id: nil) do |t|
  t.name = "Weekly Inventory Digest (recurring)"
  t.description = "Tuesday-morning weekly digest of new inventory matched to each recipient's budget."
  t.category = "new_arrival_digest"
  t.vertical = "manufactured_home"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "status", "operator" => "in", "value" => %w[new active] }] } }
  t.goal_config_template = { "primary_goal" => "clicked", "additional_goals" => ["replied"] }
  t.send_window_template = { "timezone" => "America/Chicago", "recurrence_cron" => "0 9 * * 2" }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "{{first_name}}, here are this week's homes in your range", "preheader" => "Fresh inventory matched to your budget",
      "body_blocks" => [text_block("<p>Good morning {{first_name}},</p><p>Here are the homes that came on the lot or dropped in price this week, matched to what you told us about your budget and preferences:</p>"), inventory_block, button_block("Browse all homes", "{{public_inventory_url}}"), footer_block],
      "inventory_block_config" => { "mode" => "segment_based", "max_units" => 6, "sort" => "newest", "fallback" => "show_cta" } }
  ]
end

# ============================================================
# 7. factory-order-wait (factory order build cycle — 6-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "factory-order-wait", company_id: nil) do |t|
  t.name = "Factory Order Build Updates (6-step build cycle)"
  t.description = "Weekly-ish updates during a factory order. Sets expectations, reduces 'where's my home?' calls."
  t.category = "factory_order"
  t.vertical = "manufactured_home"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Contact", "filter_tree" => {} }
  t.goal_config_template = { "primary_goal" => "deal_stage_advanced" }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[tue wed thu], "hour_start" => 10, "hour_end" => 16 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Your home is in production — week 1 update", "preheader" => "Order confirmed at factory",
      "body_blocks" => [text_block("<p>{{first_name}}, your factory order is confirmed. The factory begins frame and floor assembly this week. We'll send you a build update most weeks until delivery.</p>"), footer_block] },
    { "wait_days" => 14, "subject" => "Week 3: walls and exterior", "preheader" => "What's happening this week",
      "body_blocks" => [text_block("<p>Walls are up, exterior sheathing this week. Insulation and electrical rough-in next.</p>"), footer_block] },
    { "wait_days" => 14, "subject" => "Week 5: interiors taking shape", "preheader" => "Cabinetry, drywall, paint",
      "body_blocks" => [text_block("<p>Drywall is in. Cabinetry installs this week. Paint and trim next.</p>"), footer_block] },
    { "wait_days" => 14, "subject" => "Week 7: flooring and fixtures", "preheader" => "The home is starting to look like a home",
      "body_blocks" => [text_block("<p>Flooring and fixtures going in this week. Final QA inspection in 2 weeks.</p>"), footer_block] },
    { "wait_days" => 14, "subject" => "Week 9: factory QA + delivery scheduling", "preheader" => "Almost there",
      "body_blocks" => [text_block("<p>Factory QA passed. We're scheduling delivery and site set. Expect a call from us this week to confirm dates.</p>"), button_block("Confirm delivery window", "{{portal_url}}"), footer_block] },
    { "wait_days" => 14, "subject" => "Week 11: pre-delivery checklist", "preheader" => "Site prep status and walk-through",
      "body_blocks" => [text_block("<p>Almost there. Final pre-delivery checklist below — utilities ready, foundation ready, access cleared.</p>"), button_block("View pre-delivery checklist", "{{portal_url}}"), footer_block] }
  ]
end

# ============================================================
# 8. post-purchase-welcome-mh (post-purchase — 4-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "post-purchase-welcome-mh", company_id: nil) do |t|
  t.name = "MH Post-Purchase Welcome (4-step homeowner)"
  t.description = "Post-keys welcome series. Warranty registration, settling-in tips, referral and review asks."
  t.category = "post_purchase"
  t.vertical = "manufactured_home"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Contact", "filter_tree" => {} }
  t.goal_config_template = { "primary_goal" => "form_submitted", "additional_goals" => %w[replied unit_sold] }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu fri], "hour_start" => 10, "hour_end" => 18 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Welcome home, {{first_name}}", "preheader" => "Register your warranty",
      "body_blocks" => [text_block("<p>Welcome home, {{first_name}}!</p><p>First step: register your warranty so it's on file with the manufacturer. Takes 3 minutes.</p>"), button_block("Register warranty", "{{warranty_url}}"), footer_block] },
    { "wait_days" => 7, "subject" => "Settling in?", "preheader" => "First-month maintenance tip",
      "body_blocks" => [text_block("<p>One thing first-time MH owners often miss: walk the perimeter monthly during the first year and check for settling. Small adjustments now beat bigger ones later.</p>"), footer_block] },
    { "wait_days" => 7, "subject" => "Know someone else looking?", "preheader" => "Referral bonus",
      "body_blocks" => [text_block("<p>If you know anyone else thinking about buying, send them our way. We give you a referral bonus when they close.</p>"), button_block("Refer a friend", "{{referral_url}}"), footer_block] },
    { "wait_days" => 16, "subject" => "How are we doing?", "preheader" => "30-day review",
      "body_blocks" => [text_block("<p>30 days in. How are we doing? If we earned it, leave us a review. If something's off, reply and we'll fix it.</p>"), button_block("Leave a review", "{{review_url}}"), footer_block] }
  ]
end

# ============================================================
# 9. land-prep-checklist (land prep education — 5-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "land-prep-checklist", company_id: nil) do |t|
  t.name = "Land Prep Checklist (5-step educational)"
  t.description = "Walks owner-land buyers through site prep, permits, utilities, foundation, and delivery prep."
  t.category = "land_prep"
  t.vertical = "manufactured_home"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Contact", "filter_tree" => {} }
  t.goal_config_template = { "primary_goal" => "form_submitted" }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu fri], "hour_start" => 9, "hour_end" => 17 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Site prep — what comes first", "preheader" => "Clearing, grading, drainage", "body_blocks" => [text_block("<p>Site prep starts with clearing and grading. The site has to be flat, well-drained, and accessible to the delivery truck. Most jurisdictions also require a soil test before foundation.</p>"), footer_block] },
    { "wait_days" => 9, "subject" => "Permits — your local checklist", "preheader" => "What you'll need", "body_blocks" => [text_block("<p>Permits vary by county. The usual list: building permit, electrical permit, plumbing permit, septic/sewer permit, manufactured home installation permit. Your dealership handles most of these — but you'll want to know which ones land on you.</p>"), footer_block] },
    { "wait_days" => 9, "subject" => "Utilities — water, power, septic, gas", "preheader" => "Plan ahead", "body_blocks" => [text_block("<p>Utilities are the slowest part of land prep. Power can take 6-12 weeks from initial request. Septic install is 2-4 weeks. Get utility companies on the calendar early.</p>"), footer_block] },
    { "wait_days" => 14, "subject" => "Foundation — pier and beam vs runner systems", "preheader" => "What we recommend", "body_blocks" => [text_block("<p>For most installations we recommend a runner foundation with engineered tie-downs. It's faster, stronger, and easier to inspect than traditional pier and beam.</p>"), footer_block] },
    { "wait_days" => 13, "subject" => "Delivery day prep", "preheader" => "What to do the week before", "body_blocks" => [text_block("<p>The week before delivery: clear access path (15 ft minimum, no overhead obstructions), confirm utility hookups are 1 ft from set point, and have an adult on site for the walkthrough.</p>"), button_block("Pre-delivery checklist PDF", "{{checklist_url}}"), footer_block] }
  ]
end

# ============================================================
# 10. re-engagement-cold-mh (re-engagement — 3-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "re-engagement-cold-mh", company_id: nil) do |t|
  t.name = "MH Re-engagement (3-step cold lead)"
  t.description = "For leads gone quiet for 60+ days. Fresh inventory, price drops, soft close-the-file ask."
  t.category = "re_engagement"
  t.vertical = "manufactured_home"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "status", "operator" => "equals", "value" => "cold" }] } }
  t.goal_config_template = { "primary_goal" => "replied", "additional_goals" => ["clicked"] }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[tue wed thu], "hour_start" => 10, "hour_end" => 18 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Quick check-in, {{first_name}}", "preheader" => "Fresh listings",
      "body_blocks" => [text_block("<p>{{first_name}}, it's been a minute. Here's what's fresh on the lot:</p>"), inventory_block, footer_block],
      "inventory_block_config" => { "mode" => "category_based", "max_units" => 6, "sort" => "newest", "fallback" => "skip_block" } },
    { "wait_days" => 7, "subject" => "Price drops you might want to see", "preheader" => "Recent reductions",
      "body_blocks" => [text_block("<p>A few homes you looked at have come down in price:</p>"), inventory_block, footer_block],
      "inventory_block_config" => { "mode" => "category_based", "max_units" => 6, "sort" => "price_low", "fallback" => "skip_block", "filter" => { "price_dropped" => true } } },
    { "wait_days" => 7, "subject" => "Should we close your file?", "preheader" => "No pressure either way",
      "body_blocks" => [text_block("<p>If you're still actively looking, just hit reply and I'll get back in touch. If life's changed and now isn't the time, no worries — I'll close out your file. Either way, good to hear from you.</p>"), footer_block] }
  ]
end

# ============================================================
# 11. rv-show-followup (RV event follow-up — 4-step)
# ============================================================
CampaignTemplate.find_or_create_by(slug: "rv-show-followup", company_id: nil) do |t|
  t.name = "RV Show Follow-up (4-step event)"
  t.description = "Post-show drip for RV buyers met at a trade show or open house. Day 3 has an inventory block."
  t.category = "event_followup"
  t.vertical = "rv"
  t.is_seeded = true
  t.is_active = true
  t.audience_hint = { "source_type" => "Lead", "filter_tree" => { "type" => "and", "children" => [{ "field" => "source", "operator" => "contains", "value" => "show" }] } }
  t.goal_config_template = { "primary_goal" => "replied", "additional_goals" => %w[deal_created clicked] }
  t.send_window_template = { "timezone" => "America/Chicago", "days" => %w[mon tue wed thu fri sat], "hour_start" => 9, "hour_end" => 18 }
  t.steps_template = [
    { "wait_days" => 0, "subject" => "Thanks for stopping by at the show, {{first_name}}", "preheader" => "Quick recap",
      "body_blocks" => [text_block("<p>Hi {{first_name}},</p><p>Thanks for stopping by our booth. You mentioned you were thinking about a {{rv_type}} — I'll send you a few options on the lot in a couple days.</p>"), footer_block] },
    { "wait_days" => 3, "subject" => "RVs we have on the lot right now", "preheader" => "Picked for you",
      "body_blocks" => [text_block("<p>Here are RVs on the lot that match what you told us at the show:</p>"), inventory_block, button_block("Browse all RVs", "{{public_inventory_url}}"), footer_block],
      "inventory_block_config" => { "mode" => "category_based", "max_units" => 6, "sort" => "best_match", "fallback" => "show_cta", "filter" => { "listing_type" => "rv" } } },
    { "wait_days" => 4, "subject" => "Financing on RVs", "preheader" => "Pre-qualify in 5 minutes",
      "body_blocks" => [text_block("<p>RV financing is similar to auto financing but the term is longer. Pre-qualifying takes about 5 minutes and is a soft pull — it doesn't hit your credit.</p>"), button_block("Pre-qualify", "{{prequalify_url}}"), footer_block] },
    { "wait_days" => 3, "subject" => "Coming back next year?", "preheader" => "If now's not the time",
      "body_blocks" => [text_block("<p>If now's not the time, we'll see you next year. If it is, hit reply and we'll set up a 15-minute call.</p>"), footer_block] }
  ]
end

puts "✅ Seeded #{CampaignTemplate.where(is_seeded: true).count} platform campaign templates"
