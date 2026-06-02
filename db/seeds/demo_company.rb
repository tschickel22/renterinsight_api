# db/seeds/demo_company.rb
#
# Creates a realistic demo company for prospect demos.
#
# Usage:
#   bin/rails runner "load 'db/seeds/demo_company.rb'"
#
# Reset & re-seed:
#   RESET=true bin/rails runner "load 'db/seeds/demo_company.rb'"
#
# Additional companies:
#   DEMO_NAME='ABC Homes' DEMO_PREFIX='abc' bin/rails runner "load 'db/seeds/demo_company.rb'"
#

DEMO_PASSWORD = "Demo2026!"
DEMO_PREFIX = ENV['DEMO_PREFIX'] || 'sunshine'
DEMO_COMPANY_NAME = ENV['DEMO_NAME'] || "Sunshine MH Homes"
DEMO_EMAIL_DOMAIN = "#{DEMO_PREFIX}demo.com"

S3_STAGING = "https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com"
S3_FDHC    = "https://factory-direct-homescenter.s3.us-east-1.amazonaws.com"

puts "=" * 60
puts "DEMO COMPANY SEEDER"
puts "=" * 60
puts "  Company: #{DEMO_COMPANY_NAME}"
puts "  Emails:  *@#{DEMO_EMAIL_DOMAIN}"
puts "  Password: #{DEMO_PASSWORD}"
puts ""
puts "  For additional companies:"
puts "    DEMO_NAME='ABC Homes' DEMO_PREFIX='abc' bin/rails runner \"load 'db/seeds/demo_company.rb'\""
puts "=" * 60

# ── Reset if requested ─────────────────────────────────────
if ENV['RESET'] == 'true'
  existing = Company.find_by(name: DEMO_COMPANY_NAME)
  if existing
    puts "\nResetting existing demo company (ID: #{existing.id})..."
    %i[
      buyer_portal_accesses
      budgets budget_lines
      manufacturer_ar_payments manufacturer_ar_transactions
      payments payment_methods
      bills bill_line_items bill_payments
      journal_entries journal_entry_lines
      bank_reconciliations bank_reconciliation_items bank_transactions
      chart_of_accounts accounting_settings
      campaigns campaign_audiences campaign_enrollments campaign_sends
        campaign_steps campaign_events
      workflow_rules workflow_runs
      deals quotes invoices
      projects project_templates project_phases project_tasks
      project_cost_items project_material_usages project_documents
      purchase_orders purchase_order_lines
      parts suppliers vendors service_tickets
      contacts accounts
      leads vehicles units properties
      nurture_sequences nurture_steps nurture_enrollments
      page_layouts custom_fields
      tasks sources territories
      commission_payments commissions commission_rules commission_plans
      tags bank_accounts
      tenant_module_overrides api_keys webhook_endpoints
      brochures listings
      agreements agreement_signers agreement_templates agreement_categories
      warranty_claims contractor_assignments contractors
      company_hidden_roles company_manufacturers
      payments payment_methods loans land_parcels invitations templates
      part_categories inventory_transactions stock_balances reorder_rules
      commission_components
      locations
    ].each do |assoc|
      next unless existing.respond_to?(assoc)
      ref = existing.class.reflect_on_association(assoc)
      next unless ref
      target = existing.send(assoc)
      if ref.macro == :has_many
        count = target.count
        target.destroy_all
        puts "  Deleted #{count} #{assoc}" if count > 0
      elsif ref.macro == :has_one && target
        target.destroy
        puts "  Deleted 1 #{assoc}"
      end
    end
    existing.users.destroy_all
    existing.roles.destroy_all if existing.respond_to?(:roles)
    existing.tenant_subscription&.destroy if existing.respond_to?(:tenant_subscription)
    existing.twilio_account&.destroy if existing.respond_to?(:twilio_account)
    # Use delete instead of destroy! to avoid cascade through stale associations
    # (Site, SiteMedium, WebsiteMedia, etc. - models that no longer exist)
    existing.delete
    puts "  Company deleted.\n"
  end
end

# ── 1. Company ─────────────────────────────────────────────
puts "\n1. Creating company..."
company = Company.find_or_create_by!(name: DEMO_COMPANY_NAME) do |c|
  c.email = "info@#{DEMO_PREFIX}mhhomes.com"
  c.phone = "(260) 555-0100"
  c.address_line1 = "4520 Homestead Road"
  c.city = "Auburn"
  c.state = "IN"
  c.zip_code = "46706"
  c.status = "active"
  c.is_demo = true
  c.external_payments_id = nil
  c.subscription_tier = "professional"
  c.use_rbac_system = true
end
puts "  Company: #{company.name} (ID: #{company.id})"

# ── 1b. Subscription (Professional plan) ─────────────────
puts "\n1b. Setting up subscription..."
pro_plan = SubscriptionPlan.find_by(name: 'professional')
if pro_plan
  sub = TenantSubscription.find_or_initialize_by(company_id: company.id)
  sub.assign_attributes(
    subscription_plan_id: pro_plan.id,
    status: 'active',
    billing_cycle: 'annual',
    current_period_start: Time.current,
    current_period_end: 1.year.from_now
  )
  sub.save!
  puts "  Subscription: #{pro_plan.display_name} (#{sub.status})"
else
  puts "  ⚠ No 'professional' plan found — run: bin/rails runner \"load 'db/seeds/subscription_plans.rb'\""
end

# ── 2. Locations ───────────────────────────────────────────
# Company auto-creates "Main Location" and "Corporate" on create.
# For a clean demo, drop Main Location, keep Corporate, and add Auburn Showroom
# as the single data-bearing location so all demo activity rolls up there.
puts "\n2. Creating locations..."
locations = {}

main_loc = company.locations.find_by(name: "Main Location")
if main_loc
  begin
    main_loc.destroy
    puts "  Removed auto-created 'Main Location'"
  rescue => e
    puts "  ⚠ Could not remove 'Main Location' (#{e.message}); leaving it"
  end
end

corporate = company.locations.find_by(name: "Corporate")
if corporate
  corporate.update!(code: "CORP") if corporate.code.blank?
  locations["CORP"] = corporate
  puts "  Location: #{corporate.name} (#{corporate.code})"
end

auburn = company.locations.find_or_create_by!(name: "Auburn Showroom") do |l|
  l.code = "AUB"
  l.address_line1 = "4520 Homestead Road"
  l.city = "Auburn"
  l.state = "IN"
  l.zip_code = "46706"
  l.phone = "(260) 555-0100"
  l.active = true
end
locations["AUB"] = auburn

# Clean up locations from prior seed runs (Fort Wayne, Indianapolis).
# Reassign any dependent records to Auburn first, then delete the locations.
stale = company.locations.where(name: ["Fort Wayne Center", "Indianapolis South"])
if stale.any?
  stale_ids = stale.pluck(:id)
  conn = ActiveRecord::Base.connection
  tables_with_location = conn.exec_query(
    "SELECT DISTINCT table_name FROM information_schema.columns " \
    "WHERE column_name = 'location_id' AND table_schema = 'public'"
  ).rows.map(&:first)
  tables_with_location.each do |t|
    conn.execute(
      "UPDATE #{t} SET location_id = #{auburn.id} " \
      "WHERE location_id IN (#{stale_ids.join(',')})"
    ) rescue nil
  end
  removed = stale.delete_all
  puts "  Removed #{removed} stale locations (Fort Wayne / Indianapolis), reassigned data to Auburn"
end

# THREE DISTINCT operating locations so the reports' location grouping (Report 1
# rows + Report 2 funded-by-location) shows real groups. Names differ from the
# section-above stale list ("Fort Wayne Center"/"Indianapolis South") so the
# cleanup never deletes these on re-run — keeps location_id stable + idempotent.
fort_wayne = company.locations.find_or_create_by!(name: "Fort Wayne") do |l|
  l.code = "FTW"
  l.address_line1 = "1820 Coliseum Blvd"
  l.city = "Fort Wayne"
  l.state = "IN"
  l.zip_code = "46805"
  l.phone = "(260) 555-0200"
  l.active = true
end
locations["FTW"] = fort_wayne

indianapolis = company.locations.find_or_create_by!(name: "Indianapolis") do |l|
  l.code = "IND"
  l.address_line1 = "3400 S Meridian St"
  l.city = "Indianapolis"
  l.state = "IN"
  l.zip_code = "46217"
  l.phone = "(317) 555-0300"
  l.active = true
end
locations["IND"] = indianapolis
puts "  Locations: #{auburn.code}, #{fort_wayne.code}, #{indianapolis.code} (3 distinct)"

# ── 3. Users ───────────────────────────────────────────────
puts "\n3. Creating users..."
users = {}

user_list = [
  { key: :admin,   email: "admin@#{DEMO_EMAIL_DOMAIN}",   first: "Tom",     last: "Mitchell",  role: "company_admin" },
  { key: :manager, email: "sarah@#{DEMO_EMAIL_DOMAIN}",   first: "Sarah",   last: "Collins",   role: "company_admin" },
  { key: :sales1,  email: "mike@#{DEMO_EMAIL_DOMAIN}",    first: "Mike",    last: "Henderson", role: "company_admin" },
  { key: :sales2,  email: "jessica@#{DEMO_EMAIL_DOMAIN}", first: "Jessica", last: "Park",      role: "company_admin" },
  { key: :tech,    email: "dave@#{DEMO_EMAIL_DOMAIN}",    first: "Dave",    last: "Torres",    role: "company_admin" },
]

user_list.each do |ud|
  user = company.users.find_or_initialize_by(email: ud[:email])
  user.assign_attributes(
    first_name: ud[:first],
    last_name: ud[:last],
    role: ud[:role],
    password: DEMO_PASSWORD,
    password_confirmation: DEMO_PASSWORD,
    status: "active"
  )
  user.save!
  users[ud[:key]] = user
  puts "  User: #{user.email} (#{ud[:role]})"
end

# ── 4. RBAC Roles ──────────────────────────────────────────
puts "\n4. Assigning RBAC roles..."
# Use system roles (seeded by rbac_system_seed.rb) which already have proper permissions.
# assign_rbac_role creates UserRoleAssignment with company_id set correctly.
# Without this, build_permissions returns [] at login → empty sidebar.
{
  admin:   'company_admin',
  manager: 'company_admin',
  sales1:  'sales_rep',
  sales2:  'sales_rep',
  tech:    'service_tech',
}.each do |user_key, role_key|
  user = users[user_key]
  next unless user
  assignment = user.assign_rbac_role(role_key, company_id: company.id)
  if assignment
    puts "  #{user.email} → #{role_key}"
  else
    puts "  ⚠ Failed to assign #{role_key} to #{user.email} (role not found - run rbac_system_seed first)"
  end
end

# ── 5. Tags ────────────────────────────────────────────────
puts "\n5. Creating tags..."
tag_data = [
  { name: "Hot Lead",         color: "#EF4444" },
  { name: "VIP Customer",     color: "#F59E0B" },
  { name: "First-Time Buyer", color: "#10B981" },
  { name: "Investor",         color: "#3B82F6" },
  { name: "Referral",         color: "#8B5CF6" },
  { name: "Trade-In",         color: "#EC4899" },
  { name: "Cash Buyer",       color: "#14B8A6" },
  { name: "Financing Needed", color: "#F97316" },
  { name: "Rural Delivery",   color: "#6366F1" },
  { name: "Priority",         color: "#DC2626" },
]
tag_data.each { |td| company.tags.find_or_create_by!(name: td[:name]) { |t| t.color = td[:color] } }
puts "  Created #{tag_data.length} tags"

# ── 6. Accounts ────────────────────────────────────────────
puts "\n6. Creating accounts..."
accounts = {}

account_data = [
  { name: "21st Mortgage Corporation",  type: "partner",  website: "21stmortgage.com",  phone: "(865) 555-0100", city: "Knoxville",    state: "TN" },
  { name: "Vanderbilt Mortgage",        type: "partner",  website: "vmf.com",           phone: "(865) 555-0200", city: "Maryville",    state: "TN" },
  { name: "Cascade Financial Services", type: "partner",  website: "cascadeloans.com",  phone: "(877) 555-0300", city: "Boise",        state: "ID" },
  { name: "Martin Family Properties",   type: "customer", website: nil,                 phone: "(260) 555-0400", city: "Auburn",       state: "IN" },
  { name: "Lakeside MH Community",      type: "customer", website: "lakesidemhc.com",   phone: "(260) 555-0500", city: "Angola",       state: "IN" },
  { name: "Hoosier Land Development",   type: "prospect", website: "hoosierland.com",   phone: "(317) 555-0600", city: "Indianapolis", state: "IN" },
  { name: "Champion Home Builders",     type: "vendor",   website: "championhomes.com", phone: "(574) 555-0700", city: "Topeka",       state: "IN" },
  { name: "Redman Homes",               type: "vendor",   website: "redmanhomes.com",   phone: "(260) 555-0800", city: "Decatur",      state: "IN" },
]

account_data.each do |ad|
  acct = company.accounts.find_or_create_by!(name: ad[:name]) do |a|
    a.account_type = ad[:type]
    a.website = ad[:website]
    a.phone = ad[:phone]
    a.billing_city = ad[:city]
    a.billing_state = ad[:state]
    a.owner_id = users[:manager].id
    a.location_id = locations["AUB"].id
    a.status = "active"
    a.is_deleted = false
    a.custom_field_values = {}
  end
  accounts[ad[:name]] = acct
end
puts "  Created #{account_data.length} accounts"

# ── 7. Contacts ────────────────────────────────────────────
puts "\n7. Creating contacts..."
contacts = {}

contact_data = [
  { first: "Robert",   last: "Chen",      email: "rchen@21stmortgage.com",    phone: "(865) 555-1001", account: "21st Mortgage Corporation",  title: "Loan Officer" },
  { first: "Amanda",   last: "White",     email: "awhite@21stmortgage.com",   phone: "(865) 555-1002", account: "21st Mortgage Corporation",  title: "Sr. Underwriter" },
  { first: "James",    last: "Patterson", email: "jpatterson@vmf.com",        phone: "(865) 555-1003", account: "Vanderbilt Mortgage",        title: "Account Manager" },
  { first: "Lisa",     last: "Nguyen",    email: "lnguyen@cascadeloans.com",  phone: "(877) 555-1004", account: "Cascade Financial Services", title: "Loan Processor" },
  { first: "William",  last: "Martin",    email: "wmartin@gmail.com",         phone: "(260) 555-2001", account: "Martin Family Properties",   title: "Owner" },
  { first: "Carol",    last: "Martin",    email: "cmartin@gmail.com",         phone: "(260) 555-2002", account: "Martin Family Properties",   title: "Co-Owner" },
  { first: "Dennis",   last: "Hopper",    email: "dhopper@lakesidemhc.com",   phone: "(260) 555-2003", account: "Lakeside MH Community",      title: "Park Manager" },
  { first: "Rebecca",  last: "Stone",     email: "rstone@lakesidemhc.com",    phone: "(260) 555-2004", account: "Lakeside MH Community",      title: "Maintenance Dir." },
  { first: "Marcus",   last: "Johnson",   email: "mjohnson@hoosierland.com",  phone: "(317) 555-3001", account: "Hoosier Land Development",   title: "VP Development" },
  { first: "Patricia", last: "Adams",     email: "padams@hoosierland.com",    phone: "(317) 555-3002", account: "Hoosier Land Development",   title: "Project Manager" },
  { first: "Jeretta",  last: "Smuts",     email: "jsmuts1959@gmail.com",      phone: "(260) 227-0394", account: nil, title: nil },
  { first: "Kevin",    last: "O'Brien",   email: "kobrien88@yahoo.com",       phone: "(260) 555-4002", account: nil, title: nil },
  { first: "Maria",    last: "Gonzalez",  email: "mgonzalez@hotmail.com",     phone: "(260) 555-4003", account: nil, title: nil },
  { first: "Daniel",   last: "Crawford",  email: "dcrawford@outlook.com",     phone: "(317) 555-4004", account: nil, title: nil },
  { first: "Tammy",    last: "Fisher",    email: "tammyf@gmail.com",          phone: "(574) 555-4005", account: nil, title: nil },
  { first: "Brian",    last: "Keller",    email: "bkeller@icloud.com",        phone: "(260) 555-4006", account: nil, title: nil },
  { first: "Sandra",   last: "Mitchell",  email: "smitchell99@gmail.com",     phone: "(765) 555-4007", account: nil, title: nil },
  { first: "Jason",    last: "Turner",    email: "jturner@me.com",            phone: "(317) 555-4008", account: nil, title: nil },
  { first: "Angela",   last: "Brooks",    email: "abrooks@gmail.com",         phone: "(260) 555-4009", account: nil, title: nil },
  { first: "Raymond",  last: "Price",     email: "rprice55@yahoo.com",        phone: "(812) 555-4010", account: nil, title: nil },
]

