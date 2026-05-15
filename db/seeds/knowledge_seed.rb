# frozen_string_literal: true

# Seeds the unified knowledge base from the backend scan file plus curated
# lookup tables (intent patterns, entity aliases, onboarding tours).
#
# Idempotent: every record is find_or_create_by on a natural key.
#
# Run with:
#   bin/rails runner db/seeds/knowledge_seed.rb
#
# or include in db/seeds.rb:
#   load Rails.root.join('db', 'seeds', 'knowledge_seed.rb')

require 'json'

SCAN_PATH = Rails.root.join('knowledge-scan-backend.json')
abort "Scan file not found at #{SCAN_PATH}" unless File.exist?(SCAN_PATH)

SCAN = JSON.parse(File.read(SCAN_PATH))
puts "📚 Seeding knowledge base from #{SCAN_PATH.basename} " \
     "(#{SCAN['modules'].size} modules, #{SCAN['summary']['routes_count']} routes)"

# =============================================================================
# Module metadata — curated names, descriptions, icons, default routes.
# Anything not in this table falls back to titleized key + "box" icon.
# =============================================================================
MODULE_META = {
  'accounts'            => { name: 'Accounts',               icon: 'building-2',    desc: 'Customer and business accounts — the B2B side of your CRM.' },
  'accounting'          => { name: 'Accounting',             icon: 'calculator',    desc: 'Chart of accounts, journal entries, bills, bank transactions, reconciliation, and financial reports.' },
  'activities'          => { name: 'Activities',             icon: 'activity',      desc: 'Activity log across leads, deals, and users.' },
  'agreements'          => { name: 'Agreements & E-Sign',    icon: 'file-signature', desc: 'Contracts, agreement templates, and e-signature workflows.' },
  'ai'                  => { name: 'AI Insights',            icon: 'sparkles',      desc: 'AI-generated insights, suggestions, and smart actions.' },
  'api_keys'            => { name: 'API Keys',               icon: 'key-round',     desc: 'Programmatic access tokens for integrations.' },
  'approvals'           => { name: 'Approvals',              icon: 'check-check',   desc: 'Approval workflows for deals, discounts, and more.' },
  'auth'                => { name: 'Authentication',         icon: 'shield-check',  desc: 'Login, session, MFA, and password flows.' },
  'blog_cms'            => { name: 'Blog CMS',               icon: 'newspaper',     desc: 'Public blog content management.' },
  'brochures'           => { name: 'Brochures',              icon: 'book-open',     desc: 'Generate and send marketing brochures for inventory.' },
  'buyers_documents'    => { name: 'Buyer Documents',        icon: 'folder-archive', desc: 'Documents collected from buyers during a deal.' },
  'calendar'            => { name: 'Calendar',               icon: 'calendar-days', desc: 'Appointments and team calendar.' },
  'champion_ims'        => { name: 'Champion IMS',           icon: 'home',          desc: 'Champion Homes manufacturer sync and catalog.' },
  'commissions'         => { name: 'Commissions',            icon: 'percent',       desc: 'Commission plans, calculations, and payouts.' },
  'communications'      => { name: 'Communications',         icon: 'message-circle', desc: 'Email, SMS, and threaded conversations.' },
  'companies'           => { name: 'Companies',              icon: 'building',      desc: 'Tenant companies on the platform.' },
  'configurator'        => { name: 'Configurator',           icon: 'sliders-horizontal', desc: 'Interactive product configurator and pricing.' },
  'contacts'            => { name: 'Contacts',               icon: 'user',          desc: 'Individual contacts — the B2C side of your CRM.' },
  'contractors'         => { name: 'Contractors',            icon: 'hard-hat',      desc: 'External contractor assignments and work logs.' },
  'dashboard'           => { name: 'Dashboard',              icon: 'layout-dashboard', desc: 'Role-aware home dashboard with metrics and shortcuts.' },
  'deals'               => { name: 'Deals',                  icon: 'handshake',     desc: 'Active sales opportunities from lead to close.' },
  'import_export'       => { name: 'Import / Export',        icon: 'arrow-down-up', desc: 'Bulk data import, export, and rollback.' },
  'intake_forms'        => { name: 'Intake Forms',           icon: 'clipboard-list', desc: 'Public intake forms for new leads and applications.' },
  'inventory'           => { name: 'Inventory',              icon: 'package',       desc: 'Vehicles, units, and homes available for sale.' },
  'invoices'            => { name: 'Invoices',               icon: 'receipt',       desc: 'Customer invoices and line items.' },
  'leads'               => { name: 'Leads',                  icon: 'user-plus',     desc: 'Prospective customers before they convert to deals.' },
  'listings'            => { name: 'Public Listings',        icon: 'globe',         desc: 'Public-facing inventory listings.' },
  'loans'               => { name: 'Loans & Financing',      icon: 'landmark',      desc: 'Loan applications and financing documents.' },
  'locations'           => { name: 'Locations',              icon: 'map-pin',       desc: 'Company locations, lots, and dealerships.' },
  'manufacturer_ar'     => { name: 'Manufacturer AR',        icon: 'truck',         desc: 'Accounts receivable from manufacturers.' },
  'manufacturers'       => { name: 'Manufacturers',          icon: 'factory',       desc: 'Manufacturer records and product catalog feeds.' },
  'notes'               => { name: 'Notes',                  icon: 'sticky-note',   desc: 'Notes attached to leads, deals, accounts, and more.' },
  'notifications'       => { name: 'Notifications',          icon: 'bell',          desc: 'In-app notifications and alert preferences.' },
  'nurture'             => { name: 'Nurture Sequences',      icon: 'sprout',        desc: 'Automated drip sequences for prospects.' },
  'payments'            => { name: 'Payments',               icon: 'credit-card',   desc: 'Payment capture, fees, and payment providers.' },
  'platform_admin'      => { name: 'Platform Admin',         icon: 'crown',         desc: 'Super-admin tools across all tenant companies.' },
  'portal'              => { name: 'Buyer Portal',           icon: 'user-round',    desc: 'Self-service portal for buyers to view their deal.' },
  'projects'            => { name: 'Projects',               icon: 'kanban',        desc: 'Project tracking for service and setup work.' },
  'quickbooks'          => { name: 'QuickBooks',             icon: 'book-copy',     desc: 'QuickBooks sync for invoices and payments.' },
  'quotes'              => { name: 'Quotes',                 icon: 'file-text',     desc: 'Sales quotes and proposals.' },
  'rbac_admin'          => { name: 'Roles & Permissions',    icon: 'lock-keyhole',  desc: 'Role-based access control, roles, and permission grants.' },
  'reminders'           => { name: 'Reminders',              icon: 'alarm-clock',   desc: 'Reminders attached to activities and tasks.' },
  'reports'             => { name: 'Reports',                icon: 'bar-chart-3',   desc: 'Saved reports and analytics dashboards.' },
  'search'              => { name: 'Search',                 icon: 'search',        desc: 'Global search across the platform.' },
  'service'             => { name: 'Service',                icon: 'wrench',        desc: 'Service tickets and warranty repairs.' },
  'sources'             => { name: 'Lead Sources',           icon: 'megaphone',     desc: 'Campaigns and channels that generate leads.' },
  'sync'                => { name: 'Sync',                   icon: 'refresh-cw',    desc: 'Integration sync status and history.' },
  'tags'                => { name: 'Tags',                   icon: 'tag',           desc: 'Tags for categorizing leads, deals, and contacts.' },
  'tasks'               => { name: 'Tasks',                  icon: 'check-square',  desc: 'User task list and assignments.' },
  'templates'           => { name: 'Templates',              icon: 'copy',          desc: 'Reusable communication and document templates.' },
  'territories'         => { name: 'Territories',            icon: 'map',           desc: 'Sales territories and assignments.' },
  'uploads'             => { name: 'Uploads',                icon: 'upload',        desc: 'File upload endpoints and S3 presigning.' },
  'users'               => { name: 'Team Members',           icon: 'users',          desc: 'Users in your company.' },
  'warranty'            => { name: 'Warranty',               icon: 'shield',        desc: 'Warranty registration and claims.' },
  'webhooks'            => { name: 'Webhooks',               icon: 'webhook',       desc: 'Outbound webhooks and delivery history.' },
  'website_builder'     => { name: 'Website Builder',        icon: 'layout-template', desc: 'Brochure and micro-site builder.' },
  'workflow_automation' => { name: 'Workflow Automation',    icon: 'workflow',      desc: 'Event-driven workflow engine.' },
  'zego'                => { name: 'Zego Payments',          icon: 'wallet',        desc: 'Zego payment integration for rent and loan payments.' }
}.freeze

