# frozen_string_literal: true

# Idempotent seeder: ~60 help articles across every user-facing module.
# Skips any article whose slug already exists.
#
# Run:  bin/rails runner tmp/seed_comprehensive_articles.rb

def resolve_module(key)
  Knowledge::Module.find_by(key: key) ||
    Knowledge::Module.find_by(key: key.to_s.sub(/s\z/, '')) ||
    Knowledge::EntityAlias.find_by(alias_name: key.to_s)&.then { |a| Knowledge::Module.find_by(key: a.canonical_key) }
end

ARTICLES = [
  # ================================================================ CRM / Leads
  {
    module_key: 'leads', slug: 'managing-leads', title: 'Managing Leads', article_type: 'guide',
    excerpt: 'Browse, filter, search, and work your leads list day-to-day.',
    content: <<~MD
      ## Overview
      The Leads module is your inbox of prospective customers. It opens with stats tiles, a filterable list, and quick actions that keep leads moving.

      ## Getting There
      1. Click **CRM & Sales** in the left sidebar
      2. Click **Prospecting**
      3. The leads list appears with stats tiles at the top

      ## The Leads List
      ### Stats tiles
      Four tiles across the top show totals by status — **New**, **Contacted**, **Qualified**, and **Lost**. Click any tile to filter the list to that status.

      ### Searching
      Use the search bar to find leads by name, email, phone, or company. Results narrow as you type.

      ### Filtering
      Click **Filters** to narrow by owner, source, tag, created date, or assignment. Save the current filter set as a **View** for one-click reuse later.

      ### Bulk actions
      Select multiple rows with the checkboxes, then use the action bar to reassign owners, apply tags, change status, or export.

      ## Opening a Lead
      Click any row to open the lead detail page. From there you can:
      - Add notes and activities
      - Send email or SMS
      - Schedule follow-ups
      - Convert the lead to a contact or deal

      ## Tips & Best Practices
      > **Tip:** Assign every lead an owner and a source — unassigned leads get forgotten, and unknown sources poison your marketing ROI reports.

      ## Related Features
      - Converting leads to contacts or deals
      - Lead sources and tracking
      - Importing leads in bulk
    MD
  },
  {
    module_key: 'leads', slug: 'lead-conversion', title: 'Converting a Lead to a Contact or Deal', article_type: 'guide',
    excerpt: 'Promote qualified leads to contacts, accounts, and deals without re-entering their information.',
    content: <<~MD
      ## Overview
      When a lead becomes a real opportunity, converting them moves their information into the rest of the platform — contacts, accounts, and deals. Every piece of history (notes, activities, communications) follows along.

      ## Getting There
      1. Click **CRM & Sales** > **Prospecting** in the sidebar
      2. Click a lead row to open their detail page

      ## Step-by-Step Guide
      ### Run the conversion
      1. Click **Convert** in the top-right of the lead detail page
      2. In the dialog, choose what to create:
         - **Contact** — recommended. The lead's name, email, and phone pre-fill.
         - **Account** — if the lead is from a business, pick an existing account or create one.
         - **Deal** — optional. Set deal name, stage, amount, and close date.
      3. Review the field mapping. Custom fields on the lead map to matching custom fields on the new records.
      4. Click **Convert**

      ### What changes
      - The lead is archived with status **Won**
      - A new contact appears in **Contacts**
      - If you created a deal, it appears in **Sales Deals** at the chosen stage
      - Notes, activities, and communications copy to the contact

      ## Tips & Best Practices
      > **Tip:** Convert when the lead is clearly qualified — scheduled a showing, requested a quote, or agreed on a price range. Converting too early pollutes your contacts with unqualified prospects.

      > **Note:** Nurture sequences running against the lead stop automatically on conversion.

      ## Related Features
      - Managing leads
      - Using the sales pipeline
    MD
  },
  {
    module_key: 'leads', slug: 'import-export-leads', title: 'Importing and Exporting Leads', article_type: 'guide',
    excerpt: 'Bulk-load leads from a CSV or export your list for offline analysis.',
    content: <<~MD
      ## Overview
      Import lets you bring in hundreds of leads from a trade show or list broker in one go. Export dumps your current filtered view to CSV for analysis in Excel, Google Sheets, or BI tools.

      ## Getting There
      1. Click **CRM & Sales** > **Prospecting** in the sidebar
      2. Click **Import** or **Export** in the top-right of the page header

      ## Importing Leads
      1. Click **Import** in the page header
      2. Click **Download Sample** to see the expected CSV columns
      3. Prepare your CSV with those columns (extras are OK — just ignored)
      4. Click **Upload File** and choose your CSV
      5. On the mapping screen, adjust any columns that didn't auto-match
      6. Review the preview — rows with errors surface here so you can fix them first
      7. Click **Start Import**

      Rows commit in the background. You'll get a notification when it finishes, plus an error report for any rows that failed.

      ## Exporting Leads
      1. Apply any filters you want (status, owner, date range)
      2. Click **Export** in the page header
      3. Choose **CSV** or **Excel**
      4. The file downloads with every visible column

      ## Tips & Best Practices
      > **Tip:** Duplicates are detected by email or phone. Re-importing the same file updates existing leads instead of creating duplicates.

      > **Note:** Large imports (5,000+ rows) are throttled — they still finish, just in batches over a few minutes.

      ## Related Features
      - Managing leads
      - Lead sources and tracking
    MD
  },
  {
    module_key: 'leads', slug: 'lead-sources', title: 'Lead Sources and Tracking', article_type: 'guide',
    excerpt: 'Set up lead sources so you can measure marketing ROI and route leads automatically.',
    content: <<~MD
      ## Overview
      Lead sources tell you where each lead came from — walk-in, referral, website, trade show, or a specific marketing campaign. Accurate sources are the foundation of marketing ROI reports.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Communications** tab
      3. Scroll to the **Lead Sources** section

      ## Step-by-Step Guide
      ### Adding a source
      1. Click **Add Source**
      2. Enter the source name (e.g. "Facebook — Spring Campaign")
      3. Set the category (Paid, Organic, Referral, Other)
      4. Optionally, set a default owner so leads from this source auto-assign
      5. Click **Save**

      ### Editing a source
      1. Click the source name in the list
      2. Update fields and click **Save**
      3. Existing leads keep their original source — only new leads use the edited values

      ### Deactivating a source
      When you stop running a campaign, click the toggle to deactivate instead of deleting. Historical reports still reference the source; deactivation just hides it from the picker on new leads.

      ## Using Sources
      - **On leads** — the Source field on every new lead picks from this list
      - **On public forms** — intake forms can pre-set a source via URL param
      - **In reports** — the Source ROI report shows lead volume, conversion, and won value per source

      ## Tips & Best Practices
      > **Tip:** Keep your source list tight — 15-30 total. Too many dilutes reporting; too few loses granularity.

      ## Related Features
      - Managing leads
      - Running reports
    MD
  },

  # ================================================================= Sales Deals
  {
    module_key: 'deals', slug: 'sales-pipeline', title: 'Using the Sales Pipeline', article_type: 'guide',
    excerpt: 'Kanban pipeline view with drag-and-drop stage changes for every open deal.',
    content: <<~MD
      ## Overview
      The sales pipeline is a kanban-style board showing every open deal grouped by stage. It's the fastest way to see where your sales effort is — and where it's stuck.

      ## Getting There
      1. Click **CRM & Sales** > **Sales Deals** in the sidebar
      2. Click the **Pipeline** tab (or toggle) at the top of the page
      3. Deals render as cards, one column per stage

      ## Step-by-Step Guide
      ### Moving a deal between stages
      1. Click and hold a deal card
      2. Drag it to the destination column
      3. Drop to commit the stage change

      The change saves immediately, creates an activity entry, and fires any workflow rules configured for that stage transition.

      ### Filtering the board
      Use the header filters to scope by owner, account, source, or date range. Useful in team mode when you want just your own deals.

      ### Per-column analytics
      Each column header shows:
      - **Count** — deals in stage
      - **Total value** — sum of amounts
      - **Avg. age** — how long deals sit in that stage
      - **Conversion rate** — % that advance vs stall

      Click a column header to drill into that stage's deals in list view.

      ## Tips & Best Practices
      > **Tip:** Stale deals (30+ days with no activity) flag red. That's your red-flag queue for weekly pipeline review.

      > **Note:** Only open deals show on the board. Won and Lost deals drop off automatically — see them under the **All Deals** tab or in reports.

      ## Related Features
      - Managing deal stages
      - Deal analytics and forecasting
    MD
  },
  {
    module_key: 'deals', slug: 'deal-stages', title: 'Managing Deal Stages', article_type: 'guide',
    excerpt: 'Customize your pipeline stages and set win probabilities for forecasting.',
    content: <<~MD
      ## Overview
      Deal stages define your pipeline — the steps a deal moves through from first interest to closed-won. Customize them to match how your dealership actually sells.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **CRM** tab (or **Pipeline** section)
      3. Click **Deal Stages**

      ## Step-by-Step Guide
      ### Adding a stage
      1. Click **Add Stage**
      2. Enter the stage name (e.g. "Credit Application")
      3. Set the **Type** — Open, Won, or Lost
      4. Set the **Probability** (0-100%) — used for weighted forecasts
      5. Pick a color for the kanban column
      6. Click **Save**

      ### Reordering stages
      Drag stages up or down to change their pipeline order. Existing deals keep their stage — only the display order changes.

      ### Renaming a stage
      Click the stage name, edit, and save. Every deal currently in that stage keeps the new name.

      ### Deactivating a stage
      If you retire a stage, use the **Active** toggle instead of deleting. Historical deals retain the stage reference; deactivation just hides it from the pipeline picker on new deals.

      ## Tips & Best Practices
      > **Tip:** 5-7 stages is the sweet spot. Fewer loses useful resolution; more makes reps hesitate on every move.

      > **Note:** The final Won and Lost stages can't be deleted, only renamed — the system needs them to calculate pipeline metrics.

      ## Related Features
      - Using the sales pipeline
      - Deal analytics and forecasting
    MD
  },
  {
    module_key: 'deals', slug: 'deal-analytics', title: 'Deal Analytics and Forecasting', article_type: 'guide',
    excerpt: 'Charts and metrics for pipeline health, conversion rates, and revenue forecasting.',
    content: <<~MD
      ## Overview
      The Analytics tab in Sales Deals turns your raw pipeline data into charts and metrics — pipeline health, conversion rates, velocity, and weighted revenue forecasts.

      ## Getting There
      1. Click **CRM & Sales** > **Sales Deals** in the sidebar
      2. Click the **Analytics** tab

      ## Step-by-Step Guide
      ### Pipeline health
      The top section shows:
      - Total open deal value
      - Deals per stage (funnel chart)
      - Weighted forecast (each stage's value × its win probability)

      ### Conversion rates
      The conversion chart shows % of deals advancing from each stage to the next. Sticky stages jump out.

      ### Velocity
      Average days per stage. Slow stages are coaching opportunities.

      ### Forecast
      The forecast section projects closed-won revenue for the current and next quarter:
      - **Commit** — high-probability deals (80%+)
      - **Best case** — all open deals at their weighted probability
      - **Gap** — what you need to add to hit target

      ### Per-rep breakdown
      Scroll to the **By Rep** section to compare pipelines across salespeople. Click a rep name to drill into their deals.

      ## Filtering
      Date range, location, and rep filters at the top scope every chart on the page.

      ## Tips & Best Practices
      > **Tip:** Review the forecast weekly. If the gap to target is big, it's earlier-stage deals you need, not a push on late-stage.

      ## Related Features
      - Using the sales pipeline
      - Running reports
    MD
  },

  # ================================================================== Contacts
  {
    module_key: 'contacts', slug: 'managing-contacts', title: 'Managing Contacts', article_type: 'guide',
    excerpt: 'Create, edit, search, and link contacts to accounts and deals.',
    content: <<~MD
      ## Overview
      Contacts are individual people in your CRM. Every deal, invoice, agreement, and communication traces back to one or more contacts.

      ## Getting There
      1. Click **CRM & Sales** in the sidebar
      2. Click **Contacts**

      ## Step-by-Step Guide
      ### Adding a contact
      1. Click **Add Contact** in the top-right
      2. Fill in name, email, phone, address
      3. Optionally, link to an **Account** (business)
      4. Click **Save**

      ### Linking to an account
      On the contact detail page, the **Account** field connects the contact to a business. One contact can belong to multiple accounts — useful for consultants and brokers.

      ### Inline editing
      On the detail page, click any field to edit it in place. Changes save automatically and log an activity entry.

      ### Tags and custom fields
      Tags categorize contacts loosely. Filter and segment by tag. Custom fields (configured in **Company Settings > Custom Fields**) add structured data like referral source, customer tier, or birthday.

      ### Merging duplicates
      From the contacts list, click **Dedupe** to find potential duplicates by email, phone, or name. Review and merge to keep history intact.

      ## Tips & Best Practices
      > **Tip:** Keep email addresses current — it drives open tracking, nurture sequences, and document delivery. A stale email quietly breaks most of the platform.

      ## Related Features
      - Contact communication history
      - Managing accounts
    MD
  },

  # ================================================================== Accounts
  {
    module_key: 'accounts', slug: 'managing-accounts', title: 'Managing Accounts', article_type: 'guide',
    excerpt: 'Track business accounts — customers, prospects, partners, and vendors.',
    content: <<~MD
      ## Overview
      Accounts represent businesses and organizations. Use accounts when you deal with companies rather than individuals — commercial buyers, other dealers, property managers, or vendors you pay.

      ## Getting There
      1. Click **CRM & Sales** in the sidebar
      2. Click **Accounts**

      ## Step-by-Step Guide
      ### Adding an account
      1. Click **Add Account**
      2. Fill in name, type, website, phone, address
      3. Pick a rating and owner
      4. Click **Save**

      ### Linking contacts
      On the account detail page, open the **Contacts** tab and click **Link Contact**. Either pick an existing contact or create a new one. A contact can be linked to multiple accounts.

      ### Related records
      Each account surfaces:
      - **Deals** — every open and closed opportunity
      - **Invoices** — billing history
      - **Agreements** — contracts signed
      - **Communications rollup** — email and SMS across all linked contacts

      Click any related row to jump to its detail page.

      ### Searching and filtering
      The account list supports search by name, email, phone, or website. Filters narrow by type, rating, owner, or location. Save common filter sets as **Views**.

      ## Tips & Best Practices
      > **Tip:** Set an **owner** on every account — single-point-of-contact accountability keeps accounts from falling through the cracks.

      > **Note:** The **Convert to Customer** button on prospects flips their type and fires any onboarding workflows you've configured.

      ## Related Features
      - Account types and categories
      - Managing contacts
    MD
  },
  {
    module_key: 'accounts', slug: 'account-types', title: 'Account Types and Categories', article_type: 'guide',
    excerpt: 'When to use Customer, Prospect, Partner, and Vendor account types.',
    content: <<~MD
      ## Overview
      Every account has a type that drives default filters, routing rules, and reporting. Pick the right one up front — changing it later is easy, but stale types muddle your metrics.

      ## Getting There
      1. Click **CRM & Sales** > **Accounts** in the sidebar
      2. Open an account detail page to change its type, or use **Add Account** to set it on creation

      ## The Four Types

      ### Customer
      Businesses that have bought from you. Drive revenue reports, renewal reminders, and customer satisfaction flows. Convert prospects to customers via the **Convert to Customer** button once a deal closes won.

      ### Prospect
      Potential customers you're actively working. Live in your CRM pipeline alongside leads but at the business level. Often linked to one or more open deals.

      ### Partner
      Referrers, affiliates, dealer network members. Track referral volume and referral fees owed. Partners often don't buy from you directly but drive revenue indirectly.

      ### Vendor
      Suppliers, service providers, and anyone you pay. Track AP-side relationships — purchase orders, parts suppliers, outside contractors. Vendors typically don't show up in sales reports but drive AP reports.

      ## Changing a type
      On the account detail page, click the **Type** field and pick a new value. The account immediately re-routes in filters and reports. Historical records (past deals, invoices) keep their timestamps — the type change is forward-looking.

      ## Tips & Best Practices
      > **Tip:** Use tags for finer segmentation within a type. "VIP customer", "Platinum partner", "Preferred vendor" — tags let you cross-cut without inflating the type list.

      ## Related Features
      - Managing accounts
      - Tags management
    MD
  },

  # ==================================================================== Quotes
  {
    module_key: 'quotes', slug: 'creating-quotes', title: 'Creating and Sending Quotes', article_type: 'guide',
    excerpt: 'Build a formal price quote, add line items, and email it to the customer.',
    content: <<~MD
      ## Overview
      Quotes formalize pricing before a deal closes. They give customers something concrete to compare and approve.

      ## Getting There
      1. Click **CRM & Sales** in the sidebar
      2. Click **Quotes**

      ## Step-by-Step Guide
      ### Creating a quote
      1. Click **Create Quote** in the top-right
      2. Pick a **customer** (contact or account)
      3. Optionally attach to an existing **deal**
      4. Click **Add Line Item** for each item — inventory, parts, labor, or free-text
      5. Set quantity, unit price, and any line-level discount
      6. Set the **Valid Until** date
      7. Click **Save**

      ### Sending to the customer
      1. Open the saved quote
      2. Click **Send**
      3. Choose **Email** — a PDF attaches plus a secure public link the customer can open on any device
      4. Customize the email subject and body, then click **Send**

      The customer gets a view-and-accept page. Acceptance flips the quote status to **Accepted** and notifies you.

      ### Adding discounts
      Line items support percentage or dollar discounts per-item. A quote-level discount applies proportionally across all items and shows as a separate line on the PDF.

      ## Tips & Best Practices
      > **Tip:** Always set a **Valid Until** date. Open-ended quotes get used as leverage months later and erode your margin.

      ## Related Features
      - Quote templates
      - Public quote links
      - Deal pipeline
    MD
  },
  {
    module_key: 'quotes', slug: 'quote-templates', title: 'Quote Templates', article_type: 'guide',
    excerpt: 'Build reusable quote templates for common configurations so you stop rebuilding from scratch.',
    content: <<~MD
      ## Overview
      Quote templates let you save a fully-built quote (line items, pricing, terms, disclaimers) and reuse it for new customers with a single click. Perfect for standard configurations like "New Unit + Prep Package" or "Annual Service Plan".

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Quotes** tab (or **Templates** section)
      3. Click **Quote Templates**

      ## Step-by-Step Guide
      ### Creating a template
      1. Click **New Template**
      2. Enter a template name (e.g. "Standard Delivery Package")
      3. Add line items with default quantities and prices
      4. Set default terms and valid-until window
      5. Write a default customer message
      6. Click **Save**

      ### Using a template
      1. In **Quotes**, click **Create Quote**
      2. In the new-quote dialog, pick your template from the **Start From** dropdown
      3. Select the customer
      4. Review and adjust — line items, quantities, and pricing are editable per quote
      5. Save and send as usual

      ### Editing a template
      Editing a template does NOT retroactively change quotes already sent. Only new quotes created from the template pick up the changes.

      ### Archiving a template
      When a template retires, toggle it to **Inactive** rather than deleting. Old quotes that reference it keep their history intact.

      ## Tips & Best Practices
      > **Tip:** Build templates for your top 5-10 common quote shapes. It cuts quote-creation time from 10 minutes to under 1.

      ## Related Features
      - Creating and sending quotes
    MD
  },
  {
    module_key: 'quotes', slug: 'public-quote-links', title: 'Public Quote Links', article_type: 'guide',
    excerpt: 'How customers view, approve, and reject your quotes online — no login required.',
    content: <<~MD
      ## Overview
      Every quote has a secure public URL. Customers open it on any device, review, print, and accept or reject online. No login, no account, no friction.

      ## Getting There
      Any saved quote has a **Public Link** button available:
      1. Click **CRM & Sales** > **Quotes** in the sidebar
      2. Open any quote
      3. Click **Share** or **Public Link** in the top-right

      ## What the Customer Sees
      The public page shows:
      - Your logo, colors, and brand
      - Every line item with descriptions, quantities, and prices
      - Subtotals, discounts, taxes, and total
      - A printable PDF download button
      - **Accept** and **Reject** buttons

      ## When They Click Accept
      - Quote status flips to **Accepted**
      - You get an in-app notification and email
      - The linked deal (if any) auto-advances if workflow rules are configured
      - An audit entry records the acceptance with IP address and timestamp

      ## When They Click Reject
      - They're prompted to pick a reason (Too expensive, Wrong configuration, Going with competitor, Other)
      - Quote status flips to **Rejected**
      - You get notified with the reason — helpful for objection-handling coaching

      ## Security
      Links use cryptographically-random tokens — unguessable. You can regenerate a link from the quote's **Share** menu if it gets forwarded beyond the intended recipient.

      ## Tips & Best Practices
      > **Tip:** Send the link via both email AND SMS. SMS open rates crush email.

      > **Note:** Expired quotes (past Valid Until date) show a "This quote has expired" message and disable the accept button.

      ## Related Features
      - Creating and sending quotes
    MD
  },

  # ================================================================ Inventory
  {
    module_key: 'inventory', slug: 'managing-inventory', title: 'Managing Inventory', article_type: 'guide',
    excerpt: 'Add and update units, homes, and vehicles — statuses, specs, and pricing.',
    content: <<~MD
      ## Overview
      Inventory tracks every sellable unit — vehicles, trailers, and manufactured homes. Photos, pricing, specs, and location all live here. Sold status auto-syncs when a deal closes.

      ## Getting There
      1. Click **Inventory & Operations** in the sidebar
      2. Click **Inventory**

      ## Step-by-Step Guide
      ### Adding a unit
      1. Click **Add Unit** in the top-right
      2. Fill in stock number (auto-generated if blank), year/make/model, VIN/serial
      3. Set the location, cost, MSRP, and asking price
      4. Click **Save** — the unit appears as **Available**

      ### Editing details
      On the detail page, click any field to edit inline. Changes save immediately and write an activity entry. Inline editing is available across all tabs: Details, Specs, Pricing, Location, Media, Seller.

      ### Status tracking
      Every unit has a status that drives availability:
      - **Available** — on the lot, ready to sell
      - **Sold** — deal closed
      - **On Order** — ordered from manufacturer
      - **In Transit** — on its way to the lot
      - **Service** — temporarily out for reconditioning

      Statuses flip automatically when linked to a deal. Manual overrides are available on the detail page.

      ### Searching and filtering
      The list supports filters for status, type, manufacturer, location, floor plan, and price range. Save filter combinations as **Views**.

      ## Tips & Best Practices
      > **Tip:** Link units to manufacturer feeds so specs, options, and floor plans stay in sync — no manual re-entry when models update.

      ## Related Features
      - Inventory photos and documents
      - Land management
      - Vehicle detail page
    MD
  },
  {
    module_key: 'inventory', slug: 'inventory-media', title: 'Inventory Photos and Documents', article_type: 'guide',
    excerpt: 'Upload photos, videos, and documents — drive the brochure, website, and public listing visuals.',
    content: <<~MD
      ## Overview
      The Media tab on every inventory unit holds photos, videos, and documents. These feed automatically into brochures, the public website, syndicated listings, and the buyer portal.

      ## Getting There
      1. Click **Inventory & Operations** > **Inventory** in the sidebar
      2. Open any unit's detail page
      3. Click the **Media** tab

      ## Step-by-Step Guide
      ### Uploading photos
      1. Drag-and-drop photos onto the upload zone (or click to browse)
      2. Multiple files upload in parallel
      3. Drag to reorder — the first photo is the hero used everywhere

      Recommended: 1920×1080 or larger, JPG or PNG, under 10 MB each. The system auto-generates thumbnails.

      ### Videos
      Paste a YouTube or Vimeo URL into the **Add Video** field. The video embeds on the public listing and brochure pages.

      ### Documents
      Documents (PDFs, spec sheets, warranty forms) upload the same way as photos but show in the **Documents** section below media. Useful for buyer-facing spec sheets and manuals.

      ### Deleting
      Click the trash icon on any media item. Soft-deletes for 30 days — restore from the **Trash** view if you need it back.

      ## Public Visibility
      Photos and documents marked **Public** show on:
      - The public listing page
      - Your dealer website (if published)
      - Customer brochures
      - Syndicated feeds (RV Trader, MH Village, etc.)

      Internal-only media (cost docs, repair photos) uploaded with the **Private** flag only show to logged-in users.

      ## Tips & Best Practices
      > **Tip:** Lead with exterior hero photos, then interior rooms, then detail shots. Public listing click-through is directly tied to photo quality.

      ## Related Features
      - Managing inventory
      - Creating brochures
    MD
  },
  {
    module_key: 'inventory', slug: 'land-management', title: 'Land Management', article_type: 'guide',
    excerpt: 'Track land parcels, lots, and sites alongside your inventory.',
    content: <<~MD
      ## Overview
      The Land Management tab in Inventory tracks land parcels, lots, and sites — the real estate side of a manufactured-home sale. Keeps land inventory, costs, and sale status in the same system as your units.

      ## Getting There
      1. Click **Inventory & Operations** > **Inventory** in the sidebar
      2. Click the **Land Management** tab at the top of the page

      ## Step-by-Step Guide
      ### Adding a parcel
      1. Click **Add Parcel**
      2. Enter parcel number, address, and GPS coordinates (or paste a Google Maps link)
      3. Set acreage, zoning, and utilities status (water, sewer, electric, gas)
      4. Enter acquisition cost and asking price
      5. Upload site photos and the plat map
      6. Click **Save**

      ### Linking to a unit
      From a parcel detail page, click **Link Unit** to pair it with a home in inventory. Customers can then buy both together as a single transaction.

      ### Status tracking
      - **Raw** — undeveloped land
      - **Prepared** — grading and pad done
      - **Available** — ready for a unit
      - **Occupied** — unit placed
      - **Sold** — parcel and (optionally) unit sold together

      ### Utilities and inspections
      Each parcel has fields for water, sewer, electric, gas, and septic status. Attach inspection reports and permits as documents.

      ## Tips & Best Practices
      > **Tip:** For parcels you're actively selling, upload the plat map as the first document — buyers ask for it immediately.

      > **Note:** If you deal primarily with unit sales (no land), you can hide the Land Management tab via **Company Settings > General > Feature Toggles**.

      ## Related Features
      - Managing inventory
    MD
  },

  # =================================================================== Parts
  {
    module_key: 'parts', slug: 'managing-parts', title: 'Managing Parts Inventory', article_type: 'guide',
    excerpt: 'Add parts, track stock levels, set reorder thresholds, and manage SKUs.',
    content: <<~MD
      ## Overview
      Parts tracks your service-side inventory — filters, belts, specialty hardware, everything needed for repairs and warranty work. Tight parts management keeps service tickets moving and prevents stockouts.

      ## Getting There
      1. Click **Inventory & Operations** in the sidebar
      2. Click **Parts & Supplies**

      ## Step-by-Step Guide
      ### Adding a part
      1. Click **Add Part** in the top-right
      2. Enter SKU (your internal part number)
      3. Enter MPN (manufacturer part number) for cross-referencing
      4. Fill in description, cost, and sell price
      5. Set the **Reorder Threshold** — the stock level that triggers low-stock alerts
      6. Pick a **Default Supplier** to pre-populate purchase orders
      7. Click **Save**

      ### Tracking stock
      The **Stock** tab on a part shows current quantity on hand, broken down by bin. Stock changes via:
      - **Receiving** — PO line items marked received
      - **Consumption** — parts used on a service ticket
      - **Adjustments** — manual fixes for counts, damage, shrinkage
      - **Transfers** — moving stock between bins

      ### Low-stock alerts
      When a part drops below its reorder threshold, the list flags it red and the dashboard shows a low-stock alert. Optionally, auto-generate a draft PO when thresholds trip (configured in **Parts Settings**).

      ### Kits
      Group parts that are always used together (e.g. "Awning Repair Kit = awning + brackets + hardware") so techs can add the whole kit to a ticket in one click.

      ## Tips & Best Practices
      > **Tip:** Use the **Turnover Report** (in Reports) to find slow-moving parts tying up cash.

      ## Related Features
      - Warehouse bins
      - Purchase orders
      - Managing suppliers
    MD
  },
  {
    module_key: 'parts', slug: 'purchase-orders', title: 'Purchase Orders', article_type: 'guide',
    excerpt: 'Create POs, send them to suppliers, and receive parts when shipments arrive.',
    content: <<~MD
      ## Overview
      Purchase Orders (POs) are how you buy parts from suppliers. Every PO tracks what was ordered, what was received, and what you paid — cleanly and auditably.

      ## Getting There
      1. Click **Inventory & Operations** > **Parts & Supplies** in the sidebar
      2. Click the **Purchase Orders** tab

      ## Step-by-Step Guide
      ### Creating a PO
      1. Click **Create PO**
      2. Pick a **supplier** — default payment terms and lead time prefill
      3. Add line items by picking parts from your catalog
      4. Quantity and unit cost default from the part record; override as needed
      5. Add shipping and tax lines
      6. Click **Save** — status is **Draft**

      ### Sending the PO
      Click **Send** to email the PO (with attached PDF) to the supplier, or mark as sent by other means (phone, their portal). Status flips to **Sent** with an audit timestamp.

      ### Receiving inventory
      1. Open the PO when the shipment arrives
      2. Click **Receive**
      3. For each line, enter received quantity — partial shipments are OK
      4. Pick the **bin** where stock goes
      5. Click **Confirm Receiving**

      Stock-on-hand increments immediately. When all lines are fully received, status flips to **Received**.

      ### Tracking shipments
      Add tracking numbers on the PO's **Shipments** tab. With carrier integrations (FedEx, UPS) enabled, status updates sync automatically.

      ## Tips & Best Practices
      > **Tip:** Use **PO templates** for repeat orders — one click creates the PO with your standard parts and quantities.

      > **Note:** Close a PO when you're done — no more receiving allowed, but history preserved.

      ## Related Features
      - Managing parts inventory
      - Managing suppliers
    MD
  },
  {
    module_key: 'parts', slug: 'warehouse-bins', title: 'Warehouse Bins', article_type: 'guide',
    excerpt: 'Organize parts by bin location so techs grab the right part on the first try.',
    content: <<~MD
      ## Overview
      Bins are physical locations where parts live — shelves, drawers, aisles, or zones in your warehouse. Bin locations print on pick sheets so techs don't waste time hunting for parts.

      ## Getting There
      1. Click **Inventory & Operations** > **Parts & Supplies** in the sidebar
      2. Click the **Bins** tab

      ## Step-by-Step Guide
      ### Adding a bin
      1. Click **Add Bin**
      2. Enter the bin code (e.g. "A-12-03" for Aisle A, Row 12, Slot 3)
      3. Add a description ("Oil filters and fluid")
      4. Optionally, tag the bin with a location if you have multiple warehouses
      5. Click **Save**

      ### Assigning parts to bins
      From a part's detail page:
      1. Open the **Bins** tab
      2. Click **Add to Bin**
      3. Pick the bin and enter the quantity stored there
      4. Click **Save**

      A single part can live in multiple bins (e.g. bulk stock in one, pick stock in another).

      ### Receiving into a bin
      When receiving a PO, pick the bin for each line item. Stock increments for that specific bin. Quantities on hand across all bins aggregate into the part's total.

      ### Moving stock between bins
      On a part's **Stock** tab, click **Transfer**:
      1. Enter source bin and destination bin
      2. Enter quantity to move
      3. Click **Confirm**

      ### Printing pick sheets
      Pick sheets print the bin code next to every part, letting techs grab parts in warehouse-walk order instead of zig-zagging.

      ## Tips & Best Practices
      > **Tip:** Use a consistent bin naming convention (e.g. aisle-row-slot) across the whole warehouse — makes new hires productive in hours, not weeks.

      ## Related Features
      - Managing parts inventory
    MD
  },
  {
    module_key: 'parts', slug: 'managing-suppliers', title: 'Managing Suppliers', article_type: 'guide',
    excerpt: 'Add suppliers, view their parts and POs, and track payment terms.',
    content: <<~MD
      ## Overview
      Suppliers are the vendors you buy parts and inventory from. Each supplier holds contact info, payment terms, and a complete history of POs and received stock.

      ## Getting There
      1. Click **Inventory & Operations** > **Parts & Supplies** in the sidebar
      2. Click the **Suppliers** tab

      ## Step-by-Step Guide
      ### Adding a supplier
      1. Click **Add Supplier**
      2. Enter name, primary contact, phone, email, and website
      3. Set default **payment terms** (Net 30, Net 60, COD, etc.)
      4. Set default **lead time** in days — used for reorder forecasting
      5. Optionally upload their W-9 or other tax docs
      6. Click **Save**

      ### Supplier detail page
      Each supplier's page surfaces:
      - **Parts** — every part where they're the default supplier
      - **Purchase Orders** — all POs you've sent them (draft, sent, received, closed)
      - **AP Ledger** — outstanding balances and payment history
      - **Documents** — contracts, tax forms, product sheets

      ### Creating a PO for this supplier
      From the supplier detail page, click **Create PO** — the supplier pre-fills and their default parts list is available in one click.

      ### Deactivating a supplier
      When you stop doing business, toggle the supplier to **Inactive** rather than deleting. Historical POs and payment records stay intact; the supplier just hides from the picker on new POs.

      ## Tips & Best Practices
      > **Tip:** Track supplier performance — on-time delivery %, price trend, quality issues — as custom fields. After a year of data, you'll see which suppliers actually deserve more business.

      ## Related Features
      - Managing parts inventory
      - Purchase orders
    MD
  },

  # ================================================================= Invoices
  {
    module_key: 'invoices', slug: 'creating-invoices', title: 'Creating Invoices', article_type: 'guide',
    excerpt: 'Build invoices with line items, taxes, and payment terms.',
    content: <<~MD
      ## Overview
      Invoices capture money owed to you. Every invoice has line items, totals, payment terms, and a sendable PDF plus a secure online payment link.

      ## Getting There
      1. Click **Finance & Agreements** in the sidebar
      2. Click **Invoices**

      ## Step-by-Step Guide
      ### Creating an invoice
      1. Click **Create Invoice** in the top-right
      2. Optionally start from a won deal — line items and customer prefill
      3. Pick a **customer** (contact or account) if not starting from a deal
      4. Add line items — inventory, parts, labor, or free-text
      5. Each line has description, quantity, unit price, and discount
      6. Tax calculates automatically from the customer or location tax rate
      7. Set **payment terms** (Net 30 default)
      8. Click **Save** — status is **Draft**

      ### Editing line items
      Click any line to edit inline. Totals recalculate on each change. Drag line rows to reorder.

      ### Applying discounts
      Per-line discounts go on the line's discount field. A quote-level discount applies proportionally and shows as a separate line on the PDF.

      ### Saving vs sending
      **Save** keeps the invoice as a draft — editable, not yet delivered. **Send** emails it to the customer and locks the totals (further changes require a credit memo).

      ## Tips & Best Practices
      > **Tip:** Use **invoice templates** (in Finance settings) to standardize line items for common services — detail package, oil change, standard delivery.

      > **Note:** Invoices respect your company's locked-period setting. Invoices dated in a locked fiscal period can't be edited without unlocking.

      ## Related Features
      - Sending invoices by email
      - Processing payments on invoices
      - Invoice PDF and print
      - Draw schedules on invoices
    MD
  },
  {
    module_key: 'invoices', slug: 'sending-invoices', title: 'Sending Invoices by Email', article_type: 'guide',
    excerpt: 'Email invoices to customers with delivery tracking and open confirmations.',
    content: <<~MD
      ## Overview
      Email delivery attaches a PDF and includes a secure payment link. You'll see open tracking and (if a payment gateway is configured) one-click online payment.

      ## Getting There
      1. Click **Finance & Agreements** > **Invoices** in the sidebar
      2. Open any saved invoice

      ## Step-by-Step Guide
      ### Sending
      1. Click **Send** in the top-right
      2. The recipient prefills from the customer's email
      3. Add CCs if needed (e.g. accountant, spouse, manager)
      4. Customize the subject and body — defaults pull from your Finance settings template
      5. Click **Send**

      The email leaves via your configured email account (your connected Gmail/Microsoft, or the company SMTP).

      ### Delivery tracking
      The invoice detail page shows:
      - **Sent** — when you clicked Send
      - **Delivered** — SMTP confirmed handoff
      - **Opened** — customer opened the email (first time + all subsequent opens)
      - **Link clicked** — customer opened the payment page
      - **Paid** — payment completed

      ### Resending
      Click **Resend** to fire the same email again — useful if the customer says they didn't receive it. Each resend is logged separately.

      ### Reminders
      Configure automatic reminders in **Finance settings > Dunning**. The system can email friendly reminders at 7, 14, and 30 days past due.

      ## Tips & Best Practices
      > **Tip:** Customize the default email body to include your payment link front-and-center — customers pay faster when they don't have to hunt for it.

      > **Note:** Sent invoices are locked — to change them, void and re-issue or create a credit memo.

      ## Related Features
      - Creating invoices
      - Processing payments on invoices
    MD
  },
  {
    module_key: 'invoices', slug: 'invoice-payments-guide', title: 'Processing Payments on Invoices', article_type: 'guide',
    excerpt: 'Record payments, handle partial payments, and process refunds on invoices.',
    content: <<~MD
      ## Overview
      Payments close the loop on invoices. They arrive via the public payment link (card or ACH), via your integrated payment provider, or manually recorded from checks and cash.

      ## Getting There
      1. Click **Finance & Agreements** > **Invoices** in the sidebar
      2. Open the invoice you want to record a payment on

      ## Step-by-Step Guide
      ### Recording a payment manually
      1. Click **Record Payment**
      2. Enter:
         - **Amount** — the full balance prefills; change for partial payments
         - **Date received**
         - **Method** — check, cash, card, ACH, or other
         - **Reference number** — check number, confirmation code, etc.
      3. Click **Save**

      Balance updates immediately. If the invoice is fully paid, status flips to **Paid**.

      ### Partial payments
      Enter the partial amount. The remaining balance stays outstanding. Subsequent payments continue to apply against the balance until it's zero.

      ### Processing a refund
      From any captured payment line:
      1. Click **Refund**
      2. Enter refund amount (full or partial)
      3. If the payment went through your payment provider (Stripe, Braintree), the refund processes through the same rails
      4. Manual payments (check, cash) mark as refunded in the system; you handle actual money movement outside

      ### Payment history
      The **Payments** tab on the invoice shows every capture, every refund, every failed attempt with timestamps and reference numbers.

      ## Tips & Best Practices
      > **Tip:** Turn on bank feed sync so deposits auto-match to expected payments — cuts reconciliation time dramatically.

      > **Note:** Unapplied payments (customer paid before an invoice existed) sit in the **Credit** bucket until you apply them.

      ## Related Features
      - Creating invoices
      - Recording and tracking payments
    MD
  },
  {
    module_key: 'invoices', slug: 'invoice-pdf', title: 'Invoice PDF and Print', article_type: 'guide',
    excerpt: 'Generate, download, and print branded invoice PDFs.',
    content: <<~MD
      ## Overview
      Every invoice renders as a branded PDF ready for download, print, or email attachment. Your company logo, colors, and footer text configure once and apply to every invoice.

      ## Getting There
      1. Click **Finance & Agreements** > **Invoices** in the sidebar
      2. Open the invoice you want to download

      ## Step-by-Step Guide
      ### Downloading the PDF
      1. Click the **PDF** button in the top-right of the invoice
      2. Your browser downloads a file named `invoice-[number].pdf`
      3. Open it in your PDF viewer or forward it however you like

      ### Printing
      1. Click **Print** in the top-right of the invoice
      2. Your browser's print dialog opens with the rendered PDF
      3. Pick a printer and adjust settings
      4. Click **Print**

      ### What's on the PDF
      - Your company logo and address (from Company Settings > Branding)
      - Invoice number, date, and due date
      - Bill-to (customer) and ship-to (if different)
      - All line items with descriptions, quantities, prices
      - Subtotals, discounts, taxes, and total
      - Payment terms and due date
      - Footer notes (configured in Finance settings)

      ### Customizing the look
      Logo, colors, and footer text live in **Company Settings > Branding**. Fonts and overall layout use a fixed template — contact support if you need a custom design.

      ## Tips & Best Practices
      > **Tip:** Keep the footer short and useful — payment instructions, your phone number, your website. Legal disclaimers go on a separate page if needed.

      > **Note:** Sending by email automatically attaches the PDF — no need to download first.

      ## Related Features
      - Creating invoices
      - Sending invoices by email
      - Branding and customization
    MD
  },
  {
    module_key: 'invoices', slug: 'draw-schedules', title: 'Draw Schedules on Invoices', article_type: 'guide',
    excerpt: 'Use draw schedule templates for construction and installation progress billing.',
    content: <<~MD
      ## Overview
      Draw schedules split a large invoice into milestone payments — useful for construction, site prep, and installation work where you bill as phases complete.

      ## Getting There
      1. Click **Finance & Agreements** > **Invoices** in the sidebar
      2. Create a new invoice or open an existing draft

      ## Step-by-Step Guide
      ### Applying a draw schedule
      1. On the invoice, click **Apply Draw Schedule**
      2. Pick a template from your configured templates (set up in **Company Settings > Finance > Draw Schedule Templates**)
      3. The template splits the total into draws — e.g. 10% deposit, 30% at permit, 30% at delivery, 30% at completion
      4. Review the draws and adjust individual percentages or amounts
      5. Click **Save**

      ### Invoicing each draw
      Each draw becomes its own invoice that you send separately as milestones complete. From the parent invoice:
      1. Click **Invoice Draw** next to any unreleased draw
      2. Review the generated invoice (description, amount, due date)
      3. Send to the customer

      Balances roll up — the parent invoice tracks how much of the total has been billed vs remains.

      ### Creating a draw schedule template
      1. Click **Company Settings** > **Finance** tab > **Draw Schedule Templates**
      2. Click **New Template**
      3. Add draws with names, percentages, and milestone descriptions
      4. Save

      ## Tips & Best Practices
      > **Tip:** Tie draw invoices to project phases — when a phase marks complete, the draw invoice sends automatically via workflow rules.

      > **Note:** Each draw is a real invoice — it shows in AR aging, generates its own PDF, and takes its own payment. The parent invoice is just a tracker.

      ## Related Features
      - Creating invoices
      - Managing project phases and tasks
    MD
  },

  # ================================================================= Payments
  {
    module_key: 'payments', slug: 'tracking-payments', title: 'Recording and Tracking Payments', article_type: 'guide',
    excerpt: 'View, filter, and manage every payment across all invoices and modules.',
    content: <<~MD
      ## Overview
      The Payments module is your cross-invoice view of every payment captured by your business — cards, ACH, checks, cash, everything.

      ## Getting There
      1. Click **Finance & Agreements** in the sidebar
      2. Click **Payments**

      ## The Payments List
      ### Filtering
      Filters at the top of the page scope by date range, method, status, and location. Save commonly-used filter sets as **Views**.

      ### Status values
      - **Pending** — submitted but not yet cleared
      - **Captured** — successful
      - **Failed** — declined or errored
      - **Refunded** — refund issued (partial or full)
      - **Disputed** — chargeback initiated

      ### Stats tiles
      Four tiles show: total captured, total refunded, total pending, total failed — all for the current filter date range.

      ## Step-by-Step Guide
      ### Recording a payment
      Most payments flow in automatically from invoices. For money received outside the invoice flow:
      1. Click **Record Payment**
      2. Pick a customer and an invoice to apply against (or leave unapplied for a credit)
      3. Enter amount, date, method, and reference
      4. Click **Save**

      ### Refunding a payment
      1. Click a payment to open its detail page
      2. Click **Refund**
      3. Enter full or partial amount and reason
      4. Click **Confirm**

      Integrated gateway refunds process through the same rails. Manual payments flag as refunded for accounting — you handle actual money movement outside.

      ### Exporting
      Click **Export** to download the current filtered view as CSV or Excel — perfect for reconciliation with bank statements.

      ## Tips & Best Practices
      > **Tip:** Run a weekly bank reconciliation — export captured payments for the week and match against deposits. Bank-feed sync (if enabled) automates this.

      ## Related Features
      - Processing payments on invoices
      - Finance settings
    MD
  },

  # ================================================================ Agreements
  {
    module_key: 'agreements', slug: 'agreement-templates', title: 'Creating Agreement Templates', article_type: 'guide',
    excerpt: 'Build reusable contract templates — purchase agreements, service contracts, disclosures.',
    content: <<~MD
      ## Overview
      Templates are the foundation of the Agreements module. Build a template once, then generate contracts from it in seconds — with merge fields that pull data from the linked deal, contact, or account.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Agreements** tab (or **Templates**)
      3. Click **Agreement Templates**

      ## Step-by-Step Guide
      ### Creating from scratch
      1. Click **New Template**
      2. Enter a template name and category
      3. Use the editor to write the document body
      4. Insert merge fields using the toolbar — `{{contact.name}}`, `{{deal.amount}}`, `{{inventory.vin}}`, etc.
      5. Add signature fields where signers should sign
      6. Click **Save**

      ### Uploading a PDF template
      If you have a manufacturer-provided or legal-provided PDF:
      1. Click **Upload PDF**
      2. Once uploaded, use the field placement tool
      3. Drop **Signature**, **Date**, and **Text** fields anywhere on any page
      4. Map each text field to a merge field (e.g. `{{contact.name}}`)
      5. Save

      The PDF renders identically to the editor-built template during signing.

      ### Versioning
      When you edit a template, existing agreements already in flight keep their original version. Only new agreements use the edited template.

      ### Archiving
      Toggle to **Inactive** when a template retires — existing signed agreements keep their history; the template just hides from the picker.

      ## Tips & Best Practices
      > **Tip:** Build a library of 10-15 templates for your most common contracts. New-hire reps can send their first agreement on day one.

      > **Note:** Templates are shared across the whole company. Use categories to organize by department (Sales, Service, HR).

      ## Related Features
      - Sending agreements for e-signature
      - Agreement categories
    MD
  },
  {
    module_key: 'agreements', slug: 'send-for-esign', title: 'Sending Agreements for E-Signature', article_type: 'guide',
    excerpt: 'The e-sign workflow — add signers, send via email, track status in real time.',
    content: <<~MD
      ## Overview
      E-signatures are legally binding and faster than chasing wet ink. Send an agreement, each signer gets a personalized link, sign anywhere — desktop, mobile, anywhere with internet.

      ## Getting There
      1. Click **Finance & Agreements** in the sidebar
      2. Click **Agreements**

      ## Step-by-Step Guide
      ### Creating an agreement
      1. Click **New Agreement**
      2. Pick a **template** — data merges auto-fill from the linked record
      3. Pick the **source record** (deal, contact, account, or invoice)
      4. Review the generated document in the editor; fix any placeholders the merge didn't cover
      5. Click **Save** — status is **Draft**

      ### Adding signers
      1. Open the **Signers** tab
      2. Click **Add Signer**
      3. Enter name, email, and role (Buyer, Co-Buyer, Dealer, Witness, etc.)
      4. If sequential signing matters, set the signing order — each signer is notified only after the previous one completes
      5. Click **Save**

      ### Sending
      1. Click **Send for Signature** in the top-right
      2. Customize the email subject and body
      3. Click **Send**

      Each signer receives a unique secure link. They review, sign on any device, and status updates in real time.

      ### Tracking status
      The agreement detail page shows each signer's status:
      - **Sent** — email delivered
      - **Viewed** — signer opened the link
      - **Signed** — signer completed their fields
      - **Declined** — signer refused (with optional reason)

      When every signer completes, the agreement auto-finalizes with a downloadable signed PDF and a courtroom-ready audit log.

      ## Tips & Best Practices
      > **Tip:** Reminders auto-send if signers don't complete within your configured cadence (default: 3 days).

      ## Related Features
      - Creating agreement templates
      - Agreement categories
    MD
  },
  {
    module_key: 'agreements', slug: 'agreement-categories', title: 'Agreement Categories', article_type: 'guide',
    excerpt: 'Organize agreements by category — purchase, service, warranty, disclosures.',
    content: <<~MD
      ## Overview
      Categories group agreements by purpose — Purchase Agreements, Service Contracts, Warranties, Disclosures, Employment Docs. Good categories make finding the right template fast.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Agreements** tab
      3. Click **Categories**

      ## Step-by-Step Guide
      ### Adding a category
      1. Click **Add Category**
      2. Enter the category name
      3. Optionally, pick an icon and color
      4. Click **Save**

      ### Assigning templates
      Each agreement template has a **Category** field. Set it when creating the template, or edit existing templates to re-categorize.

      ### Reordering
      Drag categories up or down to change their display order in the template picker.

      ### Renaming and deactivating
      Click a category to rename. Toggle **Active** off to hide the category without deleting — existing agreements keep their category reference intact.

      ## Using Categories
      - **In the template picker** — categories filter the list when creating a new agreement
      - **In the agreements list** — filter by category to find related agreements quickly
      - **In reports** — volume and throughput metrics break down by category

      ## Tips & Best Practices
      > **Tip:** Start with 5-7 top-level categories. Fine-grained tagging beats fine-grained categories — use tags for sub-groupings.

      > **Note:** Don't categorize every template individually if your volume is low. Two or three broad categories are fine for most dealerships.

      ## Related Features
      - Creating agreement templates
      - Sending agreements for e-signature
    MD
  },

  # ================================================================== Projects
  {
    module_key: 'projects', slug: 'project-templates', title: 'Creating Projects from Templates', article_type: 'guide',
    excerpt: 'Use project templates to spin up standard work fast — delivery, setup, installation.',
    content: <<~MD
      ## Overview
      Project templates codify your standard workflows — home delivery, site setup, multi-week renovations. Start a project from a template and the phases, tasks, and checklists come pre-built.

      ## Getting There
      1. Click **Projects** in the sidebar
      2. Click **Create Project**
      3. Or manage templates under **Company Settings > Projects > Templates**

      ## Step-by-Step Guide
      ### Creating from a template
      1. Click **Create Project**
      2. In the new-project dialog, click **Start from Template**
      3. Pick a template (e.g. "Home Delivery & Setup")
      4. Set the customer, linked unit, start date, and project manager
      5. Click **Create**

      The template instantiates with every phase, task, checklist, and default assignee populated. You can edit any item before work begins.

      ### Building a template
      1. Go to **Company Settings > Projects > Templates**
      2. Click **New Template**
      3. Add phases (e.g. Site Prep, Delivery, Setup, Inspection, Handoff)
      4. Under each phase, add tasks with estimated duration, assignee role, and a checklist
      5. Click **Save**

      ### Editing a template
      Edits apply only to projects created from the template AFTER the edit. Existing in-flight projects keep their instantiated version.

      ### Archiving
      Toggle to **Inactive** when a template retires. Historical projects keep their original template reference.

      ## Tips & Best Practices
      > **Tip:** Build templates for your top 3-5 repeat project types. They cut project setup from 30 minutes to 2 minutes AND ensure nothing gets forgotten.

      ## Related Features
      - Managing project phases and tasks
      - Assigning team members to projects
    MD
  },
  {
    module_key: 'projects', slug: 'project-phases-tasks', title: 'Managing Project Phases and Tasks', article_type: 'guide',
    excerpt: 'Break projects into phases; each phase into tasks with checklists and due dates.',
    content: <<~MD
      ## Overview
      Phases and tasks are how you actually run a project. Phases group related work (Site Prep, Delivery, Setup); tasks are the concrete TODO items within each phase.

      ## Getting There
      1. Click **Projects** in the sidebar
      2. Open any project's detail page
      3. Click the **Phases & Tasks** tab

      ## Step-by-Step Guide
      ### Adding a phase
      1. Click **Add Phase**
      2. Enter phase name, start and end dates, and a brief description
      3. Click **Save**

      ### Adding a task to a phase
      1. Expand a phase
      2. Click **Add Task**
      3. Enter:
         - **Title** — short, actionable (e.g. "Pour foundation pad")
         - **Assignee** — user or contractor
         - **Due date**
         - **Estimated hours** (optional)
         - **Checklist** — sub-items like "Grade site", "Stake corners", "Pour concrete"
      4. Click **Save**

      ### Completing tasks
      Click the checkbox next to a task to mark it done. Check off individual checklist items as you go — they roll up into the task's completion percentage.

      ### Progress rollup
      Completed tasks → phase completion percentage → project completion percentage. Progress bars update in real time.

      ### Reordering
      Drag phases up or down to change their project order. Drag tasks between phases to reorganize.

      ### Dependencies
      On any task, set **Depends On** to another task — the dependent task won't unlock until the prerequisite completes.

      ## Tips & Best Practices
      > **Tip:** Keep tasks small enough to finish in one sitting. Any task over 4 hours should probably be split.

      > **Note:** Assignees get notified when a task is assigned, when it's due tomorrow, and when a blocking dependency completes.

      ## Related Features
      - Creating projects from templates
      - Assigning team members to projects
    MD
  },
  {
    module_key: 'projects', slug: 'project-team', title: 'Assigning Team Members to Projects', article_type: 'guide',
    excerpt: 'Add project managers, team members, and contractors with scoped access.',
    content: <<~MD
      ## Overview
      Projects can have multiple team members — a project manager, internal staff, and external contractors. Each person sees the project differently based on their role.

      ## Getting There
      1. Click **Projects** in the sidebar
      2. Open any project's detail page
      3. Click the **Team** tab

      ## Step-by-Step Guide
      ### Adding a project manager
      1. Click the **Project Manager** field in the project header
      2. Pick any internal user
      3. They become the primary owner — notifications, customer communications, and status escalations go to them

      ### Adding internal team members
      1. Click the **Team** tab
      2. Click **Add Member**
      3. Pick a user and set their role (Lead, Contributor, Observer)
      4. Click **Save**

      Internal members see everything on the project — phases, tasks, budget, documents.

      ### Adding contractors
      1. On the **Team** tab, click **Add Contractor**
      2. Pick a contractor from your contractor list (or create a new one)
      3. Set their scope — all tasks, or only specific task assignments
      4. Click **Save**

      Contractors access the project via the **Contractor Portal** — a limited view showing only their assigned tasks, no financial data, no other team members' work.

      ### Removing a member
      Click the ⋯ menu next to their name and pick **Remove**. History (completed tasks, logged hours) stays — they just no longer see the project going forward.

      ## Tips & Best Practices
      > **Tip:** Assign one Project Manager — multiple PMs create accountability gaps. Use "Lead" role for supporting leads.

      > **Note:** Contractors can upload photos and mark tasks complete on mobile — useful for site check-ins.

      ## Related Features
      - Managing project phases and tasks
    MD
  },

  # ============================================================= Service Tickets
  {
    module_key: 'service', slug: 'creating-service-tickets', title: 'Creating Service Tickets', article_type: 'guide',
    excerpt: 'Log service requests and repair work — complaint, unit, parts, labor.',
    content: <<~MD
      ## Overview
      Service tickets organize repair work. Every ticket captures the customer, the unit, the problem, parts and labor consumed, and the final outcome.

      ## Getting There
      1. Click **Service & Support** in the sidebar
      2. Click **Service Tickets**

      ## Step-by-Step Guide
      ### Creating a ticket
      1. Click **Create Ticket** in the top-right
      2. Fill in:
         - **Customer** — contact or account
         - **Unit** — from inventory or customer-provided
         - **Complaint** — what the customer reported, in their words
         - **Priority** — Low / Normal / High / Urgent
         - **Estimated hours** — if you know up-front
      3. Click **Save** — status is **Open**

      ### Recording the diagnosis
      In the ticket's **Notes** tab, log what your tech finds. Photos, measurements, and videos all attach. This becomes the basis for a quote (if the repair isn't covered) or a warranty claim.

      ### Adding parts
      1. Click the **Parts** tab
      2. Click **Add Part** and pick from inventory
      3. Enter quantity — stock decrements when you commit

      ### Logging labor
      1. Click the **Labor** tab
      2. Add labor lines with hours, rate, and which tech
      3. Multiple techs can log time against the same ticket

      Parts + labor feed the ticket's **Total**, which becomes the invoice line items when you bill.

      ### Warranty-linked tickets
      If the repair is warranty work, link it to the manufacturer and warranty type. The ticket becomes the source for a warranty claim.

      ## Tips & Best Practices
      > **Tip:** Record the complaint in the customer's exact words. Makes dispute resolution easier later.

      ## Related Features
      - Assigning and tracking tickets
      - Service ticket priorities and SLAs
      - Filing warranty claims
    MD
  },
  {
    module_key: 'service', slug: 'assigning-tickets', title: 'Assigning and Tracking Tickets', article_type: 'guide',
    excerpt: 'Assign tickets to technicians and track progress through the status workflow.',
    content: <<~MD
      ## Overview
      Assignment turns a ticket into someone's work. Status tracking shows where every ticket is — so nothing falls through the cracks and customers know when to expect updates.

      ## Getting There
      1. Click **Service & Support** > **Service Tickets** in the sidebar
      2. Open any ticket

      ## Step-by-Step Guide
      ### Assigning a technician
      1. On the ticket, click the **Assigned To** field
      2. Pick a tech from your team
      3. They get an in-app notification immediately and the ticket appears on their **Today** dashboard

      Reassign by picking a different tech at any time — the old assignee loses visibility, the new one takes over.

      ### Status workflow
      Every ticket moves through:
      - **Open** — created, not yet worked
      - **In Progress** — tech is actively working
      - **Waiting on Parts** — blocked pending parts arrival
      - **Completed** — work done, ready to invoice
      - **Invoiced** — billed to customer
      - **Closed** — paid and done

      Click the status badge to advance it. Status changes auto-notify the customer if **customer notifications** are enabled (configured per-company in Service settings).

      ### Tracking on the list
      The tickets list filters by:
      - **Status** — see just open, just waiting-parts, etc.
      - **Assignee** — your tickets vs team view
      - **Priority** — triage by urgency
      - **Date range** — recent activity

      Save commonly-used filter sets as **Views**.

      ### The service calendar
      Click the **Calendar** tab to see all tech assignments in day/week/month view. Useful for scheduling ahead and spotting overloads.

      ## Tips & Best Practices
      > **Tip:** Don't let tickets sit in "Waiting on Parts" unattended — the Parts module's low-stock alerts should trigger auto-POs.

      ## Related Features
      - Creating service tickets
      - Service ticket priorities and SLAs
    MD
  },
  {
    module_key: 'service', slug: 'ticket-priorities', title: 'Service Ticket Priorities and SLAs', article_type: 'guide',
    excerpt: 'Set priority levels and response-time SLAs so urgent issues get handled first.',
    content: <<~MD
      ## Overview
      Priority and SLA configuration let you promise (and deliver) specific response times. Urgent issues rise to the top of every tech's queue; low-priority items don't crowd the board.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Service** tab
      3. Click **Priorities & SLAs**

      ## The Four Priority Levels
      - **Low** — cosmetic or non-functional issues (scratched trim, loose screw)
      - **Normal** — routine maintenance, non-urgent repairs
      - **High** — functional problems affecting usability (AC not cooling, leaking faucet)
      - **Urgent** — safety or total-loss-of-use issues (gas leak, no heat in winter)

      ## Step-by-Step Guide
      ### Configuring SLAs
      1. In **Company Settings > Service > Priorities & SLAs**
      2. For each priority, set:
         - **First response time** — how fast you commit to acknowledge the ticket
         - **Resolution time** — how fast you commit to fix it
         - **Escalation path** — who gets pinged if the SLA is about to breach
      3. Click **Save**

      Defaults are sensible: Urgent = 1hr / 4hr, High = 4hr / 24hr, Normal = 1 business day / 5 days, Low = 2 business days / 14 days.

      ### Setting priority on a ticket
      When creating or editing a ticket, pick the priority. The SLA timer starts when the ticket is created and the **Due By** date computes automatically.

      ### Tracking SLA compliance
      The tickets list shows:
      - Green check — within SLA
      - Yellow warning — approaching breach (last 20% of time window)
      - Red alert — SLA breached

      Reports break down SLA compliance by tech, priority, and month.

      ## Tips & Best Practices
      > **Tip:** Don't promise faster SLAs than you can deliver — missed SLAs erode customer trust worse than honest longer commitments.

      > **Note:** SLA timers pause when status is **Waiting on Parts** or **Waiting on Customer** — fair when the delay isn't on you.

      ## Related Features
      - Assigning and tracking tickets
    MD
  },

  # ================================================================== Warranty
  {
    module_key: 'warranty', slug: 'filing-warranty-claims', title: 'Filing Warranty Claims', article_type: 'guide',
    excerpt: 'Submit manufacturer warranty claims from completed service tickets.',
    content: <<~MD
      ## Overview
      Warranty claims get you reimbursed for repairs covered under manufacturer warranty. Tight claim filing directly impacts your bottom line — uncollected warranty work is lost revenue.

      ## Getting There
      1. Click **Service & Support** in the sidebar
      2. Click **Warranty Claims**

      ## Step-by-Step Guide
      ### Filing from a service ticket
      1. Complete the service work — claims can't be filed against open tickets
      2. Open the service ticket
      3. Click **File Warranty Claim**
      4. Pick the **manufacturer** and **warranty type** (base, extended, dealer, third-party)
      5. Review parts and labor lines pulled from the ticket — adjust to match what the manufacturer will cover (some won't pay for shop supplies, etc.)
      6. Fill in manufacturer-specific fields (claim number format, cause codes, labor op codes)
      7. Attach photos — most manufacturers require them
      8. Click **Submit**

      Status becomes **Submitted**, timestamped and audit-logged.

      ### Filing standalone (no ticket)
      If you have a warranty claim from historical work:
      1. In **Warranty Claims**, click **New Claim**
      2. Manually enter customer, unit, complaint, and work performed
      3. Fill in parts and labor lines
      4. Submit as usual

      ### Manufacturer-specific requirements
      Different manufacturers require different data — photos, cause codes, specific labor ops. The system prompts for whatever the selected manufacturer requires. Missing fields flag red and block submission.

      ## Tips & Best Practices
      > **Tip:** File claims the same day work completes. Delays lose revenue — manufacturers often reject claims submitted after a time limit.

      > **Note:** Every claim is audit-logged including who filed, when, and what was submitted — useful if the manufacturer disputes.

      ## Related Features
      - Tracking claim status
      - Creating service tickets
    MD
  },
  {
    module_key: 'warranty', slug: 'tracking-warranty-claims', title: 'Tracking Claim Status', article_type: 'guide',
    excerpt: 'Monitor claim progress, manufacturer responses, and reimbursements.',
    content: <<~MD
      ## Overview
      Claim tracking shows where every warranty claim stands — submitted, approved, paid, or disputed — so nothing falls through the cracks and you collect every dollar owed.

      ## Getting There
      1. Click **Service & Support** in the sidebar
      2. Click **Warranty Claims**

      ## Status Workflow
      - **Draft** — not yet filed
      - **Submitted** — filed with manufacturer, awaiting response
      - **Approved** — manufacturer approved; reimbursement pending
      - **Partially Approved** — manufacturer approved some lines, denied others
      - **Denied** — manufacturer rejected the claim
      - **Paid** — reimbursement received and posted to Manufacturer AR
      - **Closed** — fully resolved

      ## Step-by-Step Guide
      ### Filtering claims
      Use the list filters to focus on:
      - **Submitted** — what's awaiting a manufacturer decision
      - **Approved (not yet paid)** — what you're owed
      - **Denied** — claims to dispute or write off

      ### Updating claim status
      When you hear back from the manufacturer:
      1. Open the claim
      2. Click **Record Response**
      3. Pick Approved, Partially Approved, or Denied
      4. Enter the approved amount and any reason for partial/denied
      5. Click **Save**

      If paid, click **Record Payment** and enter the amount + reference.

      ### Disputing denied claims
      If a claim is denied or partially approved and you disagree:
      1. Click **Dispute**
      2. Add your rationale and attach evidence (photos, tech statements, warranty docs)
      3. Click **Submit Dispute**

      Claim re-enters **Submitted** status with a dispute flag.

      ### Aging report
      The **Claim Aging** report (in Reports) shows claims outstanding beyond 30 / 60 / 90 days. Anything over 90 days needs attention — manufacturers rarely pay stale claims on their own.

      ## Tips & Best Practices
      > **Tip:** Run weekly follow-ups on Submitted claims approaching 30 days. Persistence converts "we'll get to it" into actual payment.

      ## Related Features
      - Filing warranty claims
    MD
  },

  # ================================================================ Commissions
  {
    module_key: 'commissions', slug: 'commission-plans', title: 'Setting Up Commission Plans', article_type: 'guide',
    excerpt: 'Create commission plans with rules, tiers, and per-product rates.',
    content: <<~MD
      ## Overview
      A commission plan defines how commissions are calculated for one or more reps. Plans can be flat, percentage, tiered, or hybrid combinations keyed to product category or deal type.

      ## Getting There
      1. Click **Commissions** in the sidebar
      2. Click the **Plans** tab

      ## Step-by-Step Guide
      ### Creating a plan
      1. Click **New Plan**
      2. Enter plan name and effective date
      3. Add **rules** (see below)
      4. Assign reps to the plan
      5. Click **Save**

      ### Plan types
      - **Flat** — fixed dollar amount per deal (e.g. $500 per new unit)
      - **Percentage** — % of deal margin or total (e.g. 5% of margin)
      - **Tiered** — different rates at different volume levels (e.g. 3% up to $500k, 5% above)
      - **Hybrid** — combinations of above, keyed to category

      ### Rules within a plan
      Rules specify WHAT triggers commission. Filter by:
      - Deal type (new, used, trade-in)
      - Product category (MH, RV, trailer, parts)
      - Customer type (first-time, repeat)
      - Deal amount bands

      When a deal closes, every matching rule fires and generates commission line items for the assigned rep.

      ### Assigning reps
      In **Company Settings > Users**, each user has a **Commission Plans** field. A user can have multiple active plans (e.g. new-unit plan + used-unit plan).

      ### Effective dates
      Plans have start and end dates. Deals closed between those dates use the plan. Deals closed after use whatever plan is active then.

      ## Tips & Best Practices
      > **Tip:** Keep it simple to start. One or two plans per team, three or four rules per plan. Add complexity only when your team understands the basics.

      > **Note:** Edits to active plans apply to NEW deals. Deals already earned keep their original calculation.

      ## Related Features
      - Viewing commission reports
      - Processing commission payments
    MD
  },
  {
    module_key: 'commissions', slug: 'commission-reports', title: 'Viewing Commission Reports', article_type: 'guide',
    excerpt: 'Commission dashboards, earned totals, per-rep breakdowns, and payment status.',
    content: <<~MD
      ## Overview
      Commission reports turn raw commission line items into actionable insights — who's earning, what's unpaid, and which plan contributes most revenue.

      ## Getting There
      1. Click **Commissions** in the sidebar
      2. Click the **Dashboard** or **Reports** tab

      ## The Dashboard
      ### Stats tiles
      Four tiles across the top:
      - **Total earned** (month-to-date)
      - **Total paid**
      - **Outstanding balance**
      - **Pending approval**

      Click any tile to filter the details below.

      ### Per-rep breakdown
      Scroll to the **By Rep** chart — bars show earned vs paid for each salesperson. Click a rep name to drill into their commission detail.

      ### Per-plan breakdown
      The **By Plan** chart shows which plans generate the most commission volume — useful for tuning rates.

      ## Reports
      ### Earned commissions
      Every commission line item with source deal, rule, amount, and status. Filter by rep, plan, date, or status.

      ### Commission aging
      Outstanding commissions broken out by age bucket — current, 30, 60, 90+ days.

      ### Chargebacks
      Deals that later unwound (returned unit, financing fell through) and their commission adjustments.

      ## Exporting
      Every report exports to CSV or Excel for payroll integration or offline analysis.

      ## Tips & Best Practices
      > **Tip:** Run the Earned Commissions report weekly and share with each rep. Visibility keeps everyone motivated and catches calculation errors early.

      > **Note:** Commission reports respect RBAC — reps see only their own commissions; managers see their team; admins see everything.

      ## Related Features
      - Setting up commission plans
      - Processing commission payments
    MD
  },
  {
    module_key: 'commissions', slug: 'commission-payments', title: 'Processing Commission Payments', article_type: 'guide',
    excerpt: 'Bundle earned commissions into payment batches and mark as paid.',
    content: <<~MD
      ## Overview
      Commission payments close the loop — earned commissions aren't real money until they're paid. Payment batches group earned commissions and track the actual payout.

      ## Getting There
      1. Click **Commissions** in the sidebar
      2. Click the **Payments** tab

      ## Step-by-Step Guide
      ### Creating a payment batch
      1. Click **Create Payment Batch**
      2. Pick the rep
      3. Pick the period (e.g. "March 2026") — outstanding commissions for that period prefill
      4. Review the total; uncheck any commissions to exclude from this batch
      5. Add any adjustments — bonuses (+) or deductions (-)
      6. Click **Save** — status is **Pending Approval**

      ### Approving a batch
      If your plan requires approval (configurable in commission settings), a manager reviews and approves. Approved batches are ready to pay.

      ### Marking paid
      1. Open the batch
      2. Click **Mark Paid**
      3. Enter payment date, method (check, ACH, payroll), and reference
      4. Click **Confirm**

      Every commission in the batch flips to **Paid**. The rep gets an in-app notification.

      ### Chargebacks
      If a deal later unwinds (customer returns unit, financing falls through), the associated commission reverses automatically and shows as a chargeback on the rep's next batch — handled in the adjustments section.

      ### Export for payroll
      Click **Export** on any batch to download a CSV compatible with common payroll systems (ADP, Gusto, Paychex).

      ## Tips & Best Practices
      > **Tip:** Pay commissions on a regular cadence (twice monthly is common). Predictability keeps reps focused on selling, not wondering when they'll get paid.

      > **Note:** Paid batches are locked — edits require voiding the payment and creating a new one.

      ## Related Features
      - Setting up commission plans
      - Viewing commission reports
    MD
  },

  # ============================================================ Workflow Automation
  {
    module_key: 'workflow_automation', slug: 'workflow-rules', title: 'Creating Workflow Rules', article_type: 'guide',
    excerpt: 'Build event-driven automations — triggers, conditions, actions.',
    content: <<~MD
      ## Overview
      Workflow rules automate repetitive tasks. A rule listens for a trigger (lead created, deal stage changed, invoice paid), checks conditions, and runs actions — emails, task assignments, status updates, webhooks.

      ## Getting There
      1. Click **Workflow Automation** in the sidebar

      ## Step-by-Step Guide
      ### Creating a rule
      1. Click **New Workflow**
      2. Give it a descriptive name ("Auto-assign new leads from website")
      3. Pick a **trigger** — the event that fires the workflow:
         - Lead created / updated / converted
         - Deal created / stage changed / won / lost
         - Invoice created / sent / paid / overdue
         - Service ticket created / status changed
         - ...and more
      4. Add **conditions** — filter which events actually fire the rule (e.g. only if source = "Website")
      5. Add **actions** — what happens:
         - Send email or SMS (with merge fields)
         - Assign to a user or round-robin pool
         - Update a field (change status, set priority)
         - Create a task with due date
         - Fire a webhook to an external system
      6. Toggle **Active** on
      7. Click **Save**

      ### Rule order
      When multiple rules match the same event, they run in the order defined in the list. Drag to reorder if sequence matters.

      ### Pausing without deleting
      Toggle **Active** off to pause a rule. The rule stays configured; it just doesn't fire. Useful during experiments.

      ## Tips & Best Practices
      > **Tip:** Start simple — one trigger, one condition, one action. Compound rules are harder to debug when something goes wrong.

      > **Note:** Every rule run logs to the workflow history — see exactly what fired, what data it operated on, and what actions ran.

      ## Related Features
      - Testing workflows
      - Common workflow examples
    MD
  },
  {
    module_key: 'workflow_automation', slug: 'testing-workflows', title: 'Testing Workflows', article_type: 'guide',
    excerpt: 'Preview and dry-run workflows before unleashing them on live data.',
    content: <<~MD
      ## Overview
      Workflow mistakes are expensive — sending 500 "welcome" emails to the wrong list, or worse. Always test before flipping a workflow on for real.

      ## Getting There
      1. Click **Workflow Automation** in the sidebar
      2. Open any workflow (or create a new one)
      3. Click the **Test** or **Preview** button

      ## Step-by-Step Guide
      ### Dry-run with sample data
      1. Open the workflow in the editor
      2. Click **Test Run**
      3. Pick a real record (a specific lead, deal, etc.) as the test subject
      4. The preview panel shows exactly what would happen:
         - Which conditions matched
         - Which actions would run
         - What data each action would receive
         - Email bodies with merge fields resolved
      5. No side effects — no actual emails send, no fields change

      ### Running in **Simulation Mode**
      For complex workflows:
      1. Toggle **Simulation Mode** on the workflow
      2. Activate the workflow normally
      3. The workflow runs on every matching trigger but only logs what it *would* have done — no actual actions
      4. Review the workflow history for a few hours or days
      5. When happy, toggle Simulation off — real actions start running

      ### Checking the workflow history
      Every rule run (real or simulated) logs:
      - Trigger event and data
      - Conditions checked and their results
      - Actions that ran (or would have run)
      - Output data

      Use this to debug unexpected behavior.

      ### Disabling a misbehaving rule
      If a live rule is firing incorrectly:
      1. Click **Pause** in the rule editor
      2. Review the recent history to see what triggered
      3. Fix the conditions or actions
      4. Test before re-activating

      ## Tips & Best Practices
      > **Tip:** Use Simulation Mode for 48 hours before going live on anything that sends customer-facing emails or SMS.

      ## Related Features
      - Creating workflow rules
      - Common workflow examples
    MD
  },
  {
    module_key: 'workflow_automation', slug: 'workflow-examples', title: 'Common Workflow Examples', article_type: 'guide',
    excerpt: 'Real-world workflow patterns — auto-assign leads, follow-up emails, status updates.',
    content: <<~MD
      ## Overview
      Most dealerships run the same handful of workflows. Copy these patterns as a starting point and adapt.

      ## Getting There
      1. Click **Workflow Automation** in the sidebar
      2. Click **New Workflow**

      ## Examples

      ### Auto-assign new website leads
      - **Trigger:** Lead created
      - **Conditions:** Source = "Website"
      - **Actions:**
        1. Assign to round-robin pool "Sales Team"
        2. Send assignee a notification "New website lead assigned: {{lead.name}}"
        3. Email the lead: "Thanks for your interest — your dedicated rep will reach out within 1 business hour"

      ### Follow-up sequence on unanswered leads
      - **Trigger:** Lead created
      - **Conditions:** none
      - **Actions:**
        1. After 2 days, if status still = "New", send follow-up email #1
        2. After 5 days, if still "New", send follow-up #2
        3. After 10 days, if still "New", task the owner "Call lead {{lead.name}}"

      ### Close-won celebration + next steps
      - **Trigger:** Deal stage changed to "Won"
      - **Actions:**
        1. Create an invoice from the deal
        2. Start the "Standard Delivery" project
        3. Email customer: "Congratulations on your purchase!"
        4. Post to Slack channel #sales-wins

      ### Invoice overdue reminder
      - **Trigger:** Invoice status changed (runs daily)
      - **Conditions:** Status = "Sent" AND days past due = 7
      - **Actions:**
        1. Email customer: "Friendly reminder — invoice {{invoice.number}} is 7 days past due"
        2. Notify the invoice owner

      ### Service ticket SLA escalation
      - **Trigger:** Service ticket SLA breaching
      - **Conditions:** Priority = "Urgent" AND status != "Completed"
      - **Actions:**
        1. Notify service manager
        2. Tag ticket "sla-breach"

      ## Tips & Best Practices
      > **Tip:** Rename the default workflow names to something meaningful — two months from now you'll forget what "Workflow 4" does.

      > **Note:** The workflow library (click **Browse Library** on the Workflows page) has more pre-built examples you can clone.

      ## Related Features
      - Creating workflow rules
      - Testing workflows
    MD
  },

  # ================================================================= Brochures
  {
    module_key: 'brochures', slug: 'creating-brochures', title: 'Creating and Sharing Brochures', article_type: 'guide',
    excerpt: 'Build polished brochures for inventory and share via email or public link.',
    content: <<~MD
      ## Overview
      Brochures turn inventory data into marketing collateral — shareable PDFs and web pages. Every view is tracked so you know who's actually looking at what.

      ## Getting There
      1. Click **Marketing** in the sidebar
      2. Click **Brochures**

      ## Step-by-Step Guide
      ### Creating a brochure
      1. Click **Create Brochure** in the top-right
      2. Pick one or more **inventory items** to feature
      3. Choose a **template** — controls layout, branding, which specs appear
      4. Click **Create** — the brochure renders as both PDF and web page

      ### Customizing
      On the brochure detail page:
      - **Hero photo** — reorder photos to change which is hero
      - **Custom message** — add a personalized note for the recipient
      - **Price display** — show MSRP, asking, or "Contact for price"
      - **Included specs** — toggle which spec fields appear

      ### Sharing
      Every brochure has three delivery options:
      - **Email** — sends PDF as attachment plus a web link
      - **SMS** — sends just the web link (SMS can't do attachments)
      - **Public link** — copy and paste anywhere (Facebook, Messenger, etc.)

      ### View tracking
      The **Views** tab shows every load — approximate location, device, duration. Use it to spot hot prospects who are actually reading vs idly scrolling.

      ### Bulk creation
      For a trade show or sale event, click **Bulk Create** to generate brochures for a whole group of units at once. Each unit gets its own brochure using the selected template.

      ## Tips & Best Practices
      > **Tip:** SMS delivery crushes email on open rates. Use SMS for hot leads and email for broader outreach.

      > **Note:** Sold or removed units auto-pull from active brochures so you don't advertise what you don't have.

      ## Related Features
      - Inventory photos and documents
    MD
  },

  # =========================================================== Website Builder
  {
    module_key: 'website_builder', slug: 'building-website', title: 'Building Your Dealer Website', article_type: 'guide',
    excerpt: 'Launch a public-facing dealer website with live inventory and lead capture.',
    content: <<~MD
      ## Overview
      The Website Builder gets you a public dealer site without a developer. Inventory syncs live, forms capture leads directly into your CRM, and SEO basics come built-in.

      ## Getting There
      1. Click **Marketing** in the sidebar
      2. Click **Website Builder**

      ## Step-by-Step Guide
      ### Creating a site
      1. Click **Create Site**
      2. Pick a subdomain (e.g. `yourdealer.rentersuite.com`) — you can add a custom domain later
      3. Choose a template
      4. Click **Create**

      The site is in **Draft** — not yet publicly accessible.

      ### Configuring basics
      1. Open your site's dashboard
      2. Fill in company info — phone, address, business hours
      3. Upload logo and set brand colors (these pull from Company Settings > Branding if set)
      4. Connect social media accounts

      ### Content
      Every site ships with default pages: Home, Inventory, About, Contact. Use the **page editor** to drag-and-drop content blocks — hero images, text, inventory grids, testimonials, forms.

      ### Preview
      Click **Preview** to see the site on desktop, tablet, and mobile before publishing.

      ### Publishing
      1. When satisfied, click **Publish**
      2. Your site goes live at its subdomain immediately
      3. Want a custom domain? Click **Custom Domain**, follow the DNS setup instructions, and certify your cert once DNS propagates

      ### Taking it down
      Click **Unpublish** to take the site offline while keeping all content. Republish later with one click.

      ## Tips & Best Practices
      > **Tip:** Mobile is where most shoppers arrive. Preview mobile first; build desktop second.

      > **Note:** Every form on the site routes captured leads to your CRM as "Website" source — automatically.

      ## Related Features
      - Managing website pages and content
    MD
  },
  {
    module_key: 'website_builder', slug: 'website-pages-content', title: 'Managing Website Pages and Content', article_type: 'guide',
    excerpt: 'Add pages, edit content blocks, manage blog posts and SEO.',
    content: <<~MD
      ## Overview
      Beyond the defaults (Home, Inventory, About, Contact), every site supports unlimited custom pages, a built-in blog, and per-page SEO settings.

      ## Getting There
      1. Click **Marketing** > **Website Builder** in the sidebar
      2. Open your site
      3. Click **Pages** in the site navigation

      ## Step-by-Step Guide
      ### Adding a page
      1. Click **Add Page**
      2. Enter page title and URL slug
      3. Pick a layout (blank, one-column, two-column, sidebar)
      4. Click **Create** — you land in the page editor

      ### Editing content
      The editor is drag-and-drop:
      1. Click any block to edit its content inline
      2. Drag new blocks from the palette (text, image, gallery, form, inventory grid, etc.)
      3. Use the right-side panel for block-level settings (padding, colors, alignment)
      4. Click **Save**

      ### Inventory grids
      Drop an **Inventory Grid** block to show live inventory. Configure filters (price range, type, location) in the block's settings. Units appear automatically and disappear when sold.

      ### Forms
      Drop a **Form** block to capture leads. Add fields (name, email, phone, message). Submissions land in your CRM as leads with source "Website".

      ### Blog posts
      1. Click **Blog** in site navigation
      2. Click **New Post** — write in the rich-text editor
      3. Set featured image, categories, and tags
      4. Click **Publish**

      Blog posts help SEO rankings for long-tail searches ("best RV for weekend trips", etc.).

      ### SEO per page
      On every page, the **SEO** tab controls:
      - **Title tag** — what shows in the browser tab and Google results
      - **Meta description** — the snippet under your result in search
      - **OG image** — the preview image when shared on social

      Sitemap and robots.txt generate automatically.

      ## Tips & Best Practices
      > **Tip:** Write SEO titles as benefit statements, not feature dumps — "Family RVs Under $50k" beats "Our RV Inventory".

      ## Related Features
      - Building your dealer website
    MD
  },

  # ================================================================== Calendar
  {
    module_key: 'calendar', slug: 'using-calendar', title: 'Using the Calendar', article_type: 'guide',
    excerpt: 'View and create events, activities, and reminders across your team.',
    content: <<~MD
      ## Overview
      The Calendar is the central view of everything scheduled across your team — customer appointments, service tech assignments, delivery windows, tasks, and reminders.

      ## Getting There
      1. Click **Calendar** in the sidebar

      ## Step-by-Step Guide
      ### Switching views
      Three main views:
      - **Day** — granular hourly view for today
      - **Week** — standard Monday-Sunday view
      - **Month** — overview for longer-range planning

      Switch between them using the buttons in the top-right.

      ### Creating an event
      1. Click any empty time slot (or click **New Event** in the top-right)
      2. Pick an event type — Meeting, Call, Task, Follow-up
      3. Fill in:
         - **Title** — what the event is
         - **Start** and **end** times
         - **Location** (optional)
         - **Attached record** — link to a lead, contact, deal, or ticket
         - **Attendees** — team members and/or external guests
      4. Click **Save**

      Attendees get a notification. External guests can get an ICS invite if you configure that in Calendar settings.

      ### Editing and moving events
      Click an event to edit. Drag it to a new time slot to reschedule. Drag the edge to change duration.

      ### Filtering
      Show/hide different event types or team members via the sidebar filters. Save filter sets as **Views**.

      ### Reminders
      Set reminders on any event — notified via email, in-app, or both at configurable lead times (15m, 1h, 1d before).

      ### Integration with external calendars
      Connect Google Calendar or Outlook to sync events in both directions. Configure in **Account Settings > Integrations**.

      ## Tips & Best Practices
      > **Tip:** Link every customer-facing event to its record (lead, deal, ticket). You'll thank yourself when looking back through customer history.

      ## Related Features
      - Managing leads
      - Assigning and tracking tickets
    MD
  },

  # =================================================================== Reports
  {
    module_key: 'reports', slug: 'running-reports', title: 'Running Reports', article_type: 'guide',
    excerpt: 'Browse, run, filter, and export saved reports across every module.',
    content: <<~MD
      ## Overview
      Reports surface the state of your business — sales velocity, inventory turnover, service profitability, commission expense, and more. Every data point in the platform is reportable.

      ## Getting There
      1. Click **Reports** in the sidebar

      ## Report Categories
      - **Sales** — leads, pipeline, won/lost, rep performance, source ROI
      - **Inventory** — aging, turnover, margin, stock vs sold
      - **Service** — tech efficiency, parts usage, warranty claim volume
      - **Finance** — AR aging, revenue, cost of sales, margin analysis
      - **Activity** — user activity, touches per lead, response times

      Browse the catalog on the Reports home. Each report has a description of what it shows.

      ## Step-by-Step Guide
      ### Generating a report
      1. Click any report in the catalog
      2. Set filters:
         - **Date range** — common presets (last 7 days, MTD, QTD, YTD) or custom
         - **Owner** — everyone, just me, specific rep
         - **Location** — all, specific lot
         - **Category-specific** filters (deal stage, service status, etc.)
      3. Click **Run**

      Results render inline with tables and interactive charts. Click any chart data point to drill into the underlying rows.

      ### Exporting
      Click **Export** to download:
      - **CSV** — for Excel, Google Sheets, or BI tools
      - **Excel** — formatted XLSX with charts
      - **PDF** — shareable printed report

      ### Scheduling
      1. On any report, click **Schedule**
      2. Pick a cadence (daily, weekly, monthly)
      3. Pick recipients
      4. Click **Save**

      The scheduled report runs on its own and emails results as PDF and CSV.

      ### Saved views
      When you find a useful filter combination, click **Save View** to reuse it next time — one-click access from your Reports home.

      ## Tips & Best Practices
      > **Tip:** Reports respect RBAC — reps see their own deals, managers see their team. If a report shows fewer rows than expected, check the logged-in user's permissions.

      ## Related Features
      - Commission reports
      - Deal analytics
    MD
  },

  # ========================================================== Company Settings
  {
    module_key: 'settings', slug: 'company-profile', title: 'Company Profile Settings', article_type: 'guide',
    excerpt: 'Manage your company name, logo, address, and default tax settings.',
    content: <<~MD
      ## Overview
      Your company profile is the foundation — it appears on invoices, quotes, agreements, and your public website. Set it once; it propagates everywhere.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **General** tab

      ## Step-by-Step Guide
      ### Basic info
      Fill in:
      - **Company name** — legal name that appears on documents
      - **Doing-business-as** (optional) — displays publicly if different from legal name
      - **Primary address** — billing address shown on invoices
      - **Phone** and **email** — contact info for customers
      - **Website** — shown on invoices and brochures
      - **EIN / Tax ID**
      - **Default currency** and **language**

      Click **Save** to commit.

      ### Time zone and fiscal year
      - **Time zone** — drives all displayed dates/times across the platform
      - **Fiscal year start** — used for YTD reporting

      ### Company logo
      Upload logo on the **Branding** tab (see separate article). The logo appears on invoices, quotes, brochures, the buyer portal, and your website.

      ### Locations
      If you have multiple dealerships or lots, manage them separately on the **Locations** tab. Each location can have its own address, tax rate, and payment gateway.

      ## Tips & Best Practices
      > **Tip:** Match your legal name and EIN exactly to what's on file with your bank — mismatches break ACH payment processing.

      > **Note:** Changing the primary address or legal name is logged. If you rebrand or relocate, do it intentionally and document internally.

      ## Related Features
      - Branding and customization
      - Managing locations
    MD
  },
  {
    module_key: 'settings', slug: 'branding-customization', title: 'Branding and Customization', article_type: 'guide',
    excerpt: 'Upload your logo, set brand colors, and customize buyer-facing experiences.',
    content: <<~MD
      ## Overview
      Branding controls the look and feel of everything customers see — invoices, quotes, brochures, the buyer portal, and your website. Consistency builds trust.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Branding** tab

      ## Step-by-Step Guide
      ### Logo
      1. Click **Upload Logo**
      2. Pick an SVG (recommended) or PNG with transparent background
      3. The logo auto-sizes for different contexts — header, invoice, brochure, favicon

      If you have different logos for light vs dark backgrounds, upload both.

      ### Colors
      Set your brand colors:
      - **Primary** — buttons, highlights, active states
      - **Secondary** — accents
      - **Background** — optional for dark-mode variants

      Colors propagate to:
      - Invoice and quote PDFs
      - Brochures
      - Buyer portal
      - Public website (if one is built)

      ### Fonts
      Pick from the font library (web-safe and Google Fonts). Pick one font for headings and one for body; stay consistent.

      ### Buyer portal branding
      The Buyer Portal tab lets customers log in to view their deals, invoices, documents. Customize:
      - Header logo
      - Welcome message
      - Color scheme (inherits from brand colors by default)
      - Support email shown on portal pages

      ### Email templates
      Configure branded email templates for invoice delivery, quote sending, agreement signatures, and nurture sequences.

      ## Tips & Best Practices
      > **Tip:** Test your branding end-to-end — send yourself an invoice, view your brochure, log into the buyer portal. Catch inconsistencies before customers do.

      > **Note:** Branding changes apply to NEW documents. Already-sent invoices keep their original rendering.

      ## Related Features
      - Company profile settings
      - Communication settings
    MD
  },
  {
    module_key: 'settings', slug: 'communication-settings', title: 'Communication Settings', article_type: 'guide',
    excerpt: 'Configure email (SMTP/OAuth) and SMS for sending messages from the platform.',
    content: <<~MD
      ## Overview
      Communication settings control how email and SMS leave the platform — whether through our default infrastructure, your own SMTP, or a connected email account.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Communications** tab

      ## Email Options

      ### Option 1: System SMTP (default)
      Zero setup. Emails leave from a `@notify.rentersuite.com` address and replies don't thread back to individual users. Good for transactional emails (invoice delivery, system notifications).

      ### Option 2: Company SMTP
      1. Click **Configure SMTP**
      2. Enter SMTP server, port, username, password
      3. Click **Test** — a test email sends to your user
      4. Click **Save** if successful

      All company-level emails (invoices, quotes, dunning reminders) leave via your SMTP.

      ### Option 3: Individual OAuth (recommended)
      Each user connects their Gmail or Microsoft 365 account via **Account Settings > Email**. Outgoing emails leave from their actual address; replies thread back to their inbox. Best for rep-to-customer communication.

      ## SMS
      1. Click **Configure SMS**
      2. Connect to Twilio (the default provider) with your Account SID and Auth Token
      3. Pick a sending phone number from your Twilio account
      4. Click **Save**

      SMS sends per message cost money — set a monthly cap to avoid runaway costs.

      ## Inbound email
      If using company SMTP or individual OAuth, configure inbound email routing:
      1. Click **Inbound Email**
      2. Point your mail server's catch-all to the provided address
      3. Incoming emails auto-match to contacts by sender address and append to their communication history

      ## Tips & Best Practices
      > **Tip:** Use individual OAuth for sales reps (personal-feel) and system SMTP for automated messages (branded, consistent).

      ## Related Features
      - Setting up your email
      - Branding and customization
    MD
  },
  {
    module_key: 'settings', slug: 'managing-locations', title: 'Managing Locations', article_type: 'guide',
    excerpt: 'Add and configure business locations, lots, and dealerships.',
    content: <<~MD
      ## Overview
      Locations model your physical business sites — individual lots, dealerships, branches. Users scope to locations, inventory tracks by location, and tax rates apply per location.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Locations** tab

      ## Step-by-Step Guide
      ### Adding a location
      1. Click **Add Location**
      2. Enter name and physical address
      3. Set:
         - **Phone** and **email** — location-specific contact info (override company defaults)
         - **Tax rate** — sales tax rate for invoices from this location
         - **Time zone** — for scheduled events and hours
         - **Hours of operation** — for the public website
      4. Upload a location photo (for the website and brochures)
      5. Click **Save**

      ### Assigning users
      In **Company Settings > Users**, each user has a **Locations** field listing which locations they can access. Multi-location users can switch locations via the location selector in the header.

      ### Making a location the default
      One location is marked as the **primary location**. It's the default for new records and appears on public-facing materials. Change the primary by clicking the star on any location.

      ### Per-location settings
      Each location can override:
      - Tax rate
      - Payment gateway
      - Finance settings
      - Email signature

      Values inherit from company defaults unless explicitly overridden.

      ### Deactivating a location
      When a location closes, toggle to **Inactive**. Historical records (sold units, past deals, closed tickets) keep their location reference; the location just hides from active filters and pickers.

      ## Tips & Best Practices
      > **Tip:** Use location scoping from day one — even if you're single-location. Adding a second location later is much easier when the structure already works correctly.

      ## Related Features
      - Managing users and roles
    MD
  },
  {
    module_key: 'settings', slug: 'finance-settings', title: 'Finance Settings', article_type: 'guide',
    excerpt: 'Payment processing, tax settings, invoice numbering, and draw schedule templates.',
    content: <<~MD
      ## Overview
      Finance settings control how money moves in and out — payment providers, tax rates, invoice numbering, and draw schedule templates.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Finance** tab

      ## Step-by-Step Guide
      ### Payment gateways
      Connect one or more payment providers:
      - **Stripe** — card and ACH, best-in-class developer integration
      - **Braintree** — card and PayPal
      - **Zego** — ACH for rent/loan payments

      1. Click **Connect** next to a provider
      2. Paste your API keys
      3. Click **Test Connection**
      4. Click **Save**

      Multiple providers can be active; you choose per invoice.

      ### Tax settings
      - **Default tax rate** — used when a location doesn't override
      - **Tax inclusive vs exclusive** — how prices display (with or without tax)
      - **Tax exemption handling** — per-customer tax-exempt flag overrides default rates

      ### Invoice numbering
      - **Prefix** — e.g. "INV-" or "2026-"
      - **Starting number**
      - **Padding** — "0001" vs "1"

      Once invoices are issued, changing the format only affects future numbers.

      ### Dunning (past-due reminders)
      Configure automatic email reminders for overdue invoices:
      - Reminder at 7 days past due
      - Reminder at 14 days past due
      - Final notice at 30 days past due

      Each reminder uses a template editable on this tab.

      ### Draw schedule templates
      For construction and installation billing:
      1. Click **Draw Schedule Templates**
      2. Click **New Template**
      3. Add draws with names, percentages, and milestone descriptions (e.g. "Deposit 10%", "At Permit 30%", "At Delivery 30%", "At Completion 30%")
      4. Click **Save**

      Apply templates to invoices via the **Apply Draw Schedule** button.

      ## Tips & Best Practices
      > **Tip:** Test payment processing end-to-end with a real card BEFORE your first live customer. Gateway misconfigurations are painful to discover mid-sale.

      ## Related Features
      - Creating invoices
      - Draw schedules on invoices
    MD
  },
  {
    module_key: 'settings', slug: 'integration-settings', title: 'Integration Settings', article_type: 'guide',
    excerpt: 'Configure QuickBooks, Champion IMS, Zego, and other external integrations.',
    content: <<~MD
      ## Overview
      Integrations connect Renter Insight to external tools so you don't double-enter data. Every integration has its own setup flow on the Integrations tab.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Integrations** tab

      ## Common Integrations

      ### QuickBooks
      Syncs invoices, payments, customers, and items between Renter Insight and QuickBooks Online or Desktop.
      1. Click **Connect QuickBooks**
      2. Sign in with your QuickBooks admin credentials
      3. Grant permissions
      4. Map chart-of-accounts fields (income accounts, tax items)
      5. Pick what to sync (invoices, payments, both)
      6. Click **Start Sync**

      First sync can take 30+ minutes on a large existing dataset. Ongoing sync runs every 15 minutes.

      ### Champion IMS
      For Champion Homes dealers — auto-syncs manufacturer catalog (floor plans, options, pricing) into Inventory.
      1. Click **Connect Champion IMS**
      2. Enter your retailer ID and API credentials
      3. Pick which home types to sync
      4. Click **Start Sync**

      Catalog refreshes daily. Changes appear in Inventory automatically.

      ### Zego
      Payment gateway optimized for ACH rent and loan payments.
      1. Click **Connect Zego**
      2. Enter your Zego merchant credentials
      3. Link to specific locations if you have per-location gateway needs
      4. Click **Save**

      ### Google Calendar / Outlook
      Two-way sync so events created in either system appear in both.
      1. Click **Connect Google** or **Connect Microsoft**
      2. Authorize with your Google or Microsoft account
      3. Pick which calendars to sync
      4. Click **Save**

      ### Webhooks (outgoing)
      Fire HTTP POSTs to external systems when events happen:
      1. Click **Webhooks**
      2. Click **Add Endpoint**
      3. Enter the URL and pick events (lead.created, deal.won, payment.received, etc.)
      4. Click **Save**

      Every delivery is retried with backoff and logged.

      ## Tips & Best Practices
      > **Tip:** Connect one integration at a time, verify it's working, then move on. Debugging multiple new integrations simultaneously is a nightmare.

      ## Related Features
      - Finance settings
      - Communication settings
    MD
  },
  {
    module_key: 'settings', slug: 'tags-management', title: 'Tags Management', article_type: 'guide',
    excerpt: 'Create and manage tags used to segment leads, contacts, deals, and more.',
    content: <<~MD
      ## Overview
      Tags add lightweight categorization to any record. Unlike custom fields, tags are freeform — create as many as you need and apply/remove on the fly.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Tags** tab

      ## Step-by-Step Guide
      ### Creating a tag
      1. Click **Add Tag**
      2. Enter the tag name (e.g. "VIP", "trade-show-2026", "referral")
      3. Optionally, pick a color and icon
      4. Click **Save**

      Tags are case-insensitive — "VIP" and "vip" are the same tag.

      ### Applying tags
      On any record (lead, contact, deal, account, inventory, invoice):
      1. Click the **Tags** field
      2. Pick existing tags from the dropdown or type a new tag name to create on the fly

      Multiple tags per record are fine — tags are additive.

      ### Removing tags
      Click the X next to any applied tag. The tag is removed from this record only; it still exists globally.

      ### Filtering by tag
      In any record list, the filters include a **Tags** option. Pick one or more tags to narrow the list.

      ### Deleting tags
      From the Tags management page:
      1. Find the tag in the list
      2. Click the trash icon
      3. Confirm — the tag is removed from every record it was applied to

      Deletes are permanent.

      ### Merging tags
      If you find duplicates ("VIP" and "vip customer"), click **Merge**. All records with either tag end up with the target tag.

      ## Tips & Best Practices
      > **Tip:** Keep your tag list tight — under 50 active tags. Too many dilutes their usefulness.

      > **Note:** Tags don't drive workflows directly, but workflows can filter by tag. "Apply nurture sequence to all contacts tagged `cold-lead`".

      ## Related Features
      - Managing leads
      - Managing contacts
    MD
  },
  {
    module_key: 'settings', slug: 'item-templates', title: 'Item Templates', article_type: 'guide',
    excerpt: 'Create reusable line-item templates for invoices and quotes.',
    content: <<~MD
      ## Overview
      Item templates are pre-built line items you drop into invoices and quotes in one click. Perfect for common services — detail packages, labor rates, recurring fees.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Finance** tab (or **Items**)
      3. Click **Item Templates**

      ## Step-by-Step Guide
      ### Creating an item template
      1. Click **New Item**
      2. Fill in:
         - **Name** — short, recognizable (e.g. "Exterior Detail")
         - **Description** — what the customer sees on the invoice
         - **Default price**
         - **Default quantity** (usually 1)
         - **Tax category** — Taxable, Non-taxable, Labor (varies by state)
         - **Income account** — for QuickBooks sync
      3. Click **Save**

      ### Using items on invoices
      When creating an invoice or quote:
      1. Click **Add Line Item**
      2. Pick from the dropdown of items — it autocompletes as you type
      3. Description, price, and tax category prefill
      4. Adjust quantity or price per-invoice if needed

      ### Categorizing items
      Organize items into categories (Service, Parts, Labor, Fees, Taxes) for easier navigation in long lists.

      ### Deactivating an item
      When an item retires (discontinued service, etc.), toggle to **Inactive** rather than deleting. Historical invoices keep their line items intact; the item just hides from the picker on new invoices.

      ### Bulk editing
      Check multiple items in the list and use the action bar to:
      - Update prices across the batch
      - Change category
      - Deactivate

      ## Tips & Best Practices
      > **Tip:** Build templates for your 20-30 most common line items. It cuts invoice creation from minutes to seconds.

      > **Note:** Item templates are NOT the same as inventory units. Units are physical products you track; items are line-item shortcuts for invoicing.

      ## Related Features
      - Creating invoices
      - Creating and sending quotes
    MD
  },
  {
    module_key: 'settings', slug: 'warranty-settings', title: 'Warranty Settings', article_type: 'guide',
    excerpt: 'Configure warranty types, manufacturer-specific workflows, and claim defaults.',
    content: <<~MD
      ## Overview
      Warranty settings configure how warranty claims work — which manufacturers you file with, what warranty types exist, and manufacturer-specific claim requirements.

      ## Getting There
      1. Click **Company Settings** in the sidebar
      2. Open the **Warranty** tab

      ## Step-by-Step Guide
      ### Warranty types
      Different warranty types mean different things:
      - **Base warranty** — factory-standard coverage from the manufacturer
      - **Extended warranty** — customer-purchased extended coverage
      - **Dealer warranty** — your in-house warranty
      - **Third-party warranty** — aftermarket warranty companies

      Add new types or rename existing ones as needed.

      ### Manufacturer configuration
      For each manufacturer you file claims with:
      1. Click **Add Manufacturer**
      2. Enter name and contact info (warranty dept email, phone, portal URL)
      3. Add **required fields** — cause codes, labor op codes, photos, anything the manufacturer mandates
      4. Set **labor time guides** — per-operation standard hours
      5. Configure the **reimbursement schedule** — net-30, net-60, etc.
      6. Click **Save**

      Claim forms auto-enforce required fields for each manufacturer.

      ### Claim workflow defaults
      Set company-wide defaults:
      - **Auto-file from service ticket** — when a ticket completes and has a warranty link, auto-create a draft claim
      - **Default warranty type** — if the customer hasn't specified
      - **Required photos** — photos required on every claim regardless of manufacturer

      ### Cause codes and labor ops
      Most manufacturers use their own code systems. Import them as CSVs:
      1. Click **Import Codes**
      2. Pick the manufacturer
      3. Upload the CSV (cause code, description)
      4. Click **Import**

      ### Warranty reports
      Reports driven by warranty settings:
      - Claim volume by manufacturer
      - Average reimbursement time
      - Denial rate by manufacturer
      - Aging claims

      ## Tips & Best Practices
      > **Tip:** Build your manufacturer list completely before filing your first claim. Incomplete manufacturer configs create claim-filing errors that get denied.

      ## Related Features
      - Filing warranty claims
      - Tracking claim status
    MD
  },

  # =========================================================== Account Settings
  # (setup-email already exists — skipped)
  {
    module_key: 'users', slug: 'profile-settings', title: 'Managing Your Profile', article_type: 'guide',
    excerpt: 'Update your name, email, avatar, and personal preferences.',
    content: <<~MD
      ## Overview
      Your profile is how teammates and customers see you — name, photo, email signature, and time zone. Keep it accurate; it shows up in every interaction.

      ## Getting There
      1. Click your profile icon in the top-right corner of the header
      2. Select **Account Settings**
      3. Open the **Profile** tab

      ## Step-by-Step Guide
      ### Basic info
      Update:
      - **First and last name** — how you appear in the platform
      - **Email** — your login and primary contact email (changing requires email verification)
      - **Phone** — shown to teammates for internal calls
      - **Title** — your job title (e.g. "Sales Manager")
      - **Department**

      Click **Save** to commit.

      ### Avatar / profile photo
      1. Click the avatar at the top of the Profile tab
      2. Upload a clear photo — square aspect ratio works best, 400x400px recommended
      3. The avatar appears in the header, next to your name in activity feeds, and on customer-facing materials

      ### Time zone and language
      - **Time zone** — drives how timestamps display to you (the underlying data stays UTC)
      - **Language** — English, Spanish, and more if enabled by your company admin

      ### Email signature
      In the **Signature** section, paste the HTML or plain-text signature you want to append to outgoing emails. Supports rich formatting via the editor.

      ### Default views
      Set your preferred default views for each module:
      - Which view loads on Leads?
      - Which view loads on Deals?
      - Calendar default (day, week, month)?

      ## Tips & Best Practices
      > **Tip:** Use a real photo, not a cartoon. Customers trust real faces; teammates recognize them faster in the activity feed.

      > **Note:** Changing your email address requires confirming via a link sent to the new email — security measure to prevent account hijacking.

      ## Related Features
      - Security settings
      - Setting up your email
    MD
  },
  {
    module_key: 'users', slug: 'security-settings', title: 'Security Settings', article_type: 'guide',
    excerpt: 'Multi-factor authentication, password management, and session control.',
    content: <<~MD
      ## Overview
      Security settings protect your account and your company's data. Turn on MFA, rotate your password regularly, and review active sessions.

      ## Getting There
      1. Click your profile icon in the top-right
      2. Select **Account Settings**
      3. Open the **Security** tab

      ## Step-by-Step Guide
      ### Setting up multi-factor authentication (MFA)
      1. Click **Enable MFA**
      2. Install an authenticator app (Google Authenticator, Authy, 1Password, etc.)
      3. Scan the QR code with the app
      4. Enter the 6-digit code from the app to confirm
      5. Save your **backup codes** somewhere safe (password manager) — you'll need them if you lose your device
      6. Click **Confirm**

      From now on, logins require your password PLUS the current MFA code.

      ### Changing your password
      1. Click **Change Password**
      2. Enter current password
      3. Enter new password (min 12 characters, mix of letters/numbers/symbols recommended)
      4. Confirm new password
      5. Click **Save**

      You'll be logged out of other sessions as a safety measure.

      ### Active sessions
      The **Active Sessions** section shows every device/browser currently logged into your account — device type, location, last activity.

      Click **Revoke** on any session to log it out immediately. Useful if you left a browser logged in on a shared computer.

      ### Login history
      The **Login History** section shows recent login attempts (successful and failed) with IP address and location. Review periodically for unexpected activity.

      ### Recovery email
      Set a backup email address for password resets if you lose access to your primary email. Stored encrypted; never visible to admins.

      ## Tips & Best Practices
      > **Tip:** Enable MFA even if your company doesn't require it. It takes 30 seconds and prevents the vast majority of account takeover attempts.

      > **Note:** Your company admin can require MFA for all users, all admins, or specific roles. Check with your admin if you see "MFA required" after logging in.

      ## Related Features
      - Managing your profile
    MD
  },
  {
    module_key: 'users', slug: 'notification-preferences', title: 'Notification Preferences', article_type: 'guide',
    excerpt: 'Configure email, in-app, and push notifications per event type.',
    content: <<~MD
      ## Overview
      Notifications keep you informed — new leads, upcoming tasks, SLA breaches. Configure which channels notify you for which events so you stay on top without getting overwhelmed.

      ## Getting There
      1. Click your profile icon in the top-right
      2. Select **Account Settings**
      3. Open the **Notifications** tab

      ## Step-by-Step Guide
      ### Notification channels
      Three channels are available:
      - **Email** — sent to your account email
      - **In-app** — notification bell in the header
      - **Push** — browser/mobile push (requires granting browser permission)

      For each event type, pick which channels notify you.

      ### Event categories
      Configure by category:
      - **Leads** — new leads assigned, lead activities
      - **Deals** — stage changes, deal won/lost
      - **Service** — ticket assigned, SLA warnings, customer replies
      - **Invoices** — payments received, invoices overdue
      - **Agreements** — signer viewed, signer signed, completion
      - **Team** — mentions, task assignments, approvals needed
      - **System** — login alerts, sync errors

      ### Digest emails
      Instead of individual email per event, opt for a daily or weekly digest:
      1. Click **Configure Digest**
      2. Pick delivery time (e.g. 8am daily)
      3. Choose which categories to include
      4. Click **Save**

      ### Quiet hours
      Silence non-urgent notifications during nights/weekends:
      1. Toggle **Quiet Hours**
      2. Set the window (e.g. 8pm-7am, weekends)
      3. Urgent notifications (SLA breaches, escalations) still come through

      ### Mute specific threads
      Individual conversations (lead discussions, project threads) can be muted via the Mute button on the thread.

      ## Tips & Best Practices
      > **Tip:** For most people, email-all-events causes notification blindness. Set high-signal events (my deals won, my leads replied) to email + in-app, and everything else to in-app only.

      > **Note:** Push notifications require your browser to be open (desktop) or the mobile app installed (mobile). No app yet? Email + in-app is your best combo.

      ## Related Features
      - Managing your profile
      - Security settings
    MD
  }
].freeze

# ------------------------------------------------------------------
# Seed
# ------------------------------------------------------------------
created = 0
skipped = 0
unresolved = []
errors = []

ARTICLES.each_with_index do |spec, idx|
  if Knowledge::Article.exists?(slug: spec[:slug])
    skipped += 1
    next
  end

  mod = resolve_module(spec[:module_key])
  unless mod
    unresolved << [spec[:slug], spec[:module_key]]
    next
  end

  begin
    Knowledge::Article.create!(
      knowledge_module_id: mod.id,
      title:        spec[:title],
      slug:         spec[:slug],
      excerpt:      spec[:excerpt],
      content:      spec[:content],
      article_type: spec[:article_type],
      position:     idx + 100,
      is_published: true
    )
    created += 1
  rescue ActiveRecord::RecordInvalid => e
    errors << [spec[:slug], e.message]
  end
end

puts "Created: #{created}"
puts "Skipped (slug existed): #{skipped}"
puts "Unresolved module: #{unresolved.inspect}" unless unresolved.empty?
puts "Errors: #{errors.inspect}" unless errors.empty?

puts ""
puts "=== Per-module article counts ==="
Knowledge::Article.group(:knowledge_module_id).count.each do |mid, n|
  m = Knowledge::Module.find_by(id: mid)
  puts "  #{(m&.key || 'unknown').ljust(22)} #{n}"
end
puts ""
puts "Total articles: #{Knowledge::Article.count} (#{Knowledge::Article.published.count} published)"
