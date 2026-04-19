# frozen_string_literal: true

# Rebuilds 23 guided tours with accurate per-step routes and realistic
# selectors. Delete-and-recreate semantics on steps; find-or-create on tours.
# Tours NOT in the explicit list get their routeless steps backfilled from
# their module's route.
#
# Run: bin/rails runner tmp/seed_comprehensive_tours.rb

def resolve_module(key)
  Knowledge::Module.find_by(key: key) ||
    Knowledge::Module.find_by(key: key.to_s.sub(/s\z/, '')) ||
    Knowledge::EntityAlias.find_by(alias_name: key.to_s)&.then { |a| Knowledge::Module.find_by(key: a.canonical_key) }
end

def step(route, selector, title, content, placement: 'bottom')
  { route: route, selector: selector, title: title, content: content, placement: placement }
end

TOURS = [
  # ============================================================ Getting Started
  {
    key: 'first_time_onboarding', name: 'Welcome to Renter Insight', module_key: 'dashboard',
    trigger_type: 'auto_on_first_visit',
    description: 'Quick tour of the main features for first-time users.',
    steps: [
      step('/', 'nav', 'Welcome!',
           'Welcome to Renter Insight! This quick tour will show you around the main features of your new dealer management system.'),
      step('/', 'nav a[href*="crm"]', 'CRM & Sales',
           'Manage your leads, contacts, accounts, and deals. Track your sales pipeline from first contact to closed deal.',
           placement: 'right'),
      step('/', 'nav a[href*="inventory"]', 'Inventory',
           'Track your homes, vehicles, and land inventory. Manage photos, documents, and pricing.',
           placement: 'right'),
      step('/', 'nav a[href*="finance"]', 'Finance & Agreements',
           'Create invoices, process payments, and manage agreements with e-signatures.',
           placement: 'right'),
      step('/', 'nav a[href*="service"]', 'Service & Support',
           'Log service tickets, track warranty claims, and manage your service team.',
           placement: 'right'),
      step('/', 'header button:has(.lucide-circle-help), [data-tour="help-button"]', 'Need Help?',
           'Click the Help button anytime to search features, browse articles, or take guided tours. You can also press Ctrl+? to open it.',
           placement: 'left')
    ]
  },
  {
    key: 'setup_email', name: 'Connect Your Email Account', module_key: 'users',
    trigger_type: 'manual',
    description: 'Connect Google or Microsoft to send tracked email from Renter Insight.',
    steps: [
      step('/account/settings?tab=email', '[role="tablist"] button:nth-child(2), [data-tab="email"]',
           'Email Tab', 'Navigate to Account Settings and click the Email tab to manage your email connections.'),
      step('/account/settings?tab=email', 'button:has(.lucide-plus), button:has(.lucide-mail)',
           'Add Email Connection', 'Click Add Email Connection to connect your Google or Microsoft account.'),
      step('/account/settings?tab=email', '.card, main',
           'Choose Provider', 'Select Google (Gmail/Workspace) or Microsoft (Outlook/365). You will be redirected to sign in and grant permissions.'),
      step('/account/settings?tab=email', 'main',
           'Connection Complete', 'Once connected you can send emails from any lead, contact or deal page. Communication history is tracked automatically.')
    ]
  },
  {
    key: 'manage_users', name: 'Adding Company Users', module_key: 'users',
    trigger_type: 'manual',
    description: 'Invite teammates, set roles, and assign locations.',
    steps: [
      step('/company-settings?tab=users', 'nav a[href*="company-settings"]',
           'Open Company Settings', 'Click Company Settings in the sidebar under your company name.',
           placement: 'right'),
      step('/company-settings?tab=users', '[role="tablist"] button',
           'Users Tab', 'Click the Users tab to manage your team members.'),
      step('/company-settings?tab=users', 'button:has(.lucide-plus), button:has(.lucide-user-plus)',
           'Invite User', 'Click Invite User to add a new team member. Enter their email and they will receive an invitation.'),
      step('/company-settings?tab=users', 'dialog, [role="dialog"], form',
           'Set Role and Permissions', 'Choose a role (Admin, Manager, Sales Rep) and assign them to specific locations. Roles control what they can see and do.'),
      step('/company-settings?tab=users', 'button[type="submit"]',
           'Send Invitation', 'Click Send to invite the user. They will receive an email with a link to set up their account.',
           placement: 'top')
    ]
  },

  # ================================================================ CRM & Sales
  {
    key: 'create_first_lead', name: 'Add Your First Lead', module_key: 'leads',
    trigger_type: 'auto_on_first_visit',
    description: 'Create a new lead and start tracking your sales pipeline.',
    steps: [
      step('/crm', 'nav a[href*="crm"]',
           'Open CRM', 'Click CRM & Sales then Prospecting in the sidebar to see your leads.',
           placement: 'right'),
      step('/crm', '[data-tour="add-button"], button:has(.lucide-plus)',
           'Click Add Lead', 'Click the Add Lead button to create a new prospect.'),
      step('/crm/new', 'input[name="first_name"], form input:first-of-type',
           'Enter Lead Name', 'Type the lead name. This is the primary identifier you will search by.'),
      step('/crm/new', 'input[name="email"], input[type="email"]',
           'Add Email', 'Add their email address for email tracking, nurture sequences, and quote delivery.'),
      step('/crm/new', 'input[name="phone"], input[type="tel"]',
           'Add Phone', 'Enter their phone number for call tracking and activity reminders.'),
      step('/crm/new', 'select, [data-tour="source-select"]',
           'Set Lead Source', 'Select where this lead came from - website, referral, walk-in, phone call.'),
      step('/crm/new', 'button[type="submit"], form button:last-of-type',
           'Save Lead', 'Click Save to create the lead. You can then schedule follow-ups, send quotes, and track activities.',
           placement: 'top')
    ]
  },
  {
    key: 'create_first_deal', name: 'Create Your First Deal', module_key: 'deals',
    trigger_type: 'auto_on_first_visit',
    description: 'Start tracking a sale through your pipeline.',
    steps: [
      step('/deals', 'nav a[href*="deals"]',
           'Open Sales Deals', 'Click CRM & Sales then Sales Deals in the sidebar.',
           placement: 'right'),
      step('/deals', '[data-tour="add-button"], button:has(.lucide-plus)',
           'Click New Deal', 'Click New Deal to start tracking a sale.'),
      step('/deals', 'dialog input:first-of-type, input[name="title"]',
           'Deal Title', 'Give your deal a clear name like Smith Family - 2026 Champion 3BR.'),
      step('/deals', 'dialog input[name="amount"], input[type="number"]',
           'Deal Value', 'Enter the total sale value. This feeds into pipeline analytics and commission tracking.'),
      step('/deals', 'dialog select',
           'Select Stage', 'Choose the pipeline stage - New, Qualified, Proposal, Negotiation.'),
      step('/deals', 'dialog button[type="submit"]',
           'Save Deal', 'Click Save. The deal appears in your pipeline. Drag it between stages as it progresses.',
           placement: 'top')
    ]
  },
  {
    key: 'manage_contacts', name: 'Managing Contacts', module_key: 'contacts',
    trigger_type: 'manual',
    description: 'Create, search, and manage contacts.',
    steps: [
      step('/contacts', 'nav a[href*="contacts"]',
           'Open Contacts', 'Click CRM & Sales then Contacts in the sidebar.',
           placement: 'right'),
      step('/contacts', '[data-tour="stats-tiles"], .grid',
           'Stats Overview', 'Stats tiles show your total contacts, contacts with accounts, and communication metrics.'),
      step('/contacts', '[data-tour="add-button"], button:has(.lucide-plus)',
           'Add Contact', 'Click Add Contact to create a new contact record.'),
      step('/contacts', 'input[placeholder*="search"], [data-tour="search"]',
           'Search Contacts', 'Use the search bar to quickly find contacts by name, email, or phone number.'),
      step('/contacts', '[data-tour="main-table"], table',
           'Contact List', 'Click any contact to view their detail page with communication history, activities, and linked accounts.')
    ]
  },
  {
    key: 'manage_accounts', name: 'Managing Accounts', module_key: 'accounts',
    trigger_type: 'manual',
    description: 'Organize business accounts and their linked contacts.',
    steps: [
      step('/accounts', 'nav a[href*="accounts"]',
           'Open Accounts', 'Click CRM & Sales then Accounts in the sidebar.',
           placement: 'right'),
      step('/accounts', '[data-tour="add-button"], button:has(.lucide-plus)',
           'Add Account', 'Click Add Account to create a company or organization record.'),
      step('/accounts', 'dialog, form',
           'Account Details', 'Enter the company name, type (Customer, Prospect, Partner, Vendor), and contact information.'),
      step('/accounts', 'table, [data-tour="main-table"]',
           'Account List', 'Click any account to see linked contacts, deals, invoices, and communication history.')
    ]
  },

  # ==================================================================== Finance
  {
    key: 'create_first_invoice', name: 'Create Your First Invoice', module_key: 'invoices',
    trigger_type: 'auto_on_first_visit',
    description: 'Generate and send a professional invoice.',
    steps: [
      step('/finance/invoices', 'nav a[href*="finance"]',
           'Open Finance', 'Click Finance & Agreements then Invoices in the sidebar.',
           placement: 'right'),
      step('/finance/invoices', '[data-tour="add-button"], button:has(.lucide-plus), a[href*="new"]',
           'Create Invoice', 'Click Create Invoice to start building a new invoice.'),
      step('/finance/invoices', 'dialog, form, main',
           'Select Customer', 'Choose the customer for this invoice. Search by name or select from your contacts.'),
      step('/finance/invoices', 'table, .line-items',
           'Add Line Items', 'Add products, services, or custom line items. Enter quantity and price - totals calculate automatically.',
           placement: 'top'),
      step('/finance/invoices', 'button[type="submit"], form button:last-of-type',
           'Save and Send', 'Save the invoice. You can then email it to the customer or share a public payment link.',
           placement: 'top')
    ]
  },
  {
    key: 'create_first_quote', name: 'Create Your First Quote', module_key: 'quotes',
    trigger_type: 'manual',
    description: 'Build and send a professional quote to a customer.',
    steps: [
      step('/quotes', 'nav a[href*="quotes"]',
           'Open Quotes', 'Click CRM & Sales then Quotes in the sidebar.',
           placement: 'right'),
      step('/quotes', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'Create Quote', 'Click Create Quote to start building a new quote.'),
      step('/quotes', 'dialog, form, main',
           'Select Contact', 'Choose the customer this quote is for. Search by name or company.'),
      step('/quotes', 'table, .line-items',
           'Add Line Items', 'Add products or services with pricing. You can add discounts and notes per item.',
           placement: 'top'),
      step('/quotes', 'button[type="submit"], form button:last-of-type',
           'Save and Send', 'Save the quote. Email it to the customer with a link to view and accept online.',
           placement: 'top')
    ]
  },
  {
    key: 'manage_payments', name: 'Recording Payments', module_key: 'payments',
    trigger_type: 'manual',
    description: 'View payment history and record new payments.',
    steps: [
      step('/finance/payments', 'nav a[href*="finance"]',
           'Open Finance', 'Click Finance & Agreements then Payments in the sidebar.',
           placement: 'right'),
      step('/finance/payments', '[data-tour="stats-tiles"], .grid',
           'Payment Stats', 'View total payments received, pending amounts, and recent payment activity.'),
      step('/finance/payments', 'table, [data-tour="main-table"]',
           'Payment List', 'See all payments with status, amount, date, and linked invoice. Click any payment for details.')
    ]
  },

  # ================================================================= Agreements
  {
    key: 'create_first_agreement', name: 'Create Your First Agreement', module_key: 'agreements',
    trigger_type: 'manual',
    description: 'Build a contract from a template and send it for e-signature.',
    steps: [
      step('/agreements', 'nav a[href*="agreement"]',
           'Open Agreements', 'Click Finance & Agreements then Agreements in the sidebar.',
           placement: 'right'),
      step('/agreements', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'New Agreement', 'Click New Agreement to create a contract.'),
      step('/agreements', 'dialog, form, main',
           'Select Template', 'Choose from your agreement templates - Purchase Agreement, Service Contract, etc.'),
      step('/agreements', 'dialog, form, main',
           'Add Signers', 'Add the buyers and any co-signers. Each signer gets their own signature fields.'),
      step('/agreements', 'button[type="submit"], button:has(.lucide-send)',
           'Send for Signature', 'Send the agreement via email. Signers receive a link to review and sign electronically.',
           placement: 'top')
    ]
  },

  # ================================================================ Inventory
  {
    key: 'manage_inventory', name: 'Managing Inventory', module_key: 'inventory',
    trigger_type: 'manual',
    description: 'Add and manage homes, vehicles, and land inventory.',
    steps: [
      step('/inventory', 'nav a[href*="inventory"]',
           'Open Inventory', 'Click Inventory & Operations then Inventory in the sidebar.',
           placement: 'right'),
      step('/inventory', '[data-tour="add-button"], button:has(.lucide-plus)',
           'Add Inventory', 'Click Add Home or Add Unit to create a new inventory record.'),
      step('/inventory', '[data-tour="stats-tiles"], .grid',
           'Stats Overview', 'View total units, available inventory, and value metrics at a glance.'),
      step('/inventory', 'table, [data-tour="main-table"]',
           'Inventory List', 'Browse your inventory with sorting, filtering, and search. Click any item for its detail page.'),
      step('/inventory?tab=land', '[role="tablist"] button',
           'Land Management', 'Switch to the Land Management tab to manage land parcels and lots.')
    ]
  },
  {
    key: 'manage_parts', name: 'Managing Parts and Supplies', module_key: 'parts',
    trigger_type: 'manual',
    description: 'Track parts inventory, purchase orders, and warehouse bins.',
    steps: [
      step('/parts', 'nav a[href*="parts"]',
           'Open Parts', 'Click Inventory & Operations then Parts & Supplies in the sidebar.',
           placement: 'right'),
      step('/parts', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'Add Part', 'Click Add Part to create a new part record with SKU, manufacturer, and pricing.'),
      step('/parts', 'table',
           'Parts List', 'Browse parts with search, filter by manufacturer, and track stock levels.'),
      step('/parts/purchase-orders', 'nav a[href*="purchase-orders"]',
           'Purchase Orders', 'Navigate to Purchase Orders to create POs for restocking from suppliers.',
           placement: 'right'),
      step('/parts/bins', 'nav a[href*="bins"]',
           'Warehouse Bins', 'Use Warehouse Bins to organize parts by physical storage location.',
           placement: 'right')
    ]
  },

  # ================================================================== Service
  {
    key: 'create_first_service_ticket', name: 'Create a Service Ticket', module_key: 'service',
    trigger_type: 'manual',
    description: 'Log a service request and assign it to a technician.',
    steps: [
      step('/service', 'nav a[href*="service"]',
           'Open Service', 'Click Service & Support then Service Tickets in the sidebar.',
           placement: 'right'),
      step('/service', '[data-tour="add-button"], button:has(.lucide-plus)',
           'New Service Ticket', 'Click New Service Ticket to log a service request.'),
      step('/service', 'dialog input:first-of-type, form input:first-of-type',
           'Ticket Title', 'Describe the issue - Water heater not working or Carpet replacement needed.'),
      step('/service', 'dialog select',
           'Assign Technician', 'Assign a team member or contractor to handle this ticket.'),
      step('/service', 'dialog button[type="submit"]',
           'Create Ticket', 'Save the ticket. The assignee is notified and you can track parts, labor, and warranty claims.',
           placement: 'top')
    ]
  },
  {
    key: 'manage_warranty', name: 'Filing Warranty Claims', module_key: 'warranty',
    trigger_type: 'manual',
    description: 'File and track warranty claims with manufacturers.',
    steps: [
      step('/warranty', 'nav a[href*="warranty"]',
           'Open Warranty', 'Click Service & Support then Warranty Claims in the sidebar.',
           placement: 'right'),
      step('/warranty', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'New Claim', 'Click New Claim to file a warranty claim with the manufacturer.'),
      step('/warranty', 'dialog, form',
           'Claim Details', 'Select the home/unit, describe the defect, and attach photos as evidence.'),
      step('/warranty', 'table',
           'Track Claims', 'Monitor claim status - Submitted, Under Review, Approved, Completed. Click any claim for details.')
    ]
  },

  # ================================================================== Projects
  {
    key: 'create_first_project', name: 'Start Your First Project', module_key: 'projects',
    trigger_type: 'manual',
    description: 'Create a project to track installation, setup, or construction work.',
    steps: [
      step('/projects', 'nav a[href*="projects"]',
           'Open Projects', 'Click Projects in the sidebar.',
           placement: 'right'),
      step('/projects', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'Create Project', 'Click to create a new project. You can start from a template or build from scratch.'),
      step('/projects', 'dialog, form, main',
           'Project Details', 'Enter the project name, select a customer, set start/end dates, and assign a project manager.'),
      step('/projects', 'dialog, form, main',
           'Add Phases and Tasks', 'Break your project into phases like Site Prep, Foundation, Setup. Each phase has tasks with checklists.'),
      step('/projects', 'button[type="submit"], form button:last-of-type',
           'Save Project', 'Save the project. Track progress, assign team members, manage budgets, and share updates.',
           placement: 'top')
    ]
  },

  # ============================================================== Productivity
  {
    key: 'manage_workflows', name: 'Creating Workflow Rules', module_key: 'workflow_automation',
    trigger_type: 'manual',
    description: 'Build event-driven automations with triggers, conditions, and actions.',
    steps: [
      step('/workflow-automation', 'nav a[href*="workflow"]',
           'Open Workflows', 'Click Workflow Automation in the sidebar.',
           placement: 'right'),
      step('/workflow-automation', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'Create Rule', 'Click New Rule to create an automation workflow.'),
      step('/workflow-automation', 'dialog, form',
           'Configure Trigger', 'Choose what triggers the workflow - a new lead, status change, form submission, or scheduled time.'),
      step('/workflow-automation', 'dialog, form',
           'Add Conditions', 'Set conditions that must be true - lead source equals Website, deal value above 50000.'),
      step('/workflow-automation', 'dialog, form',
           'Define Actions', 'Choose what happens - send email, create task, update status, assign to user, send notification.')
    ]
  },
  {
    key: 'manage_calendar', name: 'Using the Calendar', module_key: 'calendar',
    trigger_type: 'manual',
    description: 'View events, activities, and reminders across your team.',
    steps: [
      step('/calendar', 'nav a[href*="calendar"]',
           'Open Calendar', 'Click Calendar in the sidebar to view your schedule.',
           placement: 'right'),
      step('/calendar', '.fc-toolbar, [data-tour="calendar-toolbar"]',
           'Calendar Views', 'Switch between Month, Week, and Day views using the toolbar buttons.'),
      step('/calendar', '.fc-daygrid, .fc-timegrid, main',
           'Your Schedule', 'See all your activities, appointments, and reminders. Click any event to view or edit it.')
    ]
  },
  {
    key: 'manage_commissions', name: 'Setting Up Commissions', module_key: 'commissions',
    trigger_type: 'manual',
    description: 'Configure commission plans and track payouts.',
    steps: [
      step('/commissions', 'nav a[href*="commissions"]',
           'Open Commissions', 'Click Commissions in the sidebar.',
           placement: 'right'),
      step('/commissions', '[role="tablist"] button',
           'Commission Tabs', 'Use Dashboard for overview, Reports for detailed analysis, Plans to configure rules, and Components for building blocks.'),
      step('/commissions', 'button:has(.lucide-plus)',
           'Create Plan', 'Navigate to the Plans tab and create a commission plan with rules, tiers, and calculation methods.')
    ]
  },

  # ================================================================ Marketing
  {
    key: 'manage_brochures', name: 'Creating Brochures', module_key: 'brochures',
    trigger_type: 'manual',
    description: 'Build marketing brochures and share them via public links or email.',
    steps: [
      step('/brochures', 'nav a[href*="brochures"]',
           'Open Brochures', 'Click Marketing then Brochures in the sidebar.',
           placement: 'right'),
      step('/brochures', 'button:has(.lucide-plus), [data-tour="add-button"]',
           'Create Brochure', 'Click Create Brochure to build a new marketing brochure.'),
      step('/brochures', 'table, .grid, main',
           'Brochure List', 'View and manage your brochures. Share them via public links or email them to prospects.')
    ]
  },
  {
    key: 'manage_websites', name: 'Building Your Website', module_key: 'website_builder',
    trigger_type: 'manual',
    description: 'Build a public dealer website with inventory and lead capture.',
    steps: [
      step('/websites', 'nav a[href*="website"]',
           'Open Website Builder', 'Click Marketing then Website Builder in the sidebar.',
           placement: 'right'),
      step('/websites', 'main',
           'Website Editor', 'Build and customize your dealer website with pages, inventory listings, and lead capture forms.')
    ]
  },

  # =================================================================== Reports
  {
    key: 'manage_reports', name: 'Running Reports', module_key: 'reports',
    trigger_type: 'manual',
    description: 'Access sales, inventory, financial, and other reports.',
    steps: [
      step('/reports', 'nav a[href*="reports"]',
           'Open Reports', 'Click Reports in the sidebar to access all available reports.',
           placement: 'right'),
      step('/reports', 'main, .grid',
           'Available Reports', 'Choose from sales reports, inventory reports, financial reports, and more. Each report can be filtered and exported.')
    ]
  },

  # ========================================================== Company Settings
  {
    key: 'company_settings_overview', name: 'Company Settings Overview', module_key: 'settings',
    trigger_type: 'manual',
    description: 'Tour the main tabs of company-wide configuration.',
    steps: [
      step('/company-settings', 'nav a[href*="company-settings"]',
           'Open Settings', 'Click Company Settings in the sidebar to configure your business.',
           placement: 'right'),
      step('/company-settings?tab=general', '[role="tablist"]',
           'Settings Tabs', 'Settings are organized by tabs - General, Branding, Communications, Finance, Users, Locations, and more.'),
      step('/company-settings?tab=branding', '[role="tablist"] button',
           'Branding', 'Customize your company colors, logo, and portal branding in the Branding tab.'),
      step('/company-settings?tab=communications', '[role="tablist"] button',
           'Communications', 'Configure email and SMS settings, templates, and notification preferences.'),
      step('/company-settings?tab=finance', '[role="tablist"] button',
           'Finance', 'Set up payment processing, tax settings, draw schedule templates, and commission rules.')
    ]
  }
].freeze