# =============================================================================
# 1. knowledge_modules — one row per scanned module
# =============================================================================
puts "→ Seeding knowledge_modules..."

module_records = {}
position = 0

SCAN['modules'].each do |mod|
  key = mod['key']
  next if key == '_framework' # internal grouping, not a user-facing module

  position += 1
  meta = MODULE_META[key] || { name: key.tr('_', ' ').split.map(&:capitalize).join(' '),
                               icon: 'box',
                               desc: nil }

  # Pick a representative route: the first GET on an index-ish path
  default_route =
    (mod['routes'] || []).find { |r| r['method'] == 'GET' && r['path'] !~ /:/ }&.fetch('path') ||
    (mod['routes'] || []).find { |r| r['method'] == 'GET' }&.fetch('path')

  rec = Knowledge::Module.find_or_initialize_by(key: key)
  rec.assign_attributes(
    name:        meta[:name],
    description: meta[:desc],
    icon:        meta[:icon],
    route:       default_route,
    position:    position,
    is_active:   true
  )
  rec.save!
  module_records[key] = rec
end
puts "  created/updated #{module_records.size} modules"

# =============================================================================
# 2. knowledge_features — CRUD + import/export per module, plus named workflows
# =============================================================================
puts "→ Seeding knowledge_features..."

# Verbs we want to generate features for, keyed by action suffix in permissions.
CRUD_FEATURES = [
  { key: 'list',    name: 'View',       action: 'read',   desc_template: 'List and browse %{plural}.' },
  { key: 'create',  name: 'Create',     action: 'create', desc_template: 'Add a new %{singular}.' },
  { key: 'update',  name: 'Edit',       action: 'update', desc_template: 'Modify an existing %{singular}.' },
  { key: 'delete',  name: 'Delete',     action: 'delete', desc_template: 'Remove a %{singular}.' },
  { key: 'import',  name: 'Import',     action: 'import', desc_template: 'Bulk-import %{plural} from a file.' },
  { key: 'export',  name: 'Export',     action: 'export', desc_template: 'Export %{plural} to a file.' }
].freeze