contact_data.each do |cd|
  contact = company.contacts.find_or_create_by!(email: cd[:email]) do |c|
    c.first_name = cd[:first]
    c.last_name = cd[:last]
    c.phone = cd[:phone]
    c.title = cd[:title]
    c.account_id = cd[:account] ? accounts[cd[:account]]&.id : nil
    c.owner_id = [users[:sales1], users[:sales2], users[:manager]].sample.id
    c.location_id = [locations["AUB"], locations["FTW"]].sample.id
    c.is_deleted = false
    c.opt_out_email = false
    c.opt_out_sms = false
    c.custom_field_values = {}
  end
  contacts["#{cd[:first]} #{cd[:last]}"] = contact
end
puts "  Created #{contact_data.length} contacts"

# ── 7b. Sources (required for leads) ───────────────────────
puts "\n7b. Creating sources..."
sources = {}
[
  { name: "Website",  source_type: "online" },
  { name: "Walk-In",  source_type: "offline" },
  { name: "Referral", source_type: "offline" },
  { name: "Facebook", source_type: "online" },
  { name: "Zillow",   source_type: "online" },
].each do |sd|
  src = Source.find_or_create_by!(name: sd[:name], company_id: company.id) do |s|
    s.source_type = sd[:source_type]
    s.is_active = true
  end
  sources[sd[:name].downcase] = src
end
puts "  Created #{sources.length} sources"

# ── 8. Leads ───────────────────────────────────────────────
puts "\n8. Creating leads..."
leads = {}

lead_data = [
  { first: "Steven",   last: "Baker",    email: "sbaker@gmail.com",      phone: "(260) 555-5001", status: "new",       location: "AUB", source: "website" },
  { first: "Michelle", last: "Rivera",   email: "mrivera@yahoo.com",     phone: "(260) 555-5002", status: "new",       location: "AUB", source: "walk-in" },
  { first: "Gregory",  last: "Ward",     email: "gward@outlook.com",     phone: "(317) 555-5003", status: "new",       location: "FTW", source: "referral" },
  { first: "Dorothy",  last: "Hughes",   email: "dhughes@gmail.com",     phone: "(574) 555-5004", status: "contacted", location: "AUB", source: "facebook" },
  { first: "Larry",    last: "Coleman",  email: "lcoleman@hotmail.com",  phone: "(260) 555-5005", status: "contacted", location: "FTW", source: "website" },
  { first: "Nancy",    last: "Reed",     email: "nreed@gmail.com",       phone: "(812) 555-5006", status: "contacted", location: "IND", source: "zillow" },
  { first: "Kenneth",  last: "Stewart",  email: "kstewart@icloud.com",   phone: "(260) 555-5007", status: "qualified", location: "AUB", source: "walk-in" },
  { first: "Betty",    last: "Sanchez",  email: "bsanchez@gmail.com",    phone: "(317) 555-5008", status: "qualified", location: "FTW", source: "referral" },
  { first: "Ronald",   last: "Morris",   email: "rmorris@yahoo.com",     phone: "(260) 555-5009", status: "qualified", location: "AUB", source: "website" },
  { first: "Sharon",   last: "Bell",     email: "sbell22@gmail.com",     phone: "(574) 555-5010", status: "proposal",  location: "FTW", source: "walk-in" },
  { first: "Frank",    last: "Wood",     email: "fwood@outlook.com",     phone: "(260) 555-5011", status: "proposal",  location: "AUB", source: "facebook" },
  { first: "Helen",    last: "Rogers",   email: "hrogers@gmail.com",     phone: "(317) 555-5012", status: "proposal",  location: "IND", source: "zillow" },
  { first: "Arthur",   last: "Gray",     email: "agray@hotmail.com",     phone: "(260) 555-5013", status: "won",       location: "AUB", source: "referral" },
  { first: "Diane",    last: "Watson",   email: "dwatson@gmail.com",     phone: "(260) 555-5014", status: "won",       location: "FTW", source: "walk-in" },
  { first: "Carl",     last: "Brooks",   email: "cbrooks@yahoo.com",     phone: "(812) 555-5015", status: "lost",      location: "AUB", source: "website" },
]

lead_data.each do |ld|
  lead = company.leads.find_or_create_by!(email: ld[:email]) do |l|
    l.first_name = ld[:first]
    l.last_name = ld[:last]
    l.phone = ld[:phone]
    l.status = ld[:status]
    l.owner_id = users[:manager].id
    l.location_id = locations[ld[:location]].id
    l.source_id = sources[ld[:source]]&.id
    l.custom_field_values = {}
  end
  leads["#{ld[:first]} #{ld[:last]}"] = lead
end
puts "  Created #{lead_data.length} leads"

# ── 9. Vehicles (Inventory) ───────────────────────────────
puts "\n9. Creating vehicles (inventory)..."
vehicles = {}