# ------------------------------------------------------------------
# Apply tour rebuilds
# ------------------------------------------------------------------
rebuilt    = 0
created    = 0
unresolved = []

TOURS.each_with_index do |spec, idx|
  mod = resolve_module(spec[:module_key])
  unless mod
    unresolved << [spec[:key], spec[:module_key]]
    next
  end

  tour = Tour.find_or_initialize_by(key: spec[:key])
  was_new = tour.new_record?
  tour.assign_attributes(
    name:                spec[:name],
    description:         spec[:description],
    trigger_type:        spec[:trigger_type],
    is_active:           true,
    position:            idx + 1,
    knowledge_module_id: mod.id
  )
  tour.save!
  was_new ? (created += 1) : (rebuilt += 1)

  # Delete-and-recreate keeps position uniqueness trivially satisfied.
  tour.steps.destroy_all
  spec[:steps].each_with_index do |sd, i|
    tour.steps.create!(
      position:       i + 1,
      route:          sd[:route],
      selector:       sd[:selector],
      title:          sd[:title],
      content:        sd[:content],
      placement:      sd[:placement] || 'bottom',
      highlight_type: 'outline',
      click_required: false,
      input_required: false
    )
  end
end

puts "Rebuilt #{rebuilt} existing tours; created #{created} new tours"
puts "Unresolved modules: #{unresolved.inspect}" unless unresolved.empty?