# Crude plural/singular mapping — good enough for UI copy.
def humanize_module(key)
  plural   = key.tr('_', ' ')
  singular = plural.sub(/s$/, '').sub(/ie$/, 'y')
  [singular, plural]
end

feature_count = 0

SCAN['modules'].each do |mod|
  key = mod['key']
  next if key == '_framework'

  parent = module_records[key]
  singular, plural = humanize_module(key)

  # Which CRUD actions does this module actually have permissions for?
  # Permissions come as "resource:action" (e.g. "leads:read"). We look at any
  # permission whose resource prefix seems tied to this module OR matches a
  # canonical RBAC resource linked to the module.
  perms         = Array(mod['permissions'])
  present_acts  = perms.filter_map { |p| p.split(':').last }.to_set
  resource_prefix = perms.first&.split(':')&.first || key

  feature_pos = 0
  CRUD_FEATURES.each do |feat|
    next unless present_acts.include?(feat[:action])

    feature_pos += 1
    permission_key = "#{resource_prefix}:#{feat[:action]}"

    # Pick a likely route for this feature. Heuristic — not perfect, but points
    # users somewhere real.
    feature_route =
      case feat[:action]
      when 'read'
        (mod['routes'] || []).find { |r| r['method'] == 'GET' && r['path'] !~ /:/ }&.fetch('path')
      when 'create'
        (mod['routes'] || []).find { |r| r['method'] == 'POST' && r['path'] !~ /:/ }&.fetch('path')
      when 'update'
        (mod['routes'] || []).find { |r| %w[PATCH PUT].include?(r['method']) }&.fetch('path')
      when 'delete'
        (mod['routes'] || []).find { |r| r['method'] == 'DELETE' }&.fetch('path')
      when 'import'
        (mod['routes'] || []).find { |r| r['path'].to_s.include?('import') }&.fetch('path')
      when 'export'
        (mod['routes'] || []).find { |r| r['path'].to_s.include?('export') }&.fetch('path')
      end

    rec = Knowledge::Feature.find_or_initialize_by(
      knowledge_module_id: parent.id,
      key: feat[:key]
    )
    rec.assign_attributes(
      name:           "#{feat[:name]} #{plural.split.map(&:capitalize).join(' ')}",
      description:    format(feat[:desc_template], plural: plural, singular: singular),
      route:          feature_route,
      permission_key: permission_key,
      position:       feature_pos
    )
    rec.save!
    feature_count += 1
  end

  # Add named workflow features — any route whose action is a non-CRUD verb.
  # e.g. leads#convert, lead_scores#calculate, champion_ims#sync.
  named_actions = (mod['routes'] || []).each_with_object({}) do |r, h|
    act = r['action'].to_s.split.first.to_s
    next if %w[index show create update destroy new edit].include?(act)
    next if act.empty?
    h[act] ||= r['path']
  end

  named_actions.first(6).each do |act, path|
    feature_pos += 1
    name = act.tr('_', ' ').split.map(&:capitalize).join(' ')
    rec  = Knowledge::Feature.find_or_initialize_by(
      knowledge_module_id: parent.id,
      key: "action_#{act}"
    )
    rec.assign_attributes(
      name:           "#{name} #{plural.split.map(&:capitalize).join(' ')}".strip,
      description:    "#{name} operation on #{plural}.",
      route:          path,
      permission_key: "#{resource_prefix}:#{act}",
      position:       feature_pos
    )
    rec.save!
    feature_count += 1
  end