vehicle_data = [
  { year: 2026, make: "Champion",      model: "Aspire DAP1676H32222",   serial: "112-000-H-D-C412913A", beds: 3, baths: 2, sqft: 1155, price: 87489,  cost: 65000, status: "available",  location: "AUB",
    images: [
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-exterior.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-kitchen.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-living-room.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-master-bedroom.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-bathroom.jpg",
    ],
    floor_plan: "#{S3_FDHC}/floorplans/Dutch%20Aspire%201676H32222.png" },
  { year: 2026, make: "Champion",      model: "Emerald Sky 4483A",      serial: "112-000-H-A-C412920B", beds: 4, baths: 2, sqft: 1680, price: 124900, cost: 92000, status: "reserved",  location: "AUB",
    images: [
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-exterior.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-kitchen.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-living-room.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-master-bedroom.jpg",
    ],
    floor_plan: nil },
  { year: 2026, make: "Champion",      model: "Genesis 3276A",          serial: "112-000-H-A-C412925C", beds: 3, baths: 2, sqft: 1493, price: 98500,  cost: 72000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2025, make: "Champion",      model: "Momentum MMT2856A",      serial: "112-000-H-A-C412800D", beds: 3, baths: 2, sqft: 1344, price: 79900,  cost: 58000, status: "sold",       location: "AUB", images: [], floor_plan: "#{S3_FDHC}/floorplans/Silverton%202856H32174.png" },
  { year: 2026, make: "Champion",      model: "Heritage 1676H",         serial: "112-000-H-H-C412930E", beds: 2, baths: 1, sqft: 960,  price: 54900,  cost: 40000, status: "available",  location: "IND", images: [], floor_plan: "#{S3_FDHC}/floorplans/Dutch%20Aspire%201676H32221.png" },
  { year: 2026, make: "Champion",      model: "Aspire DAP2064H42222",   serial: "112-000-H-D-C412935F", beds: 4, baths: 2, sqft: 1984, price: 145000, cost: 108000, status: "pending",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Redman",        model: "RM2856A",                serial: "RMN-2026-A-001234",    beds: 3, baths: 2, sqft: 1344, price: 82500,  cost: 60000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Redman",        model: "RM3264A",                serial: "RMN-2026-A-001235",    beds: 3, baths: 2, sqft: 1536, price: 96700,  cost: 71000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2025, make: "Redman",        model: "RM1660A",                serial: "RMN-2025-A-001100",    beds: 2, baths: 1, sqft: 960,  price: 49900,  cost: 36000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Redman",        model: "RM4068A",                serial: "RMN-2026-A-001240",    beds: 4, baths: 2, sqft: 2040, price: 138000, cost: 102000, status: "available_to_order",  location: "FTW", images: [], floor_plan: nil },
  { year: 2025, make: "Redman",        model: "RM2448A",                serial: "RMN-2025-A-001150",    beds: 3, baths: 2, sqft: 1152, price: 68500,  cost: 50000, status: "sold",       location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 2872A",            serial: "DH-2026-A-005001",     beds: 3, baths: 2, sqft: 1536, price: 105000, cost: 77000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 3268A",            serial: "DH-2026-A-005002",     beds: 3, baths: 2, sqft: 1632, price: 118500, cost: 87000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 1676S",            serial: "DH-2026-S-005003",     beds: 2, baths: 1, sqft: 1056, price: 62000,  cost: 45000, status: "available",  location: "IND", images: [], floor_plan: nil },
  { year: 2025, make: "Dutch Housing", model: "Dutch 2460A",            serial: "DH-2025-A-004990",     beds: 3, baths: 2, sqft: 1200, price: 74900,  cost: 55000, status: "sold",       location: "AUB", images: [], floor_plan: nil },
  { year: 2019, make: "Clayton",       model: "TRU The Satisfaction",   serial: "CLT-2019-T-889900",    beds: 3, baths: 2, sqft: 1120, price: 35000,  cost: 22000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2021, make: "Skyline",       model: "Amber Cove 266CT",       serial: "SKY-2021-A-776600",    beds: 3, baths: 2, sqft: 1216, price: 42500,  cost: 28000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2017, make: "Fleetwood",     model: "Berkshire 3252B",        serial: "FLT-2017-B-554400",    beds: 4, baths: 2, sqft: 1664, price: 38000,  cost: 20000, status: "available",  location: "AUB", images: [], floor_plan: nil },
]

# Deterministic days-in-stock spread so the AGE column + aging buckets (0-30 /
# 31-60 / 61-90 / 90+) all demonstrate. Stable across re-runs (indexed, no random).
stock_ages = [9, 17, 24, 28, 41, 52, 70, 84, 96, 118, 160, 205, 240, 290, 335, 355, 76, 132]

vehicle_data.each_with_index do |vd, idx|
  age_days = stock_ages[idx % stock_ages.length]
  # Single (1) vs double (2) section by size so units classify into the proper
  # New/Used — Single/Double Section buckets instead of "Section Count Not Entered".
  veh_sections = (vd[:sqft].to_i >= 1400 || vd[:beds].to_i >= 4) ? 2 : 1
  # Lowercase new/used so Report 1's section_for matches; older units read as used.
  veh_condition = vd[:year].to_i >= 2023 ? "new" : "used"

  vehicle = company.vehicles.find_or_create_by!(serial_number: vd[:serial]) do |v|
    v.year = vd[:year]
    v.make = vd[:make]
    v.model = vd[:model]
    v.stock_number = "#{DEMO_PREFIX.upcase}-#{(idx + 1).to_s.rjust(3, '0')}"
    v.status = vd[:status]
    v.location_id = locations[vd[:location]].id
    v.sale_price = vd[:price]
    v.dealer_cost = vd[:cost]
    v.cost = vd[:cost]
    v.bedrooms = vd[:beds]
    v.bathrooms = vd[:baths]
    v.square_feet = vd[:sqft]
    v.condition = veh_condition
    v.sections = veh_sections
    v.date_in_stock = age_days.days.ago.to_date
    v.home_type = "Manufactured"
    v.listing_type = "manufactured_home"
    v.is_deleted = false
    v.floor_plan_images = []
    v.custom_field_values = {}
    if vd[:images].present?
      v.images = vd[:images].map { |url| { 'url' => url } }
      v.photo_url = vd[:images].first
    end
    if vd[:floor_plan].present?
      v.floor_plan_images = [{ 'url' => vd[:floor_plan] }]
      if vd[:images].blank?
        v.photo_url = vd[:floor_plan]
        v.images = [{ 'url' => vd[:floor_plan] }]
      end
    end
  end
  # Backfill the report-relevant fields on every run (the create block above only
  # fires for new records) so previously-seeded demo companies populate the reports.
  vehicle.update_columns(
    date_in_stock: age_days.days.ago.to_date,
    sections: veh_sections,
    condition: veh_condition,
    location_id: locations[vd[:location]].id
  )
  vehicles[vd[:serial]] = vehicle
end
puts "  Created #{vehicle_data.length} vehicles (#{vehicle_data.count { |v| v[:images].present? }} with photos)"

# ── 10. Deals ──────────────────────────────────────────────
puts "\n10. Creating deals..."
deals = {}

deal_data = [
  { title: "Smuts - Champion Aspire",      stage: "closed_won",    amount: 114235, contact: "Jeretta Smuts",     account: nil,                            home_cost: 65000, recon: 2500, fp_int: 400,  delivery: 3500, pack: 2000 },
  { title: "Martin - Emerald Sky 4483",    stage: "closed_won",    amount: 124900, contact: "William Martin",    account: "Martin Family Properties",     home_cost: 92000, recon: 0,    fp_int: 350,  delivery: 4200, pack: 2200 },
  { title: "O'Brien - Redman RM2856A",     stage: "closed_won",    amount: 89500,  contact: "Kevin O'Brien",     account: nil,                            home_cost: 60000, recon: 0,    fp_int: 0,    delivery: 3200, pack: 1800 },
  { title: "Lakeside - Dutch 2872A",       stage: "closed_won",    amount: 105000, contact: "Dennis Hopper",     account: "Lakeside MH Community",        home_cost: 77000, recon: 0,    fp_int: 0,    delivery: 4500, pack: 2100 },
  { title: "Gonzalez - Heritage 1676H",    stage: "closed_won",    amount: 62900,  contact: "Maria Gonzalez",    account: nil,                            home_cost: 40000, recon: 0,    fp_int: 0,    delivery: 2800, pack: 1500 },
  { title: "Crawford - Redman RM3264A",    stage: "closed_won",    amount: 96700,  contact: "Daniel Crawford",   account: nil,                            home_cost: 71000, recon: 0,    fp_int: 0,    delivery: 3800, pack: 1900 },
  { title: "Fisher - Dutch 1676S",         stage: "prospecting",   amount: 62000,  contact: "Tammy Fisher",      account: nil,                            home_cost: 45000, recon: 0,    fp_int: 0,    delivery: 2800, pack: 1500 },
  { title: "Hoosier Dev - Bulk Order",     stage: "closed_won",    amount: 450000, contact: "Marcus Johnson",    account: "Hoosier Land Development",     home_cost: 320000, recon: 0,   fp_int: 1200, delivery: 18000, pack: 8000 },
  { title: "Keller - Used Clayton",        stage: "closed_won",    amount: 38500,  contact: "Brian Keller",      account: nil,                            home_cost: 22000, recon: 3200, fp_int: 0,    delivery: 1800, pack: 900 },
  { title: "Turner - Skyline Amber Cove",  stage: "closed_lost",   amount: 42500,  contact: "Jason Turner",      account: nil,                            home_cost: 28000, recon: 0,    fp_int: 0,    delivery: 2000, pack: 1000 },
]

# FIX A — link each deal to a distinct vehicle and a REAL salesperson so the
# Inventory Stock List and Salesperson GP Pipeline reports populate. Vehicles
# idx 10-17 (report_demo_serials) are reserved for the "Report demo data"
# section below; deals draw from the remaining non-sold vehicles. The primary
# salesperson rotates across the three sales users — Report 2 groups by
# primary_salesperson_id, which must be a real User id (not the assigned_to email).
report_demo_serials = %w[
  RMN-2026-A-001240 RMN-2025-A-001150 DH-2026-A-005001 DH-2026-A-005002
  DH-2026-S-005003 DH-2025-A-004990 CLT-2019-T-889900 SKY-2021-A-776600
  FLT-2017-B-554400
]
deal_vehicle_pool = vehicle_data
  .reject { |vd| report_demo_serials.include?(vd[:serial]) || vd[:status] == 'sold' }
  .map { |vd| vehicles[vd[:serial]] }
deal_reps = [users[:sales1], users[:sales2], users[:manager]]
deal_lenders = ['21st Mortgage', 'Vanderbilt Mortgage', 'Triad Financial', 'Cash']

deal_data.each_with_index do |dd, idx|
  contact = contacts[dd[:contact]]
  account = dd[:account] ? accounts[dd[:account]] : nil
  assigned_vehicle = deal_vehicle_pool[idx % deal_vehicle_pool.size]
  rep = deal_reps[idx % deal_reps.size]
  lender = deal_lenders[idx % deal_lenders.size]

  # Sales tax (~6% IN state tax, simplified flat for demo)
  tax_amount = (dd[:amount] * 0.06).round(2)
  commission_amt = (dd[:amount] * 0.03).round(2)
  net_profit = (dd[:amount] - dd[:home_cost] - dd[:recon] - dd[:fp_int] - dd[:delivery] - dd[:pack] - commission_amt).round(2)

  deal = company.deals.find_or_create_by!(name: dd[:title]) do |d|
    d.stage = dd[:stage]
    d.contact_id = contact&.id
    d.account_id = account&.id
    d.assigned_to = [users[:sales1].id, users[:sales2].id].sample
    d.location_id = locations["AUB"].id
    d.value = dd[:amount]
    d.total_amount = dd[:amount]
    d.customer_name = dd[:contact]
    d.deal_number = "#{DEMO_PREFIX.upcase}-DL-#{(idx + 1).to_s.rjust(3, '0')}"
    d.custom_field_values = {}
  end
  # Force-refresh cost/profit/tax fields each run so previously-seeded
  # demo companies pick up new fields without needing a reset.
  # update_columns skips validations and callbacks (no workflow events fire).
  closed_at_date = case dd[:stage]
                   when "closed_won"  then (15 + idx * 3).days.ago
                   when "closed_lost" then (10 + idx * 2).days.ago
                   end
  updates = {
    stage:               dd[:stage],
    selling_price:       dd[:amount],
    home_cost:           dd[:home_cost],
    reconditioning_cost: dd[:recon],
    floor_plan_interest: dd[:fp_int],
    delivery_setup_cost: dd[:delivery],
    pack_amount:         dd[:pack],
    commission_amount:   commission_amt,
    tax_amount:          tax_amount,
    total_tax_amount:    tax_amount,
    state_tax_rate:      6.0,
    net_deal_profit:     net_profit,
    # FIX A — link to vehicle + real salesperson (owner_id == primary_salesperson_id).
    vehicle_id:             assigned_vehicle&.id,
    primary_salesperson_id: rep.id,
    owner_id:               rep.id,
    location_id:            assigned_vehicle&.location_id || locations["AUB"].id,
    lender_name:            (lender == "Cash" ? nil : lender),
    payment_type:           (lender == "Cash" ? "cash" : "finance"),
    # Backdate updated_at so the deal profitability report (which falls
    # back to updated_at when closed_at/won_at are missing) finds these
    # deals in the default date range.
    updated_at:          closed_at_date || 30.days.ago
  }
  updates[:won_at] = closed_at_date if dd[:stage] == "closed_won" && deal.respond_to?(:won_at)
  deal.update_columns(updates)
  deals[dd[:title]] = deal
end
puts "  Created/updated #{deal_data.length} deals (with cost/profit fields for profitability report)"

# ── 11. Quotes ─────────────────────────────────────────────
puts "\n11. Creating quotes..."
qp = DEMO_PREFIX.upcase
quote_data = [
  { number: "#{qp}-Q-2026-001", status: "accepted", subtotal: 88350,  tax: 4971, total: 114235, contact: "Jeretta Smuts",  notes: "Champion Aspire DAP1676H32222 with upgrades" },
  { number: "#{qp}-Q-2026-002", status: "sent",     subtotal: 124900, tax: 7494, total: 137394, contact: "William Martin", notes: "Emerald Sky 4483A" },
  { number: "#{qp}-Q-2026-003", status: "draft",    subtotal: 82500,  tax: 4950, total: 91950,  contact: "Kevin O'Brien",  notes: "Redman RM2856A" },
  { number: "#{qp}-Q-2026-004", status: "sent",     subtotal: 105000, tax: 6300, total: 116300, contact: "Dennis Hopper",  notes: "Dutch 2872A for Lakeside" },
  { number: "#{qp}-Q-2026-005", status: "expired",  subtotal: 42500,  tax: 2550, total: 47550,  contact: "Jason Turner",   notes: "Skyline Amber Cove" },
]

quote_data.each do |qd|
  contact = contacts[qd[:contact]]
  company.quotes.find_or_create_by!(quote_number: qd[:number]) do |q|
    q.status = qd[:status]
    q.contact_id = contact&.id
    q.account_id = contact&.account_id
    q.subtotal = qd[:subtotal]
    q.tax = qd[:tax]
    q.total = qd[:total]
    q.notes = qd[:notes]
    q.sales_rep_id = users[:sales1].id
    q.location_id = locations["AUB"].id
    q.is_deleted = false
    q.resend_count = 0
    q.custom_field_values = {}
  end
end
puts "  Created #{quote_data.length} quotes"

# ── 12. Invoices ───────────────────────────────────────────
puts "\n12. Creating invoices..."
invoice_data = [
  { number: "INV-2026-001", status: "paid",    total: 6400,   contact: "Jeretta Smuts",  notes: "Down payment - Champion Aspire" },
  { number: "INV-2026-002", status: "paid",    total: 107835, contact: "Jeretta Smuts",  notes: "Balance - Champion Aspire" },
  { number: "INV-2026-003", status: "paid",    total: 124900, contact: "William Martin", notes: "Full payment - Emerald Sky" },
  { number: "INV-2026-004", status: "paid",    total: 89500,  contact: "Kevin O'Brien",  notes: "Full payment - Redman RM2856A" },
  { number: "INV-2026-005", status: "paid",    total: 38500,  contact: "Brian Keller",   notes: "Full payment - Used Clayton" },
  { number: "INV-2026-006", status: "paid",    total: 105000, contact: "Dennis Hopper",  notes: "Lakeside - Dutch 2872A" },
  { number: "INV-2026-007", status: "paid",    total: 62900,  contact: "Maria Gonzalez", notes: "Heritage 1676H" },
  { number: "INV-2026-008", status: "paid",    total: 96700,  contact: "Daniel Crawford", notes: "Redman RM3264A" },
  { number: "INV-2026-009", status: "sent",    total: 45000,  contact: "Marcus Johnson", notes: "Bulk order - milestone 1" },
  { number: "INV-2026-010", status: "overdue", total: 10500,  contact: "Tammy Fisher",   notes: "Deposit - Dutch 1676S" },
  { number: "INV-2025-047", status: "paid",    total: 68500,  contact: "Raymond Price",  notes: "Redman RM2448A" },
  { number: "INV-2025-048", status: "paid",    total: 74900,  contact: "Angela Brooks",  notes: "Dutch 2460A" },
]

invoice_data.each do |id_data|
  contact = contacts[id_data[:contact]]
  company.invoices.find_or_create_by!(invoice_number: id_data[:number]) do |inv|
    inv.status = id_data[:status]
    inv.contact_id = contact&.id
    inv.total = id_data[:total]
    inv.subtotal = id_data[:total]
    inv.notes = id_data[:notes]
    inv.sales_rep_id = users[:manager].id
    inv.location_id = locations["AUB"].id
    inv.is_deleted = false
    inv.due_date = id_data[:status] == 'overdue' ? 15.days.ago : 30.days.from_now
    inv.invoice_date = id_data[:status] == 'paid' ? 30.days.ago : 5.days.ago
    inv.custom_field_values = {}
  end
end
puts "  Created #{invoice_data.length} invoices"

# ── 13. Service Tickets ────────────────────────────────────
# scheduled_date / scheduledTime / estimatedHours populated so tickets
# surface on the Calendar (CalendarService#service_ticket_to_event reads them).
puts "\n13. Creating service tickets..."
ticket_data = [
  { title: "Door alignment after delivery",           status: "open",        priority: "high",   contact: "Jeretta Smuts",  sched_offset:  0, time: "09:00", hours: 2 },
  { title: "HVAC not heating properly",               status: "in_progress", priority: "high",   contact: "Brian Keller",   sched_offset:  0, time: "13:00", hours: 3 },
  { title: "Kitchen faucet leak",                     status: "open",        priority: "medium", contact: "Angela Brooks",  sched_offset:  1, time: "10:30", hours: 1 },
  { title: "Carpet seam separation - master bedroom", status: "open",        priority: "medium", contact: "Raymond Price",  sched_offset:  2, time: "14:00", hours: 2 },
  { title: "Skirting installation",                   status: "pending_review", priority: "low", contact: "Jeretta Smuts",  sched_offset:  3, time: "09:00", hours: 4 },
  { title: "Pre-delivery inspection - Emerald Sky",   status: "open",        priority: "high",   contact: "William Martin", sched_offset:  4, time: "11:00", hours: 2 },
  { title: "Window crank replacement",                status: "completed",   priority: "low",    contact: "Sandra Mitchell", sched_offset: -3, time: "10:00", hours: 1 },
  { title: "Smoke detector installation",             status: "completed",   priority: "medium", contact: "Brian Keller",   sched_offset: -5, time: "09:30", hours: 1 },
  { title: "Marriage line drywall crack",             status: "in_progress", priority: "medium", contact: "Angela Brooks",  sched_offset:  5, time: "13:00", hours: 3 },
  { title: "Electrical outlet not working - kitchen", status: "open",        priority: "high",   contact: "Raymond Price",  sched_offset:  7, time: "10:00", hours: 2 },
]

ticket_data.each_with_index do |td, idx|
  contact = contacts[td[:contact]]
  sched_date = Date.current + td[:sched_offset].days
  ticket = company.service_tickets.find_or_create_by!(title: td[:title]) do |st|
    st.status = td[:status]
    st.priority = td[:priority]
    st.contact_id = contact&.id
    st.account_id = contact&.account_id
    st.assigned_to = users[:tech].id
    st.location_id = locations["AUB"].id
    st.ticket_number = "#{DEMO_PREFIX.upcase}-ST-2026-#{(idx + 1).to_s.rjust(3, '0')}"
    st.description = td[:title]
    st.is_warranty_suspected = false
    st.is_warranty_confirmed = false
    st.portal_visible = false
  end
  # Always (re)set scheduled_date + custom_fields so re-runs without RESET
  # still surface tickets on the Calendar. find_or_create_by's block only
  # fires on create, so an existing ticket would otherwise stay unscheduled.
  ticket.update!(
    scheduled_date: sched_date,
    custom_fields:  { "scheduledTime" => td[:time], "estimatedHours" => td[:hours] }
  )
end
puts "  Created/updated #{ticket_data.length} service tickets (scheduled across calendar)"

# ── 14. Suppliers ──────────────────────────────────────────
puts "\n14. Creating suppliers..."
suppliers = {}

[
  { name: "Midwest MH Parts Supply",  contact: "Tom Brennan", email: "tbrennan@midwestmhparts.com", phone: "(260) 555-6001" },
  { name: "Indiana Skirting & Supply", contact: "Paula Davis", email: "pdavis@inskirting.com",       phone: "(574) 555-6002" },
  { name: "Hoosier HVAC Distribution", contact: "Mark Wilson", email: "mwilson@hoosierhvac.com",     phone: "(317) 555-6003" },
].each do |sd|
  supplier = company.suppliers.find_or_create_by!(name: sd[:name]) do |s|
    s.contact_name = sd[:contact]
    s.email = sd[:email]
    s.phone = sd[:phone]
    s.active = true
    s.is_deleted = false
  end
  suppliers[sd[:name]] = supplier
end
puts "  Created #{suppliers.length} suppliers"

# ── 15. Parts ──────────────────────────────────────────────
puts "\n15. Creating parts..."
parts_data = [
  { name: "Door Hinge - Exterior",        sku: "PT-DH-001", mfr: "Champion",    cost: 8.50,  price: 15.00 },
  { name: "Window Crank Assembly",        sku: "PT-WC-002", mfr: "Kinro",       cost: 22.00, price: 45.00 },
  { name: "Vinyl Skirting Panel (4x8)",   sku: "PT-VS-003", mfr: "Duraskirt",   cost: 18.00, price: 35.00 },
  { name: "HVAC Filter 16x20x1",         sku: "PT-HF-004", mfr: "Honeywell",   cost: 4.50,  price: 12.00 },
  { name: "Faucet Assembly - Kitchen",    sku: "PT-FA-005", mfr: "Moen",        cost: 45.00, price: 89.00 },
  { name: "Smoke Detector Battery",      sku: "PT-SD-006", mfr: "Kidde",       cost: 3.00,  price: 8.00 },
  { name: "Carpet Seam Tape (25ft)",     sku: "PT-CT-007", mfr: "Roberts",     cost: 12.00, price: 24.00 },
  { name: "Drywall Compound (5 gal)",    sku: "PT-DC-008", mfr: "USG",         cost: 18.00, price: 32.00 },
  { name: "Marriage Line Trim Kit",       sku: "PT-ML-009", mfr: "Champion",    cost: 35.00, price: 65.00 },
  { name: "Anchor Strap Kit",            sku: "PT-AS-010", mfr: "Tie Down",    cost: 28.00, price: 55.00 },
  { name: "Electrical Outlet - Standard",sku: "PT-EO-011", mfr: "Leviton",     cost: 2.50,  price: 8.00 },
  { name: "Lever Door Handle Set",       sku: "PT-LH-012", mfr: "Kwikset",     cost: 18.00, price: 35.00 },
  { name: "Ceiling Fan w/ Light Kit",    sku: "PT-CF-013", mfr: "Hampton Bay", cost: 55.00, price: 110.00 },
  { name: "Vinyl Plank Flooring (case)", sku: "PT-VF-014", mfr: "Shaw",        cost: 32.00, price: 65.00 },
  { name: "Cabinet Handle - Black",      sku: "PT-CH-015", mfr: "Amerock",     cost: 3.50,  price: 8.00 },
]

parts_data.each do |pd|
  company.parts.find_or_create_by!(sku: pd[:sku]) do |p|
    p.name = pd[:name]
    p.manufacturer_name = pd[:mfr]
    p.default_cost = pd[:cost]
    p.list_price = pd[:price]
    p.is_deleted = false
    p.active = true
    p.uom = "each"
    p.inventory_method = "average_cost"
  end
end
puts "  Created #{parts_data.length} parts"

# ── 16. RBAC Resources & Refresh Company Admin Permissions ─
puts "\n16. Seeding RBAC resources..."
if defined?(Resource) && Resource.respond_to?(:seed_defaults)
  Resource.seed_defaults
  puts "  Resources seeded (#{Resource.active.count} active)"
  
  # Refresh company_admin system role permissions for any NEW resources
  # added after the initial rbac_system_seed.rb ran.
  #
  # RolePermission#invalidate_cache fires an after_save that does
  # Rails.cache.delete_matched, which on a FileStore walks the entire
  # cache directory per row — ~285 inserts * full-tree scan = effective
  # hang on staging. Skip the callback for the bulk loop, then clear
  # role-permission cache keys once at the end.
  ca_role = Role.system_roles.find_by(key: 'company_admin')
  if ca_role
    all_scope = Scope.find_by(key: 'all')
    expected = Resource.active.count * Action.count
    existing = ca_role.role_permissions.count
    if existing >= expected
      puts "  Company Admin role already complete (#{existing} permissions)"
    else
      added = 0
      had_cb = RolePermission.respond_to?(:skip_callback)
      RolePermission.skip_callback(:save, :after, :invalidate_cache) if had_cb
      begin
        Resource.active.find_each do |resource|
          Action.all.each do |action|
            rp = RolePermission.find_or_create_by!(
              role: ca_role, resource: resource, action: action, scope: all_scope
            ) { |p| p.granted = true }
            added += 1 if rp.previously_new_record?
          end
        end
      ensure
        RolePermission.set_callback(:save, :after, :invalidate_cache) if had_cb
      end
      puts "  Company Admin role refreshed (#{added} new permissions added)"
    end
  end
else
  puts "  Skipped"
end

# ── 17. Project Template ──────────────────────────────────
puts "\n17. Creating project template..."
if company.respond_to?(:project_templates)
  template = company.project_templates.find_or_create_by!(name: "Standard Home Setup") do |t|
    t.description = "Standard manufactured home purchase, delivery, and setup"
    t.is_active = true
  end
  # Make Standard Home Setup the default template selection so the
  # Projects list / new-project flows preselect it.
  company.project_templates.where.not(id: template.id).update_all(is_default: false)
  template.update_columns(is_default: true, is_active: true) unless template.is_default && template.is_active

  tp_data = [
    { name: "Contract Signed",         pos: 1,  days: 0,  color: "#3B82F6", icon: "file-signature" },
    { name: "Financing Approved",      pos: 2,  days: 7,  color: "#3B82F6", icon: "bank" },
    { name: "Down Payment Received",   pos: 3,  days: 3,  color: "#10B981", icon: "dollar-sign" },
    { name: "Order Placed w/ Factory", pos: 4,  days: 2,  color: "#F59E0B", icon: "factory" },
    { name: "In Production",          pos: 5,  days: 30, color: "#F59E0B", icon: "hard-hat" },
    { name: "Quality Inspection",      pos: 6,  days: 3,  color: "#F59E0B", icon: "clipboard-check" },
    { name: "Ready for Transport",     pos: 7,  days: 2,  color: "#8B5CF6", icon: "truck" },
    { name: "Site Preparation",        pos: 8,  days: 14, color: "#8B5CF6", icon: "shovel" },
    { name: "Permits Obtained",        pos: 9,  days: 10, color: "#8B5CF6", icon: "file-check" },
    { name: "Home Delivered",          pos: 10, days: 1,  color: "#EC4899", icon: "truck-delivery" },
    { name: "Foundation & Set",        pos: 11, days: 5,  color: "#EC4899", icon: "building" },
    { name: "Utility Connections",     pos: 12, days: 7,  color: "#EC4899", icon: "plug" },
    { name: "Skirting & Exterior",     pos: 13, days: 5,  color: "#6366F1", icon: "home" },
    { name: "Interior Finish & Trim",  pos: 14, days: 5,  color: "#6366F1", icon: "paint-roller" },
    { name: "Final Inspection",        pos: 15, days: 2,  color: "#14B8A6", icon: "search" },
    { name: "Walkthrough w/ Buyer",    pos: 16, days: 1,  color: "#14B8A6", icon: "users" },
    { name: "Closing & Handoff",       pos: 17, days: 1,  color: "#10B981", icon: "key" },
  ]

  tp_data.each do |tp|
    template.project_template_phases.find_or_create_by!(name: tp[:name]) do |p|
      p.position = tp[:pos]
      p.estimated_days = tp[:days]
      p.color = tp[:color]
      p.icon = tp[:icon]
    end
  end
  puts "  Template: #{template.name} (#{tp_data.length} phases)"

  # ── 18. Projects for Won Deals ──────────────────────────
  # One project per closed-won deal at varied progress so the projects
  # list shows a realistic mix (completed, late-stage, early-stage).
  puts "\n18. Creating projects..."

  [
    { deal: "Smuts - Champion Aspire",      name: "Smuts - Champion Aspire Setup",        status: "active",    done: 12, current: 13 },
    { deal: "Keller - Used Clayton",        name: "Keller - Used Clayton Setup",          status: "completed", done: 17, current: nil },
    { deal: "Martin - Emerald Sky 4483",    name: "Martin - Emerald Sky Setup",           status: "active",    done: 8,  current: 9 },
    { deal: "O'Brien - Redman RM2856A",     name: "O'Brien - Redman Setup",               status: "active",    done: 5,  current: 6 },
    { deal: "Lakeside - Dutch 2872A",       name: "Lakeside MH - Dutch Community Setup",  status: "active",    done: 3,  current: 4 },
    { deal: "Gonzalez - Heritage 1676H",    name: "Gonzalez - Heritage Setup",            status: "active",    done: 15, current: 16 },
    { deal: "Crawford - Redman RM3264A",    name: "Crawford - Redman 3264 Setup",         status: "active",    done: 10, current: 11 },
    { deal: "Hoosier Dev - Bulk Order",     name: "Hoosier Dev - 4-Home Bulk Setup",      status: "active",    done: 2,  current: 3 },
  ].each do |pc|
    deal = deals[pc[:deal]]
    next unless deal

    contact = deal.contact_id ? Contact.find_by(id: deal.contact_id) : nil

    project = company.projects.find_or_create_by!(name: pc[:name]) do |p|
      p.deal_id = deal.id
      p.project_template_id = template.id
      p.location_id = deal.location_id
      p.status = pc[:status]
      p.project_number = "PRJ-#{deal.id.to_s.rjust(4, '0')}"
      p.customer_name = contact ? "#{contact.first_name} #{contact.last_name}" : deal.customer_name
      p.customer_email = contact&.email
      p.customer_phone = contact&.phone
      p.description = deal.name
      p.phase_count = tp_data.length
      p.completed_phase_count = pc[:done]
      p.progress_percent = ((pc[:done].to_f / tp_data.length) * 100).round
      p.started_at = 45.days.ago
      p.actual_completion_date = 5.days.ago if pc[:status] == 'completed'
      p.client_access_token = SecureRandom.hex(16)
      p.is_deleted = false
      p.custom_field_values = {}
    end

    tp_data.each do |tp|
      phase_status = if tp[:pos] <= pc[:done]
                       'completed'
                     elsif pc[:current] && tp[:pos] == pc[:current]
                       'in_progress'
                     else
                       'not_started'
                     end

      days_offset = tp_data[0...(tp[:pos] - 1)].sum { |ph| ph[:days] }
      started = project.started_at + days_offset.days if phase_status != 'not_started'
      completed = started + tp[:days].days if phase_status == 'completed' && started

      project.project_phases.find_or_create_by!(name: tp[:name]) do |ph|
        ph.company_id = company.id
        ph.position = tp[:pos]
        ph.status = phase_status
        ph.color = tp[:color]
        ph.icon = tp[:icon]
        ph.estimated_days = tp[:days]
        ph.started_at = started if started
        ph.completed_at = completed if completed
      end
    end

    current = project.project_phases.find_by(status: 'in_progress')
    project.update_column(:current_phase_id, current.id) if current

    puts "  Project: #{project.name} (#{pc[:status]}, #{pc[:done]}/#{tp_data.length})"
  end
else
  puts "  Skipped (Project model not found)"
end

# ── 19. Accounting: Chart of Accounts, Bank, Bills ────────
puts "\n19. Setting up accounting..."
begin
  require Rails.root.join('db/seeds/seed_default_chart_of_accounts.rb').to_s
  DefaultChartOfAccountsSeeder.seed(company)
  puts "  Chart of accounts: #{company.chart_of_accounts.count} accounts"
rescue => e
  puts "  ⚠ Chart of accounts skipped: #{e.message}"
end

# Bank Account (one operating, idempotent on account_purpose)
if defined?(BankAccount)
  bank_coa = company.chart_of_accounts.find_by(account_number: '1010')
  bank = company.bank_accounts.find_or_create_by!(account_purpose: 'operating') do |b|
    b.location_id = locations["AUB"].id
    b.account_type = 'checking'
    b.bank_name = 'First Indiana Bank'
    b.routing_number = '074000010'
    b.account_number = "#{DEMO_PREFIX.upcase}-OP-1001"
    b.account_holder_name = company.name
    b.is_active = true
    b.is_verified = true
    b.verified_at = 30.days.ago
    b.display_last_four = '1001'
    b.opening_balance = 50_000
    b.current_balance = 124_350.42
    b.opened_on = 6.months.ago.to_date
    b.chart_of_account_id = bank_coa&.id
    b.currency = 'USD'
  end
  puts "  Bank account: #{bank.bank_name} (#{bank.account_purpose})"
end

# Bills (vendor invoices payable)
ap_account = company.chart_of_accounts.find_by(account_number: '2010')
parts_cogs = company.chart_of_accounts.find_by(account_number: '5400')
opex_acct  = company.chart_of_accounts.find_by(account_number: '6500')

bill_data = [
  { vendor: "Midwest MH Parts Supply",  number: "MWP-23491", date: 25.days.ago, due: 5.days.from_now,  total: 1_245.50, status: "pending",        memo: "Replacement door hinges + window cranks", acct: parts_cogs },
  { vendor: "Indiana Skirting & Supply", number: "ISS-88112", date: 18.days.ago, due: 12.days.from_now, total: 3_480.00, status: "pending",        memo: "Skirting panels for Auburn lot",         acct: parts_cogs },
  { vendor: "Hoosier HVAC Distribution", number: "HVD-44021", date: 45.days.ago, due: 15.days.ago,     total: 2_180.75, status: "partially_paid", memo: "HVAC unit + install supplies",           acct: parts_cogs },
  { vendor: "Hoosier HVAC Distribution", number: "HVD-44188", date: 6.days.ago,  due: 24.days.from_now, total: 875.00,   status: "draft",          memo: "Filter inventory restock",               acct: parts_cogs },
  { vendor: "Midwest MH Parts Supply",  number: "MWP-23612", date: 60.days.ago, due: 30.days.ago,     total: 4_120.00, status: "paid",           memo: "Q4 parts order",                          acct: parts_cogs },
].each_with_index do |bd, idx|
  next unless defined?(Bill)
  vendor = suppliers[bd[:vendor]]
  next unless vendor
  bill = company.bills.find_or_create_by!(bill_number: bd[:number]) do |b|
    b.vendor_id = vendor.id
    b.vendor_name = vendor.name
    b.location_id = locations["AUB"].id
    b.bill_date = bd[:date]
    b.due_date = bd[:due]
    b.status = bd[:status]
    b.subtotal = bd[:total]
    b.tax_amount = 0
    b.total_amount = bd[:total]
    b.amount_paid = bd[:status] == 'paid' ? bd[:total] : (bd[:status] == 'partially_paid' ? (bd[:total] * 0.5).round(2) : 0)
    b.balance_due = bd[:total] - b.amount_paid
    b.memo = bd[:memo]
    b.payment_terms = "Net 30"
    b.ap_account_id = ap_account&.id
    b.is_deleted = false
  end
  if bd[:acct] && bill.bill_line_items.empty?
    bill.bill_line_items.create!(
      chart_of_account_id: bd[:acct].id,
      amount: bd[:total],
      description: bd[:memo],
      position: 1,
      location_id: locations["AUB"].id
    )
  end
end
puts "  Bills: #{company.bills.count} (#{company.bills.where(status: 'pending').count} pending, #{company.bills.where(status: 'paid').count} paid)" if defined?(Bill)

# ── 20. Commissions ───────────────────────────────────────
puts "\n20. Setting up commissions..."
if defined?(CommissionPlan) && defined?(CommissionRule) && defined?(CommissionPayment)
  plan = company.commission_plans.find_or_create_by!(name: "Sales Rep — Standard MH") do |p|
    p.description = "Standard 3% of gross profit on new and used home sales"
    p.effective_date = 1.year.ago.to_date
    p.is_active = true
    p.is_default = true
    p.assigned_role = "sales_rep"
  end

  rule = company.commission_rules.find_or_create_by!(name: "3% of Gross Profit") do |r|
    r.rule_type = "percentage"
    r.rate = 0.03
    r.amount = 0
    r.tiers = []
    r.is_active = true
    r.description = "3% of (sale price - dealer cost) on closed_won deals"
  end

  won_deals = deals.values.select { |d| d.stage == "closed_won" }
  won_deals.each_with_index do |deal, idx|
    next unless deal.assigned_to.present?
    company.commission_payments.find_or_create_by!(payment_number: "CP-#{(idx + 1).to_s.rjust(4, '0')}") do |cp|
      cp.deal_id = deal.id
      cp.commission_plan_id = plan.id
      cp.location_id = deal.location_id
      cp.payee_user_id = deal.assigned_to
      cp.status = idx.zero? ? "paid" : "approved"
      cp.amount = (deal.value.to_f * 0.03).round(2)
      cp.earned_date = deal.updated_at.to_date
      cp.calculation_details = { "rule" => rule.name, "rate" => 0.03, "basis" => "gross_profit" }
      if cp.status == "paid"
        cp.payment_method = "ach"
        cp.paid_at = 5.days.ago
        cp.paid_date = 5.days.ago.to_date
        cp.paid_by_user_id = users[:admin].id
        cp.amount_paid = cp.amount
        cp.remaining_balance = 0
      end
      cp.approved_at = 7.days.ago
      cp.approved_by_user_id = users[:manager].id
    end
  end
  puts "  Plan: #{plan.name}, Payments: #{company.commission_payments.count}"
else
  puts "  Skipped (commission models missing)"
end

# ── 21. Nurture Sequence + Enrollments ────────────────────
puts "\n21. Setting up nurture sequence..."
if defined?(NurtureSequence) && defined?(NurtureStep) && defined?(NurtureEnrollment)
  seq = company.nurture_sequences.find_or_create_by!(name: "New Lead — 7 Day Welcome") do |s|
    s.description = "Auto-enrolls new leads. Mix of email and SMS over 7 days."
    s.is_active = true
  end

  step_data = [
    { pos: 1, wait: 0, channel: "email", subject: "Welcome to #{DEMO_COMPANY_NAME}, {{first_name}}",
      body: "Thanks for reaching out. We'll be in touch shortly — in the meantime here's our most-toured floor plans." },
    { pos: 2, wait: 1, channel: "sms",
      body: "Hi {{first_name}}, this is the team at #{DEMO_COMPANY_NAME}. Want to schedule a quick tour this week?" },
    { pos: 3, wait: 2, channel: "email", subject: "Top 3 questions buyers ask us",
      body: "Most folks new to manufactured housing have the same questions. Here are the three we hear most." },
    { pos: 4, wait: 4, channel: "email", subject: "Financing options that surprise people",
      body: "Modern MH financing looks nothing like it did ten years ago. Quick overview inside." },
    { pos: 5, wait: 7, channel: "sms",
      body: "Last note from #{DEMO_COMPANY_NAME} — happy to answer any questions, just reply to this message." },
  ]
  step_data.each do |sd|
    seq.nurture_steps.find_or_create_by!(position: sd[:pos]) do |st|
      st.step_type = sd[:channel]
      st.channel = sd[:channel]
      st.subject = sd[:subject]
      st.body = sd[:body]
      st.wait_days = sd[:wait]
    end
  end

  # Enroll a few leads
  leads.values.first(4).each_with_index do |lead, idx|
    NurtureEnrollment.find_or_create_by!(
      enrollable_type: "Lead",
      enrollable_id: lead.id,
      nurture_sequence_id: seq.id
    ) do |ne|
      ne.lead_id = lead.id
      ne.company_id = company.id
      ne.status = idx < 2 ? "running" : (idx == 2 ? "completed" : "idle")
      ne.current_step_index = idx < 2 ? (idx + 1) : (idx == 2 ? step_data.length : 0)
    end
  end
  puts "  Sequence: #{seq.name} (#{seq.nurture_steps.count} steps, #{NurtureEnrollment.where(nurture_sequence_id: seq.id).count} enrolled)"
else
  puts "  Skipped (nurture models missing)"
end

# ── 22. Campaigns ─────────────────────────────────────────
puts "\n22. Setting up campaigns..."
if defined?(Campaign)
  campaign = company.campaigns.find_or_create_by!(name: "Spring 2026 — New Inventory Showcase") do |c|
    c.description = "Featured new homes available now"
    c.status = "running"
    c.campaign_type = "blast"
    c.channel = "email"
    c.audience_mode = "static"
    c.from_identity_type = "User"
    c.from_identity_id = users[:manager].id
    c.from_display_name = "#{users[:manager].first_name} at #{DEMO_COMPANY_NAME}"
    c.reply_to_address = users[:manager].email
    c.subject_default = "New manufactured homes just hit the lot"
    c.goal_config = { "primary_goal" => "clicked", "remove_on_goal_met" => true }
    c.send_window = { "timezone" => "America/Indianapolis", "days" => %w[tue wed thu], "hour_start" => 10, "hour_end" => 18 }
    c.throttle_per_day = 200
    c.utm_source = "campaign"
    c.utm_medium = "email"
    c.utm_campaign = "spring-2026-showcase"
    c.scheduled_at = 3.days.ago
    c.started_at = 3.days.ago
    c.created_by_user_id = users[:manager].id
    c.location_id = locations["AUB"].id
  end

  # Audience (static snapshot of contacts)
  CampaignAudience.find_or_create_by!(campaign_id: campaign.id) do |a|
    a.source_type = "Contact"
    a.filter_tree = { "type" => "and", "children" => [{ "field" => "is_deleted", "operator" => "equals", "value" => false }] }
    a.estimated_count = contacts.size
    a.estimated_at = 3.days.ago
  end

  # Single step (blast)
  step = campaign.campaign_steps.find_or_create_by!(position: 1) do |s|
    s.wait_days = 0
    s.wait_hours = 0
    s.channel = "email"
    s.subject = "New manufactured homes just hit the lot"
    s.preheader = "3 brand-new Champion and Redman floor plans available"
    s.body_blocks = [
      { "type" => "text", "html" => "<p>Hi {{first_name}},</p><p>Three brand-new floor plans just landed at our Auburn showroom and we wanted you to be the first to see them.</p>" },
      { "type" => "inventory", "ref" => "step.inventory_block_config" },
      { "type" => "button", "label" => "Browse inventory", "url" => "https://example.com/inventory", "style" => "primary" },
      { "type" => "footer_unsubscribe" }
    ]
    s.is_active = true
  end

  # Sample enrollments + sends for first 5 contacts
  contacts.values.first(5).each_with_index do |contact, idx|
    enr = CampaignEnrollment.find_or_create_by!(campaign_id: campaign.id, recipient_type: "Contact", recipient_id: contact.id) do |e|
      e.company_id = company.id
      e.email_address_snapshot = contact.email
      e.status = idx == 4 ? "unsubscribed" : "completed"
      e.current_step_index = 1
      e.last_sent_at = 3.days.ago
      e.unsubscribed_at = (3.days.ago if idx == 4)
    end
    CampaignSend.find_or_create_by!(campaign_step_id: step.id, campaign_enrollment_id: enr.id) do |snd|
      snd.company_id = company.id
      snd.campaign_id = campaign.id
      snd.sent_at = 3.days.ago
      snd.delivered_at = 3.days.ago + 5.minutes
      snd.opened_at = idx < 3 ? (3.days.ago + 2.hours) : nil
      snd.open_count = idx < 3 ? rand(1..3) : 0
      snd.clicked_at = idx < 2 ? (3.days.ago + 2.hours + 30.seconds) : nil
      snd.click_count = idx < 2 ? 1 : 0
    end
  end
  puts "  Campaign: #{campaign.name} (#{CampaignSend.where(campaign_id: campaign.id).count} sends)"
else
  puts "  Skipped (Campaign model missing)"
end

# ── 23. Workflow Rules ────────────────────────────────────
puts "\n23. Setting up workflow rules..."
if defined?(WorkflowRule)
  workflows = [
    {
      name: "New Lead Alert (Facebook)",
      description: "Email the lead owner when a new Facebook lead lands.",
      entity_type: "Lead",
      trigger: { "event_type" => "lead.created", "entity_type_filter" => "Lead" },
      conditions: [{ "type" => "and", "conditions" => [{ "field" => "source", "operator" => "equals", "value" => "Facebook" }] }],
      steps: { "nodes" => [{ "id" => "n1", "type" => "send_email", "config" => {
        "to" => "{{entity.owner_email}}",
        "subject" => "New Facebook Lead: {{entity.first_name}} {{entity.last_name}}",
        "body" => "A new lead came in from Facebook. Call within 5 minutes for best results."
      } }], "edges" => [] }
    },
    {
      name: "Deal Closed Notification",
      description: "Notify the deal owner when a deal is marked closed_won.",
      entity_type: "Deal",
      trigger: { "event_type" => "deal.status_changed", "entity_type_filter" => "Deal" },
      conditions: [{ "type" => "and", "conditions" => [{ "field" => "stage", "operator" => "equals", "value" => "closed_won" }] }],
      steps: { "nodes" => [{ "id" => "n1", "type" => "send_email", "config" => {
        "to" => "{{entity.owner_email}}",
        "subject" => "Deal Closed — {{entity.name}}",
        "body" => "Closed-won deal: {{entity.name}} ({{entity.amount}})."
      } }], "edges" => [] }
    },
    {
      name: "Service Ticket Acknowledgment",
      description: "Send customer an acknowledgment when they open a service ticket.",
      entity_type: "ServiceTicket",
      trigger: { "event_type" => "service_ticket.created", "entity_type_filter" => "ServiceTicket" },
      conditions: [],
      steps: { "nodes" => [{ "id" => "n1", "type" => "send_email", "config" => {
        "to" => "{{entity.contact_email}}",
        "subject" => "Your service request — Ticket {{entity.id}}",
        "body" => "Thanks for opening a service request. A team member will reach out shortly."
      } }], "edges" => [] }
    },
  ]
  workflows.each do |wf|
    company.workflow_rules.find_or_create_by!(name: wf[:name]) do |r|
      r.description = wf[:description]
      r.entity_type = wf[:entity_type]
      r.status = "active"
      r.trigger = wf[:trigger]
      r.conditions = wf[:conditions]
      r.steps = wf[:steps]
      r.parameters = {}
      r.version = 1
      r.is_seeded = true
      r.created_by_user_id = users[:admin].id
    end
  end
  puts "  Workflow rules: #{company.workflow_rules.count}"
else
  puts "  Skipped (WorkflowRule model missing)"
end

# ── 24. Loans ─────────────────────────────────────────────
puts "\n24. Setting up loans..."
if defined?(Loan)
  loan_data = [
    { contact: "Jeretta Smuts",  number: "L-2026-001", principal: 107_835.00, rate: 7.25, term: 240, status: "active",   start_offset: 30,
      home: "112-000-H-A-C412800D" },
    { contact: "Brian Keller",   number: "L-2026-002", principal: 30_500.00,  rate: 8.50, term: 120, status: "active",   start_offset: 60,
      home: "CLT-2019-T-889900" },
    { contact: "Raymond Price",  number: "L-2025-099", principal: 60_000.00,  rate: 7.75, term: 180, status: "paid_off", start_offset: 540,
      home: "RMN-2025-A-001150" },
  ]
  loan_data.each do |ld|
    contact = contacts[ld[:contact]]
    next unless contact
    vehicle = vehicles[ld[:home]]
    company.loans.find_or_create_by!(loan_number: ld[:number]) do |l|
      l.location_id = locations["AUB"].id
      l.loan_type = "retail_installment"
      l.status = ld[:status]
      l.borrower_type = "Contact"
      l.borrower_id = contact.id
      l.financed_entity_type = vehicle ? "Vehicle" : nil
      l.financed_entity_id   = vehicle&.id
      l.principal_amount = ld[:principal]
      l.interest_rate = ld[:rate]
      l.term_months = ld[:term]
      l.origination_date = ld[:start_offset].days.ago.to_date
      l.first_payment_date = (ld[:start_offset] - 30).days.ago.to_date
      l.maturity_date = (ld[:term].months.from_now - ld[:start_offset].days).to_date
      l.payment_frequency = "monthly"
      monthly = (ld[:principal] * (ld[:rate] / 100 / 12)) / (1 - (1 + ld[:rate] / 100 / 12)**(-ld[:term]))
      l.regular_payment_amount = monthly.round(2)
      l.day_of_month_due = 1
      l.current_balance = ld[:status] == "paid_off" ? 0 : (ld[:principal] * 0.92).round(2)
      l.total_paid = ld[:status] == "paid_off" ? ld[:principal] : (ld[:principal] * 0.08).round(2)
      l.payments_made = ld[:status] == "paid_off" ? ld[:term] : (ld[:start_offset] / 30).to_i
      l.payments_remaining = ld[:status] == "paid_off" ? 0 : (ld[:term] - (ld[:start_offset] / 30).to_i)
      l.last_payment_date = 25.days.ago.to_date
      l.next_payment_date = ld[:status] == "paid_off" ? nil : 5.days.from_now.to_date
      l.auto_pay_enabled = false
      l.is_deleted = false
    end
  end
  puts "  Loans: #{company.loans.count} (#{company.loans.where(status: 'active').count} active)"
else
  puts "  Skipped (Loan model missing)"
end

# ── 25. Purchase Orders ───────────────────────────────────
puts "\n25. Setting up purchase orders..."
if defined?(PurchaseOrder)
  parts_list = company.parts.limit(5).to_a

  # purchase_orders.supplier_id has a DB-level FK to the legacy `suppliers`
  # table, but the model `belongs_to :supplier` resolves to the STI Supplier
  # (vendors table, vendor_type='supplier'). For both checks to pass, the
  # supplier_id must exist in BOTH tables with the SAME id. Mirror our
  # vendors-suppliers into the legacy table using each vendor's own id.
  suppliers.each do |name, vendor|
    exists = ActiveRecord::Base.connection.exec_query(
      "SELECT 1 FROM suppliers WHERE id = #{vendor.id} LIMIT 1"
    ).rows.any?
    next if exists
    ActiveRecord::Base.connection.execute(
      "INSERT INTO suppliers (id, company_id, name, contact_name, email, phone, vendor_id, active, is_deleted, created_at, updated_at) " \
      "VALUES (#{vendor.id}, #{company.id}, " \
      "#{ActiveRecord::Base.connection.quote(name)}, " \
      "#{ActiveRecord::Base.connection.quote(vendor.contact_name)}, " \
      "#{ActiveRecord::Base.connection.quote(vendor.email)}, " \
      "#{ActiveRecord::Base.connection.quote(vendor.phone)}, " \
      "#{vendor.id}, true, false, NOW(), NOW())"
    )
  end
  # Bump suppliers sequence past the inserted IDs to avoid future PK conflicts
  ActiveRecord::Base.connection.execute(
    "SELECT setval('suppliers_id_seq', GREATEST((SELECT MAX(id) FROM suppliers), 1))"
  )

  po_data = [
    { supplier: "Midwest MH Parts Supply",  number: "PO-2026-001", date: 10.days.ago, status: "received",            qty: 25 },
    { supplier: "Indiana Skirting & Supply", number: "PO-2026-002", date: 5.days.ago,  status: "sent",                qty: 40 },
    { supplier: "Hoosier HVAC Distribution", number: "PO-2026-003", date: 1.day.ago,   status: "draft",               qty: 12 },
  ]
  po_data.each do |pod|
    supplier = suppliers[pod[:supplier]]
    next unless supplier && parts_list.any?
    po = company.purchase_orders.find_or_create_by!(po_number: pod[:number]) do |p|
      p.supplier_id = supplier.id
      p.vendor_id = supplier.id
      p.location_id = locations["AUB"].id
      p.created_by_id = users[:manager].id
      p.status = pod[:status]
      p.order_date = pod[:date].to_date
      p.expected_delivery_date = (pod[:date] + 14.days).to_date
      p.delivery_date = (pod[:status] == "received" ? pod[:date] + 7.days : nil)&.to_date
      p.received_date = pod[:status] == "received" ? pod[:date] + 7.days : nil
      p.ship_to_name = company.name
      p.ship_to_address1 = locations["AUB"].address_line1
      p.ship_to_city = locations["AUB"].city
      p.ship_to_state = locations["AUB"].state
      p.ship_to_zip = locations["AUB"].zip_code
      p.subtotal = 0
      p.tax_amount = 0
      p.shipping_cost = 0
      p.total_amount = 0
    end
    if po.purchase_order_lines.empty?
      subtotal = 0
      parts_list.first(3).each_with_index do |part, i|
        qty = pod[:qty] + i * 5
        line_total = (part.default_cost.to_f * qty).round(2)
        subtotal += line_total
        po.purchase_order_lines.create!(
          part_id: part.id,
          line_number: i + 1,
          quantity_ordered: qty,
          quantity_received: pod[:status] == "received" ? qty : 0,
          unit_cost: part.default_cost,
          line_total: line_total,
          description: part.name
        )
      end
      po.update!(subtotal: subtotal, total_amount: subtotal)
    end
  end
  puts "  Purchase orders: #{company.purchase_orders.count}"
else
  puts "  Skipped (PurchaseOrder model missing)"
end

# ── 26. Contractors + Warranty Claims ─────────────────────
puts "\n26. Setting up contractors and warranty claims..."
if defined?(Contractor)
  contractor_data = [
    { name: "B&B Skirting Pros",    contact: "Bill Boykins",   email: "bill@bbskirting.com",    phone: "(260) 555-7001", trade: "skirting",   rate: 65 },
    { name: "Reliant HVAC Service", contact: "Rita Gonzalez",  email: "rita@relianthvac.com",   phone: "(317) 555-7002", trade: "hvac",       rate: 95 },
    { name: "Anchor Set Crew",      contact: "Carl Anchorson", email: "carl@anchorsetcrew.com", phone: "(260) 555-7003", trade: "foundation", rate: 85 },
  ]
  contractors_hash = {}
  contractor_data.each do |cd|
    c = company.contractors.find_or_create_by!(email: cd[:email]) do |ct|
      ct.name = cd[:name]
      ct.contact_name = cd[:contact]
      ct.phone = cd[:phone]
      ct.trade_type = cd[:trade]
      ct.hourly_rate = cd[:rate]
      ct.status = "active"
      ct.active = true
      ct.is_deleted = false
      ct.rating = [4.5, 4.7, 4.9].sample
    end
    contractors_hash[cd[:name]] = c
  end
  puts "  Contractors: #{contractors_hash.size}"

  # Assign contractors to a couple of service tickets
  if defined?(ContractorAssignment)
    open_tickets = company.service_tickets.where(status: %w[open in_progress]).limit(2)
    open_tickets.each_with_index do |ticket, idx|
      contractor = contractors_hash.values[idx % contractors_hash.size]
      ContractorAssignment.find_or_create_by!(
        vendor_id: contractor.id,
        assignable_type: "ServiceTicket",
        assignable_id: ticket.id
      ) do |a|
        a.company_id = company.id
        a.assigned_by_id = users[:manager].id
        a.status = idx.zero? ? "in_progress" : "assigned"
        a.assigned_at = 3.days.ago
        a.accepted_at = idx.zero? ? 2.days.ago : nil
        a.notes = "On-site visit needed."
      end
    end
    puts "  Contractor assignments: #{ContractorAssignment.where(company_id: company.id).count}"
  end
else
  puts "  Skipped (Contractor model missing)"
end

# Warranty claims (require manufacturer + service_ticket)
if defined?(WarrantyClaim)
  champ_mfr = Manufacturer.where("name ILIKE ?", "%champion%").first
  champ_mfr ||= Manufacturer.where(active: true).first
  if champ_mfr
    CompanyManufacturer.find_or_create_by!(company_id: company.id, manufacturer_id: champ_mfr.id) { |cm| cm.active = true }
  else
    puts "  ⚠ No manufacturers in DB — skipping warranty claims"
  end
  warranty_source_tickets = champ_mfr ? company.service_tickets.where(status: %w[open in_progress completed]).limit(2) : []
  warranty_source_tickets.each_with_index do |ticket, idx|
    company.warranty_claims.find_or_create_by!(claim_number: "WC-2026-#{(idx + 1).to_s.rjust(3, '0')}") do |w|
      w.service_ticket_id = ticket.id
      w.manufacturer_id = champ_mfr.id
      w.location_id = ticket.location_id || locations["AUB"].id
      w.status = idx.zero? ? "submitted" : "approved"
      w.estimated_amount = [350, 850, 1_200].sample
      w.approved_amount = idx.zero? ? nil : w.estimated_amount
      w.parts = [{ "name" => "Door hinge assembly", "qty" => 2, "cost" => 25 }]
      w.labor = [{ "description" => "Adjust door alignment", "hours" => 1.5, "rate" => 95 }]
      w.submitted_at = 5.days.ago
      w.approved_at = (3.days.ago if idx == 1)
      w.public_token = SecureRandom.hex(16)
      w.is_deleted = false
      w.submitted_by = users[:tech].first_name
    end
  end
  puts "  Warranty claims: #{company.warranty_claims.count}"
end

# ── 27. Agreements ────────────────────────────────────────
puts "\n27. Setting up agreement templates and agreements..."
if defined?(AgreementTemplate)
  cat = company.agreement_categories.find_or_create_by!(name: "Sales Agreement") do |c|
    c.description = "Purchase agreements and addenda"
    c.color = "#3B82F6"
    c.position = 1
    c.is_system = false
  end

  templates = [
    { name: "MH Purchase Agreement (IN)",    form_type: "purchase_agreement", state: "IN" },
    { name: "Delivery & Setup Addendum",      form_type: "addendum",           state: "IN" },
    { name: "Limited Warranty Disclosure",    form_type: "disclosure",         state: nil  },
  ]
  template_objs = {}
  templates.each do |td|
    t = company.agreement_templates.find_or_create_by!(name: td[:name]) do |at|
      at.description = "Standard #{td[:name]} for #{DEMO_COMPANY_NAME}"
      at.category = "Sales Agreement"
      at.agreement_category_id = cat.id
      at.template_type = "editor"
      at.form_type = td[:form_type]
      at.state_code = td[:state]
      at.status = "active"
      at.version = 1
      at.content = "<h1>#{td[:name]}</h1><p>Auto-generated demo template for {{customer_name}}.</p>"
      at.merge_fields = ["customer_name", "vehicle_make", "vehicle_model", "sale_price"]
      at.default_signers = [{ "role" => "signer", "name" => "Buyer" }]
      at.is_system_template = false
      at.created_by_id = users[:admin].id
    end
    template_objs[td[:name]] = t
  end
  puts "  Templates: #{template_objs.size}"

  # Sample agreements
  sales_template = template_objs["MH Purchase Agreement (IN)"]
  smuts = contacts["Jeretta Smuts"]
  martin = contacts["William Martin"]
  smuts_deal = deals["Smuts - Champion Aspire"]
  martin_deal = deals["Martin - Emerald Sky 4483"]

  if sales_template && smuts && smuts_deal
    ag = company.agreements.find_or_create_by!(agreement_number: "AG-2026-001") do |a|
      a.agreement_template_id = sales_template.id
      a.title = "Purchase Agreement — Smuts — Champion Aspire"
      a.category = "Sales Agreement"
      a.status = "completed"
      a.contact_id = smuts.id
      a.deal_id = smuts_deal.id
      a.location_id = locations["AUB"].id
      a.prepared_by_id = users[:sales1].id
      a.merge_field_values = { "customer_name" => "Jeretta Smuts", "sale_price" => "$114,235" }
      a.sent_at = 21.days.ago
      a.completed_at = 18.days.ago
      a.delivery_method = "email"
      a.signing_order = "parallel"
      a.is_deleted = false
    end
    ag.agreement_signers.find_or_create_by!(email: smuts.email) do |s|
      s.name = "Jeretta Smuts"
      s.role = "signer"
      s.signing_order = 1
      s.status = "signed"
      s.signed_at = 18.days.ago
      s.viewed_at = 20.days.ago
      s.access_token = SecureRandom.hex(20)
      s.typed_signature = "Jeretta Smuts"
      s.signature_method = "typed"
    end
  end

  if sales_template && martin && martin_deal
    ag2 = company.agreements.find_or_create_by!(agreement_number: "AG-2026-002") do |a|
      a.agreement_template_id = sales_template.id
      a.title = "Purchase Agreement — Martin — Emerald Sky"
      a.category = "Sales Agreement"
      a.status = "sent"
      a.contact_id = martin.id
      a.deal_id = martin_deal.id
      a.location_id = locations["AUB"].id
      a.prepared_by_id = users[:sales2].id
      a.merge_field_values = { "customer_name" => "William Martin", "sale_price" => "$137,394" }
      a.sent_at = 2.days.ago
      a.delivery_method = "email"
      a.signing_order = "parallel"
      a.is_deleted = false
    end
    ag2.agreement_signers.find_or_create_by!(email: martin.email) do |s|
      s.name = "William Martin"
      s.role = "signer"
      s.signing_order = 1
      s.status = "viewed"
      s.viewed_at = 1.day.ago
      s.access_token = SecureRandom.hex(20)
    end
  end
  puts "  Agreements: #{company.agreements.count}"
end

# ── 28. Brochures + Listings ──────────────────────────────
puts "\n28. Setting up brochures and listings..."
if defined?(Brochure)
  featured_vehicles = company.vehicles.where(status: "available").limit(3)
  if featured_vehicles.any?
    company.brochures.find_or_create_by!(title: "Spring 2026 Featured Homes") do |b|
      b.description = "Hand-picked new homes available right now"
      b.public_id = "#{DEMO_PREFIX}-spring-2026-#{SecureRandom.hex(4)}"
      b.template_name = "mh_family_living"
      b.template_data = { "theme" => "warm", "highlight_color" => "#3B82F6" }
      b.vehicle_ids = featured_vehicles.pluck(:id)
      b.is_public = true
      b.status = "active"
      b.location_id = locations["AUB"].id
    end
  end
  puts "  Brochures: #{company.brochures.count}"
end

if defined?(Listing)
  company.vehicles.where(status: "available").limit(2).each_with_index do |vehicle, idx|
    company.listings.find_or_create_by!(vehicle_id: vehicle.id) do |l|
      l.status = "active"
      l.offer_type = "sale"
      l.sale_price = vehicle.sale_price || 0
      l.rent_price = 0
      l.rent_period = "monthly"
      l.description = "#{vehicle.year} #{vehicle.make} #{vehicle.model} — #{vehicle.bedrooms}BR / #{vehicle.bathrooms}BA, #{vehicle.square_feet} sqft. Available now at our #{locations['AUB'].city} location."
      l.location_id = vehicle.location_id
      l.contact_email = users[:manager].email
      l.contact_phone = "(260) 555-0100"
      l.published_at = idx.days.ago
      l.has_appliances = true
      l.has_ac = true
      l.financing_available = "yes"
      l.delivery_available = "yes"
      l.is_deleted = false
    end
  end
  puts "  Listings: #{company.listings.count}"
end

# ── 29. Payment Methods (needed for Payment records) ──────
puts "\n29. Setting up payment methods..."
payment_methods = {}
if defined?(PaymentMethod)
  payor_contacts = ["Jeretta Smuts", "Brian Keller", "Raymond Price", "Angela Brooks", "William Martin", "Kevin O'Brien", "Dennis Hopper", "Maria Gonzalez", "Daniel Crawford", "Marcus Johnson"]
  payor_contacts.each do |name|
    contact = contacts[name]
    next unless contact
    pm = PaymentMethod.find_or_create_by!(
      owner_type: "Contact", owner_id: contact.id, method_type: "cash"
    ) do |m|
      m.company_id = company.id
      m.location_id = locations["AUB"].id
      m.nickname = "#{name.split.first}'s Cash/Check"
      m.is_default = true
      m.is_active = true
      m.is_verified = true
      m.billing_first_name = contact.first_name
      m.billing_last_name = contact.last_name
    end
    payment_methods[name] = pm
  end
  puts "  Payment methods: #{payment_methods.size}"
end

# ── 30. Payments (drives dashboard revenue tile) ──────────
puts "\n30. Setting up payments..."
if defined?(Payment)
  # Map: (invoice_number suffix) → contact name; mirrors invoice_data above.
  paid_invoice_payments = [
    { inv: "INV-2026-001", contact: "Jeretta Smuts",   amount: 6_400,   days_ago: 25 },
    { inv: "INV-2026-002", contact: "Jeretta Smuts",   amount: 107_835, days_ago: 18 },
    { inv: "INV-2026-003", contact: "William Martin",  amount: 124_900, days_ago: 16 },
    { inv: "INV-2026-004", contact: "Kevin O'Brien",   amount: 89_500,  days_ago: 14 },
    { inv: "INV-2026-005", contact: "Brian Keller",    amount: 38_500,  days_ago: 10 },
    { inv: "INV-2026-006", contact: "Dennis Hopper",   amount: 105_000, days_ago: 8 },
    { inv: "INV-2026-007", contact: "Maria Gonzalez",  amount: 62_900,  days_ago: 7 },
    { inv: "INV-2026-008", contact: "Daniel Crawford", amount: 96_700,  days_ago: 6 },
    { inv: "INV-2025-047", contact: "Raymond Price",   amount: 68_500,  days_ago: 60 },
    { inv: "INV-2025-048", contact: "Angela Brooks",   amount: 74_900,  days_ago: 45 },
  ]
  # Add a few more recent payments so the dashboard revenue tile has
  # something for the current period regardless of when the seed runs.
  paid_invoice_payments += [
    { inv: "INV-2026-001", contact: "Jeretta Smuts",  amount: 2_500, days_ago: 2, suffix: "-supp" },
    { inv: "INV-2026-005", contact: "Brian Keller",   amount: 1_200, days_ago: 5, suffix: "-supp" },
  ]

  created = 0
  paid_invoice_payments.each_with_index do |pp, idx|
    contact = contacts[pp[:contact]]
    pm      = payment_methods[pp[:contact]]
    next unless contact && pm
    invoice = company.invoices.find_by(invoice_number: pp[:inv])
    pnum = "#{DEMO_PREFIX.upcase}-PAY-2026-#{(idx + 1).to_s.rjust(4, '0')}#{pp[:suffix]}"
    Payment.find_or_create_by!(payment_number: pnum) do |p|
      p.company_id = company.id
      p.location_id = locations["AUB"].id
      p.payment_type = "one_time"
      p.status = "completed"
      p.amount = pp[:amount]
      p.payment_date = pp[:days_ago].days.ago.to_date
      p.processed_at = pp[:days_ago].days.ago
      p.payment_method_id = pm.id
      p.payer_type = "Contact"
      p.payer_id = contact.id
      if invoice
        p.payable_type = "Invoice"
        p.payable_id = invoice.id
      end
      p.gateway_name = "manual"
    end
    created += 1
  end
  total_collected = company.payments.where(status: "completed").sum(:amount)
  puts "  Payments: #{company.payments.count} ($#{total_collected.to_i} collected)"
end

# ── 31. Journal Entries (GL postings for closed_won deals) ─
puts "\n31. Posting closed-won deals to GL..."
if defined?(JournalEntry) && defined?(JournalEntryLine)
  ar_acct           = company.chart_of_accounts.find_by(account_number: '1110')
  cash_acct         = company.chart_of_accounts.find_by(account_number: '1010')
  inventory_new     = company.chart_of_accounts.find_by(account_number: '1210')
  inventory_used    = company.chart_of_accounts.find_by(account_number: '1220')
  new_sales_rev     = company.chart_of_accounts.find_by(account_number: '4010')
  used_sales_rev    = company.chart_of_accounts.find_by(account_number: '4020')
  cogs_new          = company.chart_of_accounts.find_by(account_number: '5010')
  cogs_used         = company.chart_of_accounts.find_by(account_number: '5020')
  sales_tax_acct    = company.chart_of_accounts.find_by(account_number: '2210')
  delivery_rev      = company.chart_of_accounts.find_by(account_number: '4300')
  commission_exp    = company.chart_of_accounts.find_by(account_number: '6010')
  accrued_exp       = company.chart_of_accounts.find_by(account_number: '2020')

  won_deals = deals.values.select { |d| d.stage == "closed_won" }
  won_deals.each_with_index do |deal, idx|
    next if deal.tax_posted
    je_memo = "Closing entry — #{deal.name}"
    next if company.journal_entries.exists?(memo: je_memo)

    is_new = (deal.home_cost || 0) > 30_000  # rough heuristic for demo
    rev_acct = is_new ? new_sales_rev : used_sales_rev
    inv_acct = is_new ? inventory_new : inventory_used
    cogs_acct = is_new ? cogs_new : cogs_used
    next unless ar_acct && rev_acct && inv_acct && cogs_acct

    # Use a non-numeric entry_number so JournalEntry#assign_entry_number
    # (which auto-increments based on numeric entries) ignores these seed
    # rows when handing out numbers to user-created entries. Otherwise
    # the "Approve" flow can collide with seeded JEs.
    # FIX B — fund about half of the closed-won deals THIS month (GL posted in the
    # current month) so Report 2's "Funded this month" is non-zero; leave the rest
    # backdated to prior months so they correctly fall out of the current pipeline.
    funded_this_month = idx.even?
    je_entry_date = funded_this_month ? (Date.current.beginning_of_month + (idx + 2)) : (35 + idx * 4).days.ago.to_date
    je = company.journal_entries.new(
      memo: je_memo,
      entry_date: je_entry_date,
      entry_number: "SEED-#{DEMO_PREFIX.upcase}-D#{deal.id}",
      source_type: "deal_closing",
      is_void: false
    )

    rev_credit = deal.selling_price - (deal.delivery_setup_cost || 0)
    # Sale recognition
    je.journal_entry_lines.build(chart_of_account_id: ar_acct.id, debit_amount: deal.selling_price + (deal.tax_amount || 0), credit_amount: 0, memo: "AR — #{deal.customer_name}", location_id: locations["AUB"].id)
    je.journal_entry_lines.build(chart_of_account_id: rev_acct.id, debit_amount: 0, credit_amount: rev_credit, memo: "Home sale revenue", location_id: locations["AUB"].id, department: is_new ? "new_sales" : "used_sales")
    if deal.delivery_setup_cost.to_f > 0 && delivery_rev
      je.journal_entry_lines.build(chart_of_account_id: delivery_rev.id, debit_amount: 0, credit_amount: deal.delivery_setup_cost, memo: "Delivery & setup", location_id: locations["AUB"].id, department: is_new ? "new_sales" : "used_sales")
    end
    if (deal.tax_amount || 0) > 0 && sales_tax_acct
      je.journal_entry_lines.build(chart_of_account_id: sales_tax_acct.id, debit_amount: 0, credit_amount: deal.tax_amount, memo: "Sales tax collected", location_id: locations["AUB"].id)
    end
    # COGS recognition
    je.journal_entry_lines.build(chart_of_account_id: cogs_acct.id, debit_amount: deal.home_cost, credit_amount: 0, memo: "Cost of home sold", location_id: locations["AUB"].id, department: is_new ? "new_sales" : "used_sales")
    je.journal_entry_lines.build(chart_of_account_id: inv_acct.id, debit_amount: 0, credit_amount: deal.home_cost, memo: "Inventory relief", location_id: locations["AUB"].id)
    # Commission accrual
    if (deal.commission_amount || 0) > 0 && commission_exp && accrued_exp
      je.journal_entry_lines.build(chart_of_account_id: commission_exp.id, debit_amount: deal.commission_amount, credit_amount: 0, memo: "Sales commission accrual", location_id: locations["AUB"].id, department: is_new ? "new_sales" : "used_sales")
      je.journal_entry_lines.build(chart_of_account_id: accrued_exp.id, debit_amount: 0, credit_amount: deal.commission_amount, memo: "Accrued commissions payable", location_id: locations["AUB"].id)
    end

    je.save!
    # Mark the deal posted so the in-app "Approve" button reports
    # "already posted to GL" instead of trying to create a duplicate JE.
    deal.update_columns(
      tax_posted: true,
      commission_posted: true,
      commission_posted_at: Time.current,
      gl_posted: true,
      gl_posted_at: je.entry_date.to_time,
      gl_journal_entry_id: je.id
    )
  end
  puts "  Journal entries: #{company.journal_entries.count} (#{JournalEntryLine.joins(:journal_entry).where(journal_entries: { company_id: company.id }).count} lines)"
end

# ── 32. Bill Payments ─────────────────────────────────────
puts "\n32. Setting up bill payments..."
if defined?(BillPayment)
  bank = company.bank_accounts.find_by(account_purpose: "operating")
  paid_bills = company.bills.where(status: %w[paid partially_paid])
  paid_bills.each do |bill|
    next if BillPayment.exists?(bill_id: bill.id)
    BillPayment.create!(
      bill_id: bill.id,
      company_id: company.id,
      amount: bill.amount_paid,
      payment_date: (bill.bill_date + 20.days),
      payment_method: "check",
      bank_account_id: bank&.id
    )
  end
  puts "  Bill payments: #{BillPayment.where(company_id: company.id).count}"
end

# ── 33. Manufacturer AR (warranty receivables from mfr) ───
puts "\n33. Setting up manufacturer AR..."
if defined?(ManufacturerArTransaction)
  company.warranty_claims.includes(:manufacturer).find_each.with_index do |claim, idx|
    next if ManufacturerArTransaction.exists?(warranty_claim_id: claim.id)
    original = claim.estimated_amount || 500
    paid_to_date = idx.zero? ? 0 : original * 0.5
    txn = ManufacturerArTransaction.create!(
      company_id: company.id,
      warranty_claim_id: claim.id,
      manufacturer_id: claim.manufacturer_id,
      transaction_number: "#{DEMO_PREFIX.upcase}-MAR-#{(idx + 1).to_s.rjust(3, '0')}",
      original_claim_amount: original,
      amount_paid_to_date: paid_to_date,
      amount_outstanding: original - paid_to_date,
      status: idx.zero? ? "open" : "partial",
      claim_date: 5.days.ago.to_date
    )
    if paid_to_date > 0 && defined?(ManufacturerArPayment)
      ManufacturerArPayment.create!(
        company_id: company.id,
        manufacturer_ar_transaction_id: txn.id,
        payment_number: "#{DEMO_PREFIX.upcase}-MARP-#{(idx + 1).to_s.rjust(3, '0')}",
        amount: paid_to_date,
        payment_date: 2.days.ago.to_date,
        payment_method: "check",
        recorded_by: users[:admin].email
      )
    end
  end
  puts "  Manufacturer AR transactions: #{ManufacturerArTransaction.where(company_id: company.id).count}"
end

# ── 33b. Annual Budget + Budget Lines (drives Budget vs Actual) ─
puts "\n33b. Setting up annual budget..."
if defined?(Budget) && defined?(BudgetLine)
  fiscal_year = Date.current.year
  budget = company.budgets.find_or_create_by!(name: "#{fiscal_year} Operating Budget — #{DEMO_PREFIX.capitalize}") do |b|
    b.fiscal_year = fiscal_year
    b.budget_type = "annual"
    b.consolidation_type = "consolidated"
    b.status = "active"
    b.description = "Annual operating budget for #{fiscal_year} (auto-seeded)"
    b.created_by_id = users[:admin].id
  end

  # Annual budget targets keyed to the chart-of-accounts numbers seeded
  # by DefaultChartOfAccountsSeeder. Variance report uses these vs the
  # JournalEntryLine amounts on the same accounts.
  budget_targets = {
    '4010' => 1_500_000,  # New Home Sales
    '4020' =>   500_000,  # Used Home Sales
    '4110' =>    60_000,  # Extended Warranty Revenue
    '4120' =>    40_000,  # Insurance Products
    '4140' =>    80_000,  # Finance Reserve
    '4210' =>   180_000,  # Service Labor
    '4220' =>   120_000,  # Parts Sales
    '4300' =>   200_000,  # Delivery & Setup Income
    '5010' => 1_050_000,  # COGS — New Home
    '5020' =>   320_000,  # COGS — Used Home
    '5200' =>   140_000,  # Delivery & Setup Costs
    '5300' =>    45_000,  # Floor Plan Interest Expense
    '5400' =>    65_000,  # Parts COGS
    '5500' =>    35_000,  # Warranty Expense
    '6010' =>   180_000,  # Sales Salaries & Commissions
    '6020' =>   240_000,  # Admin Salaries
    '6030' =>   140_000,  # Service Tech Pay
    '6040' =>    52_000,  # Payroll Taxes
    '6050' =>    65_000,  # Employee Benefits
    '6100' =>    72_000,  # Advertising & Marketing
    '6200' =>   120_000,  # Rent & Occupancy
    '6300' =>    36_000,  # Utilities
    '6400' =>    42_000,  # Insurance
    '6500' =>    24_000,  # Office & Admin
    '6700' =>    36_000,  # Professional Fees
  }

  created = 0
  budget_targets.each do |acct_number, annual|
    acct = company.chart_of_accounts.find_by(account_number: acct_number)
    next unless acct
    monthly = (annual / 12.0).round(2)
    line = budget.budget_lines.find_or_initialize_by(chart_of_account_id: acct.id)
    (1..12).each { |m| line.public_send("month_#{m}=", monthly) }
    line.annual_total = annual
    if line.new_record? || line.changed?
      line.save!
      created += 1
    end
  end
  puts "  Budget: #{budget.name} (#{budget.budget_lines.count} lines, status=#{budget.status})"
end

# ── 34. Buyer Portal Access (proxy-able client portal) ────
# BuyerPortalAccess.email is globally unique, but seeded contact emails are
# hardcoded and shared across every demo company (e.g. jsmuts1959@gmail.com).
# Whichever demo is seeded first claims those emails; subsequent demos would
# end up with 0 portal accounts. Namespace the portal login with DEMO_PREFIX
# so each demo company gets its own portal accounts.
puts "\n34. Setting up client portal access..."
if defined?(BuyerPortalAccess)
  portal_contacts = ["Jeretta Smuts", "Brian Keller", "William Martin", "Dennis Hopper"]
  portal_contacts.each do |name|
    contact = contacts[name]
    next unless contact
    portal_email = contact.email.sub('@', "+#{DEMO_PREFIX}@")
    BuyerPortalAccess.find_or_create_by!(email: portal_email) do |bpa|
      bpa.buyer_type = "Contact"
      bpa.buyer_id = contact.id
      bpa.company_id = company.id
      bpa.password = DEMO_PASSWORD
      bpa.password_confirmation = DEMO_PASSWORD
      bpa.status = "Active"
      bpa.role = "Client"
      bpa.portal_enabled = true
      bpa.email_opt_in = true
      bpa.sms_opt_in = false
      bpa.marketing_opt_in = true
    end
  end
  count = BuyerPortalAccess.where(company_id: company.id).count
  puts "  Portal accounts: #{count} (login email format: <contact>+#{DEMO_PREFIX}@<domain>, password #{DEMO_PASSWORD})"
end

# ── 35. Work Queue + Calendar (Tasks & Activities) ────────
# Populates the Work Queue tiles (Tasks today/week, Meetings today,
# Calls due, Reminders upcoming) and the Calendar (LeadActivity,
# ContactActivity, DealActivity, AccountActivity, Tasks).
#
# reminder_sent: true on past/completed records skips the
# after_create :schedule_reminders callback (which would otherwise
# call ActivityReminderService for any reminder_time in the past).
puts "\n35. Seeding work queue + calendar data..."

sales_users = [users[:sales1], users[:sales2]].compact
manager     = users[:manager]
tech        = users[:tech]
admin       = users[:admin]

today_9am = Date.current.to_time.change(hour: 9)
def at_hour(date, hour, min = 0) date.to_time.change(hour: hour, min: min) end

# ── Tasks ───────────────────────────────────────────────
lead_baker    = leads["Steven Baker"]
lead_hughes   = leads["Dorothy Hughes"]
lead_stewart  = leads["Kenneth Stewart"]
lead_morris   = leads["Ronald Morris"]
deal_smuts    = deals["Smuts - Champion Aspire"]
deal_martin   = deals["Martin - Emerald Sky 4483"]
deal_fisher   = deals["Fisher - Dutch 1676S"]
ticket_first  = company.service_tickets.where(status: ['open', 'in_progress']).first

task_specs = [
  { title: "Call back about financing options",     desc: "Customer asked about 21st Mortgage pre-qual",     due: at_hour(Date.current - 2.days, 14), priority: :high,   status: :pending,     assignee: sales_users[0], taskable: lead_baker,    mod: 'crm' },
  { title: "Email updated quote PDF",               desc: "Send revised quote with delivery fees",            due: at_hour(Date.current - 1.day,  10), priority: :urgent, status: :pending,     assignee: sales_users[1], taskable: deal_fisher,   mod: 'deals' },
  { title: "Confirm delivery date with Champion",   desc: "Need ship-from-factory ETA",                       due: at_hour(Date.current,          11), priority: :high,   status: :pending,     assignee: manager,        taskable: deal_martin,   mod: 'deals' },
  { title: "Walk-through prep for Stewart visit",   desc: "Stage the Emerald Sky unit on lot 12",             due: at_hour(Date.current,          15), priority: :medium, status: :pending,     assignee: sales_users[0], taskable: lead_stewart,  mod: 'crm' },
  { title: "Order replacement HVAC blower motor",   desc: "Part #BLM-2200 for Keller ticket",                 due: at_hour(Date.current,          16), priority: :high,   status: :in_progress, assignee: tech,           taskable: ticket_first,  mod: 'service' },
  { title: "Follow up on financing paperwork",      desc: "Hughes mailed in W-2 — confirm received",          due: at_hour(Date.current + 1.day,  10), priority: :medium, status: :pending,     assignee: sales_users[1], taskable: lead_hughes,   mod: 'crm' },
  { title: "Site inspection - Lakeside pad #34",    desc: "Verify pier spacing before delivery",              due: at_hour(Date.current + 2.days, 13), priority: :high,   status: :pending,     assignee: tech,           taskable: nil,           mod: 'service' },
  { title: "Prep Smuts closing paperwork",          desc: "Title transfer, retail installment contract",      due: at_hour(Date.current + 3.days,  9), priority: :high,   status: :pending,     assignee: manager,        taskable: deal_smuts,    mod: 'deals' },
  { title: "Demo new Skyline model to Morris",      desc: "Schedule 1hr walkthrough on lot",                  due: at_hour(Date.current + 4.days, 14), priority: :medium, status: :pending,     assignee: sales_users[0], taskable: lead_morris,   mod: 'crm' },
  { title: "Submit warranty claim - drywall crack", desc: "Champion warranty form + photos",                  due: at_hour(Date.current + 5.days, 10), priority: :medium, status: :pending,     assignee: tech,           taskable: nil,           mod: 'service' },
  { title: "Q2 sales pipeline review",              desc: "Forecast vs target — Auburn showroom",             due: at_hour(Date.current + 7.days, 16), priority: :low,    status: :pending,     assignee: manager,        taskable: nil,           mod: 'admin' },
  { title: "Refresh website inventory photos",      desc: "Five new units need lot photos",                   due: at_hour(Date.current + 10.days, 11), priority: :low,   status: :pending,     assignee: sales_users[1], taskable: nil,           mod: 'marketing' },

  # Admin-owned (Tom Mitchell / admin@<prefix>demo.com)
  { title: "Approve Hoosier bulk-order pricing",    desc: "Sign off on $450k Hoosier Land bulk discount",     due: at_hour(Date.current - 1.day, 16),  priority: :urgent, status: :pending,     assignee: admin,          taskable: deals["Hoosier Dev - Bulk Order"], mod: 'deals' },
  { title: "Review weekly KPI dashboard",           desc: "Pipeline + close rate review for Monday standup",  due: at_hour(Date.current,         9),   priority: :high,   status: :pending,     assignee: admin,          taskable: nil,           mod: 'admin' },
  { title: "Sign month-end commission run",         desc: "Validate commission payouts against closed deals", due: at_hour(Date.current + 2.days, 11), priority: :high,   status: :pending,     assignee: admin,          taskable: nil,           mod: 'admin' },
  { title: "Annual budget vs actual review",        desc: "Walk through Budget vs Actual report with CFO",    due: at_hour(Date.current + 6.days, 14), priority: :medium, status: :pending,     assignee: admin,          taskable: nil,           mod: 'admin' },
]

task_count = 0
task_specs.each do |spec|
  next unless spec[:assignee]
  existing = Task.where(company_id: company.id, title: spec[:title]).first
  next if existing
  Task.create!(
    company:        company,
    location:       locations["AUB"],
    title:          spec[:title],
    description:    spec[:desc],
    status:         spec[:status],
    priority:       spec[:priority],
    task_module:    spec[:mod],
    assigned_to_id: spec[:assignee].id,
    due_date:       spec[:due],
    taskable:       spec[:taskable],
    created_by:     spec[:assignee].email,
  )
  task_count += 1
end
puts "  Tasks: #{task_count} created (overdue/today/week/next-week mix)"

# ── Lead Activities ─────────────────────────────────────
# Meetings today/this week, Calls due today/overdue, Reminders within
# the next day, plus a few completed in the past for context.
la_specs = [
  # Meetings — today + this week
  { lead: lead_stewart, type: 'meeting', subject: 'Lot walkthrough — Skyline Amber Cove',
    start: at_hour(Date.current, 15), finish: at_hour(Date.current, 16, 30),
    meeting_location: 'Auburn Showroom — Lot 12', assignee: sales_users[0] },
  { lead: lead_baker, type: 'meeting', subject: 'Financing options consultation',
    start: at_hour(Date.current + 1.day, 11), finish: at_hour(Date.current + 1.day, 12),
    meeting_location: 'Auburn Showroom Office', assignee: sales_users[0] },
  { lead: lead_hughes, type: 'meeting', subject: 'Custom upgrade options review',
    start: at_hour(Date.current + 3.days, 14), finish: at_hour(Date.current + 3.days, 15),
    meeting_location: 'Auburn Showroom Office', assignee: sales_users[1] },

  # Calls — overdue + due today (work queue: activity_calls_due)
  { lead: lead_baker, type: 'call', subject: 'Follow-up: floorplan questions',
    due: at_hour(Date.current - 1.day, 10), phone: lead_baker&.phone, dir: 'outbound',
    assignee: sales_users[0] },
  { lead: lead_morris, type: 'call', subject: 'Confirm Saturday demo',
    due: at_hour(Date.current, 13), phone: lead_morris&.phone, dir: 'outbound',
    assignee: sales_users[0] },
  { lead: lead_hughes, type: 'call', subject: 'Returned voicemail — financing',
    due: at_hour(Date.current, 16), phone: lead_hughes&.phone, dir: 'inbound',
    assignee: sales_users[1] },

  # Reminders — upcoming (work queue: activity_reminders_upcoming)
  { lead: lead_stewart, type: 'reminder', subject: 'Send pre-walkthrough checklist',
    reminder: 2.hours.from_now, assignee: sales_users[0] },
  { lead: lead_morris, type: 'reminder', subject: 'Check trade-in valuation',
    reminder: 6.hours.from_now, assignee: sales_users[0] },

  # Tasks — overdue + today (work queue: activity_tasks_today)
  { lead: lead_baker, type: 'task', subject: 'Send Champion brochure PDF',
    due: at_hour(Date.current - 1.day, 9), assignee: sales_users[0] },
  { lead: lead_stewart, type: 'task', subject: 'Prepare offer sheet',
    due: at_hour(Date.current, 17), assignee: sales_users[0] },

  # Completed (past) — for timeline / not in workqueue
  { lead: lead_baker, type: 'call', subject: 'Initial discovery call',
    due: at_hour(Date.current - 3.days, 11), phone: lead_baker&.phone, dir: 'outbound',
    assignee: sales_users[0], status: 'completed' },

  # Admin (Tom Mitchell) — exec-level oversight
  { lead: lead_stewart, type: 'meeting', subject: 'Exec intro — high-value prospect',
    start: at_hour(Date.current + 2.days, 9), finish: at_hour(Date.current + 2.days, 10),
    meeting_location: 'Auburn Showroom Conference Room', assignee: admin },
  { lead: lead_hughes, type: 'call', subject: 'Owner intro call',
    due: at_hour(Date.current, 15), phone: lead_hughes&.phone, dir: 'outbound',
    assignee: admin },
  { lead: lead_morris, type: 'reminder', subject: 'Check on financing escalation',
    reminder: 4.hours.from_now, assignee: admin },

  # Manager (Sarah Collins) — sales coaching / oversight
  { lead: lead_morris, type: 'meeting', subject: 'Sales coaching ride-along',
    start: at_hour(Date.current + 1.day, 14), finish: at_hour(Date.current + 1.day, 15, 30),
    meeting_location: 'Auburn Showroom — Lot', assignee: manager },
  { lead: lead_baker, type: 'task', subject: 'Review Baker proposal before send',
    due: at_hour(Date.current, 12), assignee: manager },

  # Tech (Dave Torres) — service follow-ups tied to leads
  { lead: lead_hughes, type: 'reminder', subject: 'Schedule pre-delivery inspection',
    reminder: 3.hours.from_now, assignee: tech },
]

la_count = 0
la_specs.each do |s|
  next unless s[:lead] && s[:assignee]
  existing = LeadActivity.where(lead_id: s[:lead].id, subject: s[:subject]).first
  next if existing

  attrs = {
    lead:             s[:lead],
    user:             s[:assignee],
    assigned_to:      s[:assignee],
    activity_type:    s[:type],
    subject:          s[:subject],
    status:           s[:status] || 'pending',
    priority:         'medium',
    reminder_sent:    (s[:status] == 'completed'),  # skip after_create reminder
  }

  case s[:type]
  when 'meeting'
    attrs[:start_time] = s[:start]
    attrs[:end_time]   = s[:finish]
    attrs[:due_date]   = s[:start]
    attrs[:meeting_location] = s[:meeting_location]
  when 'call'
    attrs[:due_date]       = s[:due]
    attrs[:phone_number]   = s[:phone].presence || '(260) 555-0000'
    attrs[:call_direction] = s[:dir]
  when 'reminder'
    attrs[:reminder_time]  = s[:reminder]
    attrs[:due_date]       = s[:reminder]
    attrs[:reminder_method] = ['popup']
  when 'task'
    attrs[:due_date]       = s[:due]
  end

  if s[:status] == 'completed'
    attrs[:completed_at] = (s[:due] || s[:start] || Time.current) + 30.minutes
  end

  LeadActivity.create!(attrs)
  la_count += 1
end
puts "  Lead activities: #{la_count} created (meetings/calls/reminders/tasks)"

# ── Deal Activities ─────────────────────────────────────
da_specs = [
  { deal: deal_martin, type: 'meeting', subject: 'Contract signing — Emerald Sky',
    start: at_hour(Date.current + 1.day, 10), finish: at_hour(Date.current + 1.day, 11),
    assignee: sales_users[1] },
  { deal: deal_smuts, type: 'call', subject: 'Final close-out confirmation',
    due: at_hour(Date.current, 14), phone: '(260) 227-0394', dir: 'outbound',
    assignee: manager },
  { deal: deal_fisher, type: 'reminder', subject: 'Send updated proposal',
    reminder: 4.hours.from_now, assignee: sales_users[1] },
  { deal: deals["Hoosier Dev - Bulk Order"], type: 'meeting', subject: 'VP signoff — Hoosier bulk pricing',
    start: at_hour(Date.current + 2.days, 13), finish: at_hour(Date.current + 2.days, 14),
    assignee: admin },
  { deal: deal_martin, type: 'call', subject: 'Pre-delivery walk-through scheduling',
    due: at_hour(Date.current + 1.day, 9), phone: '(260) 555-2001', dir: 'outbound',
    assignee: tech },
  { deal: deal_smuts, type: 'task', subject: 'Owner review of Smuts deal margin',
    due: at_hour(Date.current, 10), assignee: admin },
]

da_count = 0
da_specs.each do |s|
  next unless s[:deal] && s[:assignee]
  existing = DealActivity.where(deal_id: s[:deal].id, subject: s[:subject]).first
  next if existing

  attrs = {
    deal:           s[:deal],
    user:           s[:assignee],
    assigned_to:    s[:assignee],
    activity_type:  s[:type],
    subject:        s[:subject],
    status:         'pending',
    priority:       'medium',
    reminder_sent:  false,
  }

  case s[:type]
  when 'meeting'
    attrs[:start_time] = s[:start]
    attrs[:end_time]   = s[:finish]
    attrs[:due_date]   = s[:start]
    attrs[:location]   = 'Auburn Showroom Office'
  when 'call'
    attrs[:due_date]       = s[:due]
    attrs[:phone_number]   = s[:phone]
    attrs[:call_direction] = s[:dir]
  when 'reminder'
    attrs[:reminder_time]   = s[:reminder]
    attrs[:due_date]        = s[:reminder]
    attrs[:reminder_method] = ['popup']
  when 'task'
    attrs[:due_date]       = s[:due]
  end

  DealActivity.create!(attrs)
  da_count += 1
end
puts "  Deal activities: #{da_count} created"

# ── Contact Activities ──────────────────────────────────
contact_keller  = contacts["Brian Keller"]
contact_smuts   = contacts["Jeretta Smuts"]
contact_martin  = contacts["William Martin"]

ca_specs = [
  { contact: contact_keller, type: 'call', subject: 'Service follow-up call',
    due: at_hour(Date.current, 11), phone: contact_keller&.phone, dir: 'outbound',
    assignee: tech },
  { contact: contact_smuts, type: 'meeting', subject: 'Post-delivery walkthrough',
    start: at_hour(Date.current + 2.days, 10), finish: at_hour(Date.current + 2.days, 11),
    assignee: manager },
  { contact: contact_martin, type: 'task', subject: 'Confirm utility hookup schedule',
    due: at_hour(Date.current + 1.day, 9), assignee: manager },

  # Admin (Tom Mitchell) — quarterly check-ins / VIP relationships
  { contact: contacts["Marcus Johnson"], type: 'meeting', subject: 'Quarterly check-in — Hoosier Land',
    start: at_hour(Date.current + 4.days, 10), finish: at_hour(Date.current + 4.days, 11),
    assignee: admin },
  { contact: contact_smuts, type: 'call', subject: 'Owner thank-you call',
    due: at_hour(Date.current, 17), phone: contact_smuts&.phone, dir: 'outbound',
    assignee: admin },

  # Sales reps — contact follow-ups
  { contact: contacts["Dennis Hopper"], type: 'call', subject: 'Lakeside community follow-up',
    due: at_hour(Date.current + 1.day, 11), phone: contacts["Dennis Hopper"]&.phone, dir: 'outbound',
    assignee: sales_users[0] },
  { contact: contacts["Robert Chen"], type: 'task', subject: 'Send Q2 loan pricing sheet',
    due: at_hour(Date.current + 2.days, 14), assignee: sales_users[1] },
]

ca_count = 0
ca_specs.each do |s|
  next unless s[:contact] && s[:assignee]
  existing = ContactActivity.where(contact_id: s[:contact].id, subject: s[:subject]).first
  next if existing

  attrs = {
    contact_id:    s[:contact].id,
    account_id:    s[:contact].account_id,
    user_id:       s[:assignee].id,
    assigned_to_id: s[:assignee].id,
    activity_type: s[:type],
    subject:       s[:subject],
    status:        'pending',
    priority:      'medium',
    reminder_sent: false,
  }

  case s[:type]
  when 'meeting'
    attrs[:start_time] = s[:start]
    attrs[:end_time]   = s[:finish]
    attrs[:due_date]   = s[:start]
    attrs[:meeting_location] = 'Auburn Showroom Office'
  when 'call'
    attrs[:due_date]       = s[:due]
    attrs[:phone_number]   = s[:phone].presence || '(260) 555-0000'
    attrs[:call_direction] = s[:dir]
  when 'task'
    attrs[:due_date]       = s[:due]
  end

  ContactActivity.create!(attrs)
  ca_count += 1
end
puts "  Contact activities: #{ca_count} created"

# ── 41. Report demo data (Inventory Stock List + Salesperson GP Pipeline) ──
# Idempotent: every record is guarded by find_or_create_by / update_columns, so
# re-running without RESET re-applies links instead of duplicating. Builds a full
# GP pipeline (Pending / Closed-Not-Funded / Funded), deal contention, and the two
# flag cases (missing cost, sold-no-deal) that the reports surface. All gross/cost
# is consumed from the unified Deal model methods by the reports — nothing here
# recomputes GP; it just sets the inputs (vehicle link, home_cost, gl_posted, etc.).
puts "\n41. Report demo data (inventory + GP pipeline)..."

# Uses the three DISTINCT locations created in section 2 (AUB / FTW / IND) so the
# funded-by-location grouping and Report 1 location column show real groups.
vget = ->(serial) { company.vehicles.find_by(serial_number: serial) }
this_month_date = Date.current.beginning_of_month + 6

# Build (or refresh) a demo deal linked to a vehicle + REAL salesperson. Uses
# update_columns to set report fields without firing close/GL callbacks.
build_rpt_deal = lambda do |key, name, vehicle, rep, attrs|
  deal = company.deals.find_or_create_by!(name: name) do |d|
    d.stage = attrs[:stage]
    d.assigned_to = rep.id
    d.contact_id = company.contacts.first&.id # Deal requires a contact or account
    d.location_id = vehicle&.location_id || locations["AUB"].id
    d.value = attrs[:selling_price]
    d.total_amount = attrs[:selling_price]
    d.customer_name = attrs[:customer_name]
    d.deal_number = "#{DEMO_PREFIX.upcase}-RPT-#{key}"
    d.custom_field_values = {}
  end
  cols = {
    stage:                  attrs[:stage],
    vehicle_id:             vehicle&.id,
    primary_salesperson_id: rep.id,
    owner_id:               rep.id,
    location_id:            vehicle&.location_id || locations["AUB"].id,
    selling_price:          attrs[:selling_price],
    customer_name:          attrs[:customer_name],
    updated_at:             Time.current
  }.merge(attrs.except(:stage, :selling_price, :customer_name))
  deal.update_columns(cols)
  deals[name] = deal
  deal
end

# --- PENDING + CONTENTION: one available vehicle with TWO open deals --------
contention_vehicle = vget.call("CLT-2019-T-889900")
if contention_vehicle
  build_rpt_deal.call("OPEN1", "[RPT] Alvarez — Clayton (open A)", contention_vehicle, users[:sales1],
    stage: "proposal",    selling_price: 38900, customer_name: "Gloria Alvarez")
  build_rpt_deal.call("OPEN2", "[RPT] Bennett — Clayton (open B)", contention_vehicle, users[:sales2],
    stage: "negotiation", selling_price: 39500, customer_name: "Carl Bennett")
end

# --- ON ORDER: open deal on an available_to_order unit -> Report 1 'On Order' -
order_v = vget.call("RMN-2026-A-001240")
if order_v
  build_rpt_deal.call("ORDER1", "[RPT] Castillo — Redman RM4068A (on order)", order_v, users[:sales1],
    stage: "proposal", selling_price: 142000, customer_name: "Rosa Castillo",
    lender_name: "Vanderbilt Mortgage", payment_type: "finance")
end

# --- CLOSED NOT FUNDED: closed_won, NOT gl_posted (the GL-approval gap) ------
cnf_v1 = vget.call("DH-2026-A-005002") # Fort Wayne
cnf_v2 = vget.call("SKY-2021-A-776600") # Fort Wayne
if cnf_v1
  build_rpt_deal.call("CNF1", "[RPT] Dawson — Dutch 3268A (closed, not funded)", cnf_v1, users[:sales2],
    stage: "closed_won", selling_price: 122000, customer_name: "Erin Dawson",
    home_cost: 87000, reconditioning_cost: 0, floor_plan_interest: 0, delivery_setup_cost: 4200,
    pack_amount: 2200, lender_name: "Triad Financial", gl_posted: false, gl_posted_at: nil,
    finance_reserve: 1500, product_margin: 800, won_at: this_month_date)
end
if cnf_v2
  build_rpt_deal.call("CNF2", "[RPT] Foster — Skyline (closed, not funded)", cnf_v2, users[:manager],
    stage: "closed_won", selling_price: 43000, customer_name: "Grant Foster",
    home_cost: 28000, reconditioning_cost: 0, floor_plan_interest: 0, delivery_setup_cost: 2000,
    pack_amount: 1000, lender_name: "21st Mortgage", gl_posted: false, gl_posted_at: nil,
    won_at: this_month_date)
end

# --- FUNDED THIS MONTH: closed_won, gl_posted this month; AUB + IND so the ---
# funded-by-location grouping spans 3 locations (with the section-10 funded units).
fund_v1 = vget.call("DH-2026-A-005001") # Auburn
fund_v2 = vget.call("DH-2026-S-005003") # Indianapolis
if fund_v1
  d = build_rpt_deal.call("FUND1", "[RPT] Harmon — Dutch 2872A (funded)", fund_v1, users[:sales1],
    stage: "closed_won", selling_price: 106000, customer_name: "Nina Harmon",
    home_cost: 77000, reconditioning_cost: 0, floor_plan_interest: 400, delivery_setup_cost: 4500,
    pack_amount: 2100, lender_name: "21st Mortgage", gl_posted: true,
    gl_posted_at: this_month_date.to_time, finance_reserve: 1500, product_margin: 800,
    won_at: this_month_date)
  fund_v1.update_columns(status: "sold", sold_via_deal_id: d.id)
end
if fund_v2
  d = build_rpt_deal.call("FUND2", "[RPT] Iverson — Dutch 1676S (funded)", fund_v2, users[:manager],
    stage: "closed_won", selling_price: 63500, customer_name: "Owen Iverson",
    home_cost: 45000, reconditioning_cost: 0, floor_plan_interest: 350, delivery_setup_cost: 2800,
    pack_amount: 1500, lender_name: "Vanderbilt Mortgage", gl_posted: true,
    gl_posted_at: this_month_date.to_time, finance_reserve: 1500, product_margin: 800,
    won_at: this_month_date)
  fund_v2.update_columns(status: "sold", sold_via_deal_id: d.id)
end

# --- MISSING COST: an available vehicle with NO cost -> Report 1 flags it ----
missing_v = vget.call("FLT-2017-B-554400")
missing_v&.update_columns(dealer_cost: nil, freight_cost: nil, pdi_cost: nil, total_cost: nil,
                          cost: nil, status: "available", sold_via_deal_id: nil)

# --- SOLD-NO-DEAL: sold vehicles with no linked deal -> Report 1 flags them --
%w[DH-2025-A-004990 RMN-2025-A-001150].each do |serial|
  v = vget.call(serial)
  next unless v
  v.update_columns(status: "sold", sold_via_deal_id: nil)
  company.deals.where(vehicle_id: v.id).update_all(vehicle_id: nil) # guard: unlink any deal
end

puts "  Report demo: pending+contention (2) & on-order (1); closed-not-funded (2); " \
     "funded this month (2: #{fund_v1&.location&.code}/#{fund_v2&.location&.code}); missing-cost + sold-no-deal flagged"

# ── Summary ────────────────────────────────────────────────
puts "\n" + "=" * 60
puts "DEMO COMPANY READY!"
puts "=" * 60
puts ""
puts "Company:  #{company.name} (ID: #{company.id})"
puts "URL:      https://dms.renterinsight.com/login"
puts "          https://staging-dms.renterinsight.com/login (staging)"
puts ""
puts "Login Credentials (Password: #{DEMO_PASSWORD})"
puts "-" * 55
user_list.each do |ud|
  printf "  %-15s %s\n", ud[:role], ud[:email]
end
puts ""
puts "Data Summary:"
puts "-" * 55
{
  "Locations"         => company.respond_to?(:locations)         ? company.locations.count : 0,
  "Users"             => company.users.count,
  "Vehicles"          => company.respond_to?(:vehicles)          ? company.vehicles.count : 0,
  "Leads"             => company.respond_to?(:leads)             ? company.leads.count : 0,
  "Accounts"          => company.respond_to?(:accounts)          ? company.accounts.count : 0,
  "Contacts"          => company.respond_to?(:contacts)          ? company.contacts.count : 0,
  "Deals"             => company.respond_to?(:deals)             ? company.deals.count : 0,
  "Quotes"            => company.respond_to?(:quotes)            ? company.quotes.count : 0,
  "Invoices"          => company.respond_to?(:invoices)          ? company.invoices.count : 0,
  "Service Tickets"   => company.respond_to?(:service_tickets)   ? company.service_tickets.count : 0,
  "Projects"          => company.respond_to?(:projects)          ? company.projects.count : 0,
  "Parts"             => company.respond_to?(:parts)             ? company.parts.count : 0,
  "Suppliers"         => company.respond_to?(:suppliers)         ? company.suppliers.count : 0,
  "Tags"              => company.respond_to?(:tags)              ? company.tags.count : 0,
  "Sources"           => Source.where(company_id: company.id).count,
  "Chart of Accounts" => company.respond_to?(:chart_of_accounts) ? company.chart_of_accounts.count : 0,
  "Bills"             => company.respond_to?(:bills)             ? company.bills.count : 0,
  "Bank Accounts"     => company.respond_to?(:bank_accounts)     ? company.bank_accounts.count : 0,
  "Commission Plans"  => company.respond_to?(:commission_plans)  ? company.commission_plans.count : 0,
  "Commission Pmts"   => company.respond_to?(:commission_payments) ? company.commission_payments.count : 0,
  "Nurture Sequences" => company.respond_to?(:nurture_sequences) ? company.nurture_sequences.count : 0,
  "Campaigns"         => company.respond_to?(:campaigns)         ? company.campaigns.count : 0,
  "Workflow Rules"    => company.respond_to?(:workflow_rules)    ? company.workflow_rules.count : 0,
  "Loans"             => company.respond_to?(:loans)             ? company.loans.count : 0,
  "Purchase Orders"   => company.respond_to?(:purchase_orders)   ? company.purchase_orders.count : 0,
  "Contractors"       => company.respond_to?(:contractors)       ? company.contractors.count : 0,
  "Warranty Claims"   => company.respond_to?(:warranty_claims)   ? company.warranty_claims.count : 0,
  "Agreement Tplts"   => company.respond_to?(:agreement_templates) ? company.agreement_templates.count : 0,
  "Agreements"        => company.respond_to?(:agreements)        ? company.agreements.count : 0,
  "Brochures"         => company.respond_to?(:brochures)         ? company.brochures.count : 0,
  "Listings"          => company.respond_to?(:listings)          ? company.listings.count : 0,
  "Payment Methods"   => defined?(PaymentMethod)                  ? PaymentMethod.where(company_id: company.id).count : 0,
  "Payments"          => company.respond_to?(:payments)           ? company.payments.count : 0,
  "  → Revenue (completed)" => company.respond_to?(:payments)     ? company.payments.where(status: 'completed').sum(:amount).to_i : 0,
  "Journal Entries"   => company.respond_to?(:journal_entries)    ? company.journal_entries.count : 0,
  "Bill Payments"     => defined?(BillPayment)                    ? BillPayment.where(company_id: company.id).count : 0,
  "Mfr AR Txns"       => defined?(ManufacturerArTransaction)      ? ManufacturerArTransaction.where(company_id: company.id).count : 0,
  "Budgets"           => company.respond_to?(:budgets)            ? company.budgets.count : 0,
  "Budget Lines"      => company.respond_to?(:budgets)            ? BudgetLine.joins(:budget).where(budgets: { company_id: company.id }).count : 0,
  "Portal Accounts"   => defined?(BuyerPortalAccess)              ? BuyerPortalAccess.where(company_id: company.id).count : 0,
  "Tasks"             => company.respond_to?(:tasks)              ? company.tasks.count : 0,
  "Lead Activities"   => LeadActivity.joins(:lead).where(leads: { company_id: company.id }).count,
  "Deal Activities"   => DealActivity.joins(:deal).where(deals: { company_id: company.id }).count,
  "Contact Activities" => ContactActivity.joins(:contact).where(contacts: { company_id: company.id }).count,
  "Tickets Scheduled" => company.service_tickets.where.not(scheduled_date: nil).count,
  "Deals w/ Vehicle"  => company.deals.where.not(vehicle_id: nil).count,
  "Open (Pending)"    => company.deals.where(stage: Reports::InventoryDealQuery::OPEN_STAGES).count,
  "Closed Not Funded" => company.deals.where(stage: "closed_won", gl_posted: false).count,
  "Funded This Month" => company.deals.where(gl_posted: true, gl_posted_at: Date.current.beginning_of_month..Date.current.end_of_month).count,
  "Contention Vehicles" => company.deals.where(stage: Reports::InventoryDealQuery::OPEN_STAGES).where.not(vehicle_id: nil).group(:vehicle_id).count.count { |_, c| c >= 2 },
}.each do |label, count|
  printf "  %-20s %d\n", label, count
end

# Report breakdowns: vehicles by location and by New/Used × section size.
puts ""
puts "Inventory by Location:"
company.vehicles.where(is_deleted: [false, nil]).includes(:location)
       .group_by { |v| v.location&.name || "Unassigned" }
       .sort_by { |name, _| name.to_s }
       .each { |name, vs| printf "  %-20s %d\n", name, vs.size }
puts "Inventory by Section:"
company.vehicles.where(is_deleted: [false, nil])
       .group_by { |v| size = v.sections.to_i >= 2 ? "Double" : (v.sections.to_i == 1 ? "Single" : "Unspecified"); "#{(v.condition.to_s.capitalize.presence || 'Unspecified')} — #{size}" }
       .sort_by { |k, _| k }
       .each { |k, vs| printf "  %-22s %d\n", k, vs.size }

puts ""
puts "To reset and re-seed:"
puts "  RESET=true bin/rails runner \"load 'db/seeds/demo_company.rb'\""
puts "=" * 60