# ------------------------------------------------------------------
# Backfill remaining tours' step routes to their module route
# ------------------------------------------------------------------
rebuilt_keys = TOURS.map { |s| s[:key] }
backfilled = 0
other_tours = 0
Tour.active.where.not(key: rebuilt_keys).includes(:knowledge_module).each do |tour|
  other_tours += 1
  mod_route = tour.knowledge_module&.route
  next if mod_route.blank?
  n = tour.steps.where(route: [nil, '']).update_all(route: mod_route)
  backfilled += n
end
puts "Backfilled #{backfilled} missing routes across #{other_tours} other tours"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
puts ""
puts "=== Rebuilt tours summary ==="
TOURS.each do |spec|
  t = Tour.find_by(key: spec[:key])
  printf "  %-32s steps=%d trigger=%s module=%s\n",
         spec[:key], t&.steps&.count || 0, t&.trigger_type, t&.knowledge_module&.key
end

puts ""
puts "=== All active tours ==="
Tour.active.ordered.includes(:knowledge_module).each do |t|
  printf "  %-32s %-22s route=%s\n", t.key, t.knowledge_module&.key, t.knowledge_module&.route
end

puts ""
puts "Total active tours: #{Tour.active.count}"
orphan = TourStep.joins(:tour).where(route: nil).where(tours: { is_active: true }).count
puts "Active tour steps missing route: #{orphan}"