end
puts "  created/updated #{feature_count} features"

# =============================================================================
# 3. knowledge_intent_patterns — regex mappings for the smart-help search box
# =============================================================================
puts "→ Seeding knowledge_intent_patterns..."

INTENT_PATTERNS = [
  # intent, pattern, entity_key, priority
  ['create',    '\b(how (do|can) i|how to)\s+(create|add|make|new|start|begin)\b',                 nil, 100],
  ['create',    '\b(i (want|need) to|can i)\s+(create|add|make|start)\b',                          nil,  90],
  ['update',    '\b(how (do|can) i|how to)\s+(edit|update|change|modify|rename|set)\b',            nil, 100],
  ['update',    '\b(i (want|need) to)\s+(edit|update|change|modify)\b',                            nil,  90],
  ['delete',    '\b(how (do|can) i|how to)\s+(delete|remove|archive|deactivate)\b',                nil, 100],
  ['delete',    '\b(i (want|need) to)\s+(delete|remove|archive)\b',                                nil,  90],
  ['search',    '\b(how (do|can) i|how to)\s+(find|search|look (for|up)|filter)\b',                nil, 100],
  ['search',    '\b(where (are|is) (all |my )?my?)\b',                                             nil,  80],
  ['navigate',  '\b(where (is|can i find)|show me|take me to|go to|navigate to|open)\b',           nil, 100],
  ['explain',   '\b(what (is|are|does)|explain|help (me )?(with|understand)|tell me about)\b',     nil, 100],
  ['explain',   '\b(what is the difference between|compare)\b',                                    nil,  80],
  ['report',    '\b(report|dashboard|analytics|metrics|chart|graph)\b',                            'reports', 70],
  ['configure', '\b(configure|setup|set up|enable|disable|turn (on|off))\b',                       nil,  85]
].freeze

intent_count = 0
INTENT_PATTERNS.each do |intent_type, pattern, entity_key, priority|
  rec = Knowledge::IntentPattern.find_or_initialize_by(pattern: pattern, intent_type: intent_type)
  rec.assign_attributes(entity_key: entity_key, priority: priority)
  rec.save!
  intent_count += 1
end
puts "  created/updated #{intent_count} intent patterns"

# =============================================================================
# 4. knowledge_entity_aliases — domain synonyms for the MH / dealer world
# =============================================================================
puts "→ Seeding knowledge_entity_aliases..."

# shape: [canonical_key, [aliases...], entity_type]
ENTITY_ALIASES = [
  ['leads',       %w[prospect prospects interest inquiry inquiries],                    'module'],
  ['contacts',    %w[person people customer customers individual individuals buyer buyers], 'module'],
  ['accounts',    %w[business businesses organization organizations company],            'module'],
  ['deals',       %w[sale sales opportunity opportunities transaction transactions],     'module'],
  ['inventory',   %w[home homes unit units vehicle vehicles coach rv mh mobile-home manufactured-home], 'module'],
  ['users',       ['team', 'team member', 'team members', 'team-member', 'team-members',
                   'staff', 'employee', 'employees', 'rep', 'reps', 'user'],              'module'],
  ['tasks',       %w[todo to-do to-dos todos follow-up follow-ups],                      'module'],
  ['activities',  %w[log history timeline audit],                                        'module'],
  ['commissions', %w[comp compensation commission payout payouts],                       'module'],
  ['agreements',  %w[contract contracts paperwork document e-sign esign signature],      'module'],
  ['invoices',    %w[bill bills invoice statement statements],                           'module'],
  ['quotes',      %w[quote proposal proposals estimate estimates pricing],               'module'],
  ['loans',       %w[loan financing finance lender credit-app credit application],      'module'],
  ['sources',     %w[campaign campaigns channel channels referral referrals],            'module'],
  ['reports',     %w[report analytics dashboard metrics kpi kpis],                       'module'],
  ['rbac_admin',  %w[permission permissions role roles access security],                 'module'],
  ['locations',   %w[location lot lots dealership dealerships store stores branch branches], 'module'],
  ['territories', %w[region regions area areas zone zones],                              'module'],
  ['tags',        %w[tag label labels category categories],                              'module'],
  ['notes',       %w[note comment comments memo memos],                                  'module'],
  ['portal',      %w[buyer-portal customer-portal client-portal],                        'module'],
  ['service',     %w[repair repairs warranty-claim ticket tickets],                      'module'],
  ['nurture',     %w[drip sequence sequences campaign-flow],                             'module'],
  ['calendar',    %w[appointment appointments meeting meetings schedule],                'module'],
  ['accounting', %w[accounting gl general-ledger chart-of-accounts coa journal-entry journal-entries bills expenses bank-transactions reconciliation p-and-l profit-and-loss balance-sheet ap accounts-payable ar-aging], 'module']
].freeze

alias_count = 0
ENTITY_ALIASES.each do |canonical, aliases, entity_type|
  aliases.each do |a|
    rec = Knowledge::EntityAlias.find_or_initialize_by(
      entity_type: entity_type,
      alias_name:  a
    )
    rec.canonical_key = canonical
    rec.save!
    alias_count += 1
  end
end
puts "  created/updated #{alias_count} entity aliases"

# =============================================================================
# 5. Initial tours — first-time onboarding walkthroughs
# =============================================================================
puts "→ Seeding tours..."

TOURS = [
  {
    module_key:    'dashboard',
    key:           'first_time_onboarding',
    name:          'Welcome to Renter Insight',
    description:   'A quick tour of the dashboard and main navigation for first-time users.',
    trigger_type:  'auto_on_first_visit',
    position:      1,
    steps: [
      { selector: 'body',                          title: 'Welcome!',           content: "You're in. Let's take a 60-second tour of what's here.", placement: 'center', highlight_type: 'overlay' },
      { selector: '[data-tour="sidebar"]',        title: 'Main navigation',    content: 'Every major area of the app lives in this sidebar — leads, deals, inventory, and more.', placement: 'right' },
      { selector: '[data-tour="dashboard-cards"]', title: 'At-a-glance metrics', content: 'Your role-aware dashboard cards surface what needs your attention right now.', placement: 'bottom' },
      { selector: '[data-tour="global-search"]',  title: 'Smart help & search', content: 'Ask a question in plain English — "how do I create a lead?" — and we will take you there.', placement: 'bottom' },
      { selector: '[data-tour="user-menu"]',      title: 'Your profile',       content: 'Settings, notifications, and sign-out all live here.', placement: 'left' }
    ]
  },
  {
    module_key:    'leads',
    key:           'create_first_lead',
    name:          'Add your first lead',
    description:   'Walk through adding a new lead from scratch.',
    trigger_type:  'manual',
    position:      1,
    steps: [
      { selector: '[data-tour="leads-new-button"]', title: 'Start a new lead', content: 'Click here to open the new-lead form.', placement: 'bottom', click_required: true },
      { selector: '[name="first_name"]',           title: 'Name',             content: 'Their first and last name. Email and phone help us route and dedupe.', placement: 'right', input_required: true },
      { selector: '[name="source"]',               title: 'Where did they come from?', content: 'Pick a lead source so your marketing ROI reports stay honest.', placement: 'right' },
      { selector: '[data-tour="assign-to"]',       title: 'Assign an owner',  content: 'Assigning right away means the lead does not sit in limbo.', placement: 'right' },
      { selector: '[data-tour="save-lead"]',       title: 'Save',             content: 'That is it. From here you can add notes, schedule a follow-up, or convert to a deal.', placement: 'top' }
    ]
  },
  {
    module_key:    'deals',
    key:           'create_first_deal',
    name:          'Create your first deal',
    description:   'Turn a lead into an active deal and set up the sale.',
    trigger_type:  'manual',
    position:      1,
    steps: [
      { selector: '[data-tour="deals-new-button"]',      title: 'New deal',          content: 'Either start from scratch or convert an existing lead.', placement: 'bottom' },
      { selector: '[data-tour="deal-inventory-picker"]', title: 'Pick the unit',     content: 'Attach the specific home or vehicle being sold.', placement: 'right' },
      { selector: '[data-tour="deal-pricing"]',          title: 'Price and terms',   content: 'Line items, discounts, trade-in — all live here.', placement: 'right' },
      { selector: '[data-tour="deal-stage"]',            title: 'Pipeline stage',    content: 'Set the stage so this deal shows up in the right pipeline column.', placement: 'bottom' },
      { selector: '[data-tour="deal-save"]',             title: 'Save the deal',     content: 'The deal is now on the board and ready for paperwork, financing, and delivery.', placement: 'top' }
    ]
  },
  {
    module_key:    'invoices',
    key:           'create_first_invoice',
    name:          'Create your first invoice',
    description:   'Generate an invoice and mark it ready to send.',
    trigger_type:  'manual',
    position:      1,
    steps: [
      { selector: '[data-tour="invoices-new-button"]', title: 'Start the invoice', content: 'Invoices can be created from a deal or directly here.', placement: 'bottom' },
      { selector: '[data-tour="invoice-customer"]',    title: 'Pick a customer',   content: 'Start typing a name — contacts and accounts both show up.', placement: 'right' },
      { selector: '[data-tour="invoice-lines"]',       title: 'Line items',        content: 'Add as many line items as you need. Subtotal and tax calculate automatically.', placement: 'right' },
      { selector: '[data-tour="invoice-terms"]',       title: 'Terms & due date',  content: 'Net 30 is the default. Override when needed.', placement: 'right' },
      { selector: '[data-tour="invoice-send"]',        title: 'Send it',           content: 'Email it directly, or save as draft to send later.', placement: 'top' }
    ]
  }
].freeze

tour_count = 0
step_count = 0

TOURS.each do |spec|
  parent = module_records[spec[:module_key]]
  next unless parent # defensive — spec mentions a module not in the scan

  tour = Tour.find_or_initialize_by(knowledge_module_id: parent.id, key: spec[:key])
  tour.assign_attributes(
    name:         spec[:name],
    description:  spec[:description],
    trigger_type: spec[:trigger_type],
    position:     spec[:position],
    is_active:    true
  )
  tour.save!
  tour_count += 1

  spec[:steps].each_with_index do |step_spec, idx|
    step = TourStep.find_or_initialize_by(tour_id: tour.id, position: idx + 1)
    step.assign_attributes(
      selector:       step_spec[:selector],
      title:          step_spec[:title],
      content:        step_spec[:content],
      placement:      step_spec[:placement]       || 'bottom',
      highlight_type: step_spec[:highlight_type]  || 'outline',
      click_required: step_spec[:click_required]  || false,
      input_required: step_spec[:input_required]  || false
    )
    step.save!
    step_count += 1
  end
end
puts "  created/updated #{tour_count} tours and #{step_count} steps"

puts "✅ Knowledge base seed complete."
puts "   modules: #{Knowledge::Module.count}"
puts "   features: #{Knowledge::Feature.count}"
puts "   intent patterns: #{Knowledge::IntentPattern.count}"
puts "   entity aliases: #{Knowledge::EntityAlias.count}"
puts "   tours: #{Tour.count} (#{TourStep.count} steps)"
