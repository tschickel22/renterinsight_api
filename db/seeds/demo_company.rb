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
      projects project_templates
      purchase_orders parts suppliers service_tickets
      invoices quotes deals contacts accounts
      leads vehicles units properties
      nurture_sequences page_layouts custom_fields
      tags bank_accounts locations
    ].each do |assoc|
      if existing.respond_to?(assoc)
        count = existing.send(assoc).count
        existing.send(assoc).destroy_all
        puts "  Deleted #{count} #{assoc}" if count > 0
      end
    end
    existing.users.destroy_all
    existing.roles.destroy_all if existing.respond_to?(:roles)
    existing.destroy!
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

# ── 2. Locations ───────────────────────────────────────────
puts "\n2. Creating locations..."
locations = {}

[
  { name: "Auburn Showroom",    code: "AUB", address: "4520 Homestead Road", city: "Auburn",       state: "IN", zip: "46706", phone: "(260) 555-0100" },
  { name: "Fort Wayne Center",  code: "FTW", address: "8900 Lima Road",      city: "Fort Wayne",   state: "IN", zip: "46818", phone: "(260) 555-0200" },
  { name: "Indianapolis South", code: "IND", address: "3200 S Meridian St",  city: "Indianapolis", state: "IN", zip: "46217", phone: "(317) 555-0300" },
].each do |d|
  loc = company.locations.find_or_create_by!(name: d[:name]) do |l|
    l.code = d[:code]
    l.address_line1 = d[:address]
    l.city = d[:city]
    l.state = d[:state]
    l.zip_code = d[:zip]
    l.phone = d[:phone]
    l.active = true
  end
  locations[d[:code]] = loc
  puts "  Location: #{loc.name} (#{loc.code})"
end

# ── 3. Users ───────────────────────────────────────────────
puts "\n3. Creating users..."
users = {}

user_list = [
  { key: :admin,   email: "admin@#{DEMO_EMAIL_DOMAIN}",   first: "Tom",     last: "Mitchell",  role: "platform_admin" },
  { key: :manager, email: "sarah@#{DEMO_EMAIL_DOMAIN}",   first: "Sarah",   last: "Collins",   role: "company_admin" },
  { key: :sales1,  email: "mike@#{DEMO_EMAIL_DOMAIN}",    first: "Mike",    last: "Henderson", role: "user" },
  { key: :sales2,  email: "jessica@#{DEMO_EMAIL_DOMAIN}", first: "Jessica", last: "Park",      role: "user" },
  { key: :tech,    email: "dave@#{DEMO_EMAIL_DOMAIN}",    first: "Dave",    last: "Torres",    role: "user" },
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
puts "\n4. Creating roles..."
if company.respond_to?(:roles)
  roles = {}
  [
    { name: "Sales Manager", description: "Full CRM + inventory access" },
    { name: "Sales Rep",     description: "CRM access, quotes, leads" },
    { name: "Service Tech",  description: "Service tickets and parts" },
  ].each do |rd|
    role = company.roles.find_or_create_by!(name: rd[:name]) do |r|
      r.description = rd[:description]
    end
    roles[rd[:name]] = role
    puts "  Role: #{role.name}"
  end

  if defined?(UserRole)
    { manager: "Sales Manager", sales1: "Sales Rep", sales2: "Sales Rep", tech: "Service Tech" }.each do |ukey, rname|
      next unless roles[rname] && users[ukey]
      UserRole.find_or_create_by!(user_id: users[ukey].id, role_id: roles[rname].id)
    end
    puts "  Roles assigned to users"
  end
end

# ── 5. Tags ────────────────────────────────────────────────
puts "\n5. Creating tags..."
tag_names = ["Hot Lead", "VIP Customer", "First-Time Buyer", "Investor", "Referral",
             "Trade-In", "Cash Buyer", "Financing Needed", "Rural Delivery", "Priority"]
tag_names.each { |name| company.tags.find_or_create_by!(name: name) }
puts "  Created #{tag_names.length} tags"

# ── 6. Accounts ────────────────────────────────────────────
puts "\n6. Creating accounts..."
accounts = {}

account_data = [
  { name: "21st Mortgage Corporation",  type: "lender",   website: "21stmortgage.com",  phone: "(865) 555-0100", city: "Knoxville",    state: "TN" },
  { name: "Vanderbilt Mortgage",        type: "lender",   website: "vmf.com",           phone: "(865) 555-0200", city: "Maryville",    state: "TN" },
  { name: "Cascade Financial Services", type: "lender",   website: "cascadeloans.com",  phone: "(877) 555-0300", city: "Boise",        state: "ID" },
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
  end
  contacts["#{cd[:first]} #{cd[:last]}"] = contact
end
puts "  Created #{contact_data.length} contacts"

# ── 8. Leads ───────────────────────────────────────────────
puts "\n8. Creating leads..."
leads = {}

lead_data = [
  { first: "Steven",   last: "Baker",    email: "sbaker@gmail.com",      phone: "(260) 555-5001", status: "new",       location: "AUB" },
  { first: "Michelle", last: "Rivera",   email: "mrivera@yahoo.com",     phone: "(260) 555-5002", status: "new",       location: "AUB" },
  { first: "Gregory",  last: "Ward",     email: "gward@outlook.com",     phone: "(317) 555-5003", status: "new",       location: "FTW" },
  { first: "Dorothy",  last: "Hughes",   email: "dhughes@gmail.com",     phone: "(574) 555-5004", status: "contacted", location: "AUB" },
  { first: "Larry",    last: "Coleman",  email: "lcoleman@hotmail.com",  phone: "(260) 555-5005", status: "contacted", location: "FTW" },
  { first: "Nancy",    last: "Reed",     email: "nreed@gmail.com",       phone: "(812) 555-5006", status: "contacted", location: "IND" },
  { first: "Kenneth",  last: "Stewart",  email: "kstewart@icloud.com",   phone: "(260) 555-5007", status: "qualified", location: "AUB" },
  { first: "Betty",    last: "Sanchez",  email: "bsanchez@gmail.com",    phone: "(317) 555-5008", status: "qualified", location: "FTW" },
  { first: "Ronald",   last: "Morris",   email: "rmorris@yahoo.com",     phone: "(260) 555-5009", status: "qualified", location: "AUB" },
  { first: "Sharon",   last: "Bell",     email: "sbell22@gmail.com",     phone: "(574) 555-5010", status: "proposal",  location: "FTW" },
  { first: "Frank",    last: "Wood",     email: "fwood@outlook.com",     phone: "(260) 555-5011", status: "proposal",  location: "AUB" },
  { first: "Helen",    last: "Rogers",   email: "hrogers@gmail.com",     phone: "(317) 555-5012", status: "proposal",  location: "IND" },
  { first: "Arthur",   last: "Gray",     email: "agray@hotmail.com",     phone: "(260) 555-5013", status: "won",       location: "AUB" },
  { first: "Diane",    last: "Watson",   email: "dwatson@gmail.com",     phone: "(260) 555-5014", status: "won",       location: "FTW" },
  { first: "Carl",     last: "Brooks",   email: "cbrooks@yahoo.com",     phone: "(812) 555-5015", status: "lost",      location: "AUB" },
]

lead_data.each do |ld|
  lead = company.leads.find_or_create_by!(email: ld[:email]) do |l|
    l.first_name = ld[:first]
    l.last_name = ld[:last]
    l.phone = ld[:phone]
    l.status = ld[:status]
    l.owner_id = users[:manager].id
    l.location_id = locations[ld[:location]].id
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
  { year: 2026, make: "Champion",      model: "Emerald Sky 4483A",      serial: "112-000-H-A-C412920B", beds: 4, baths: 2, sqft: 1680, price: 124900, cost: 92000, status: "available",  location: "AUB",
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
  { year: 2026, make: "Champion",      model: "Aspire DAP2064H42222",   serial: "112-000-H-D-C412935F", beds: 4, baths: 2, sqft: 1984, price: 145000, cost: 108000, status: "in_transit", location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Redman",        model: "RM2856A",                serial: "RMN-2026-A-001234",    beds: 3, baths: 2, sqft: 1344, price: 82500,  cost: 60000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Redman",        model: "RM3264A",                serial: "RMN-2026-A-001235",    beds: 3, baths: 2, sqft: 1536, price: 96700,  cost: 71000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2025, make: "Redman",        model: "RM1660A",                serial: "RMN-2025-A-001100",    beds: 2, baths: 1, sqft: 960,  price: 49900,  cost: 36000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Redman",        model: "RM4068A",                serial: "RMN-2026-A-001240",    beds: 4, baths: 2, sqft: 2040, price: 138000, cost: 102000, status: "on_order",  location: "FTW", images: [], floor_plan: nil },
  { year: 2025, make: "Redman",        model: "RM2448A",                serial: "RMN-2025-A-001150",    beds: 3, baths: 2, sqft: 1152, price: 68500,  cost: 50000, status: "sold",       location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 2872A",            serial: "DH-2026-A-005001",     beds: 3, baths: 2, sqft: 1536, price: 105000, cost: 77000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 3268A",            serial: "DH-2026-A-005002",     beds: 3, baths: 2, sqft: 1632, price: 118500, cost: 87000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 1676S",            serial: "DH-2026-S-005003",     beds: 2, baths: 1, sqft: 1056, price: 62000,  cost: 45000, status: "available",  location: "IND", images: [], floor_plan: nil },
  { year: 2025, make: "Dutch Housing", model: "Dutch 2460A",            serial: "DH-2025-A-004990",     beds: 3, baths: 2, sqft: 1200, price: 74900,  cost: 55000, status: "sold",       location: "AUB", images: [], floor_plan: nil },
  { year: 2019, make: "Clayton",       model: "TRU The Satisfaction",   serial: "CLT-2019-T-889900",    beds: 3, baths: 2, sqft: 1120, price: 35000,  cost: 22000, status: "available",  location: "AUB", images: [], floor_plan: nil },
  { year: 2021, make: "Skyline",       model: "Amber Cove 266CT",       serial: "SKY-2021-A-776600",    beds: 3, baths: 2, sqft: 1216, price: 42500,  cost: 28000, status: "available",  location: "FTW", images: [], floor_plan: nil },
  { year: 2017, make: "Fleetwood",     model: "Berkshire 3252B",        serial: "FLT-2017-B-554400",    beds: 4, baths: 2, sqft: 1664, price: 38000,  cost: 20000, status: "available",  location: "AUB", images: [], floor_plan: nil },
]

vehicle_data.each do |vd|
  vehicle = company.vehicles.find_or_create_by!(serial_number: vd[:serial]) do |v|
    v.year = vd[:year]
    v.make = vd[:make]
    v.model = vd[:model]
    v.stock_number = "STK-#{rand(10000..99999)}"
    v.status = vd[:status]
    v.location_id = locations[vd[:location]].id
    v.sale_price = vd[:price]
    v.dealer_cost = vd[:cost]
    v.cost = vd[:cost]
    v.bedrooms = vd[:beds]
    v.bathrooms = vd[:baths]
    v.square_feet = vd[:sqft]
    v.condition = vd[:year] >= 2025 ? "New" : "Used"
    v.home_type = "Manufactured"
    v.is_deleted = false
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
  vehicles[vd[:serial]] = vehicle
end
puts "  Created #{vehicle_data.length} vehicles (#{vehicle_data.count { |v| v[:images].present? }} with photos)"

# ── 10. Deals ──────────────────────────────────────────────
puts "\n10. Creating deals..."
deals = {}

deal_data = [
  { title: "Smuts - Champion Aspire",      stage: "won",           amount: 114235, contact: "Jeretta Smuts",     account: nil },
  { title: "Martin - Emerald Sky 4483",    stage: "negotiation",   amount: 124900, contact: "William Martin",    account: "Martin Family Properties" },
  { title: "O'Brien - Redman RM2856A",     stage: "proposal",      amount: 89500,  contact: "Kevin O'Brien",     account: nil },
  { title: "Lakeside - Dutch 2872A",       stage: "proposal",      amount: 105000, contact: "Dennis Hopper",     account: "Lakeside MH Community" },
  { title: "Gonzalez - Heritage 1676H",    stage: "qualification", amount: 62900,  contact: "Maria Gonzalez",    account: nil },
  { title: "Crawford - Redman RM3264A",    stage: "qualification", amount: 96700,  contact: "Daniel Crawford",   account: nil },
  { title: "Fisher - Dutch 1676S",         stage: "discovery",     amount: 62000,  contact: "Tammy Fisher",      account: nil },
  { title: "Hoosier Dev - Bulk Order",     stage: "discovery",     amount: 450000, contact: "Marcus Johnson",    account: "Hoosier Land Development" },
  { title: "Keller - Used Clayton",        stage: "won",           amount: 38500,  contact: "Brian Keller",      account: nil },
  { title: "Turner - Skyline Amber Cove",  stage: "lost",          amount: 42500,  contact: "Jason Turner",      account: nil },
]

deal_data.each do |dd|
  contact = contacts[dd[:contact]]
  account = dd[:account] ? accounts[dd[:account]] : nil

  deal = company.deals.find_or_create_by!(name: dd[:title]) do |d|
    d.stage = dd[:stage]
    d.contact_id = contact&.id
    d.account_id = account&.id
    d.assigned_to = [users[:sales1].id, users[:sales2].id].sample
    d.location_id = [locations["AUB"], locations["FTW"]].sample.id
    d.value = dd[:amount]
    d.total_amount = dd[:amount]
    d.customer_name = dd[:contact]
    d.deal_number = "DL-#{rand(1000..9999)}"
  end
  deals[dd[:title]] = deal
end
puts "  Created #{deal_data.length} deals"

# ── 11. Quotes ─────────────────────────────────────────────
puts "\n11. Creating quotes..."
quote_data = [
  { number: "Q-2026-001", status: "accepted", subtotal: 88350,  tax: 4971, total: 114235, contact: "Jeretta Smuts",  notes: "Champion Aspire DAP1676H32222 with upgrades" },
  { number: "Q-2026-002", status: "sent",     subtotal: 124900, tax: 7494, total: 137394, contact: "William Martin", notes: "Emerald Sky 4483A" },
  { number: "Q-2026-003", status: "draft",    subtotal: 82500,  tax: 4950, total: 91950,  contact: "Kevin O'Brien",  notes: "Redman RM2856A" },
  { number: "Q-2026-004", status: "sent",     subtotal: 105000, tax: 6300, total: 116300, contact: "Dennis Hopper",  notes: "Dutch 2872A for Lakeside" },
  { number: "Q-2026-005", status: "expired",  subtotal: 42500,  tax: 2550, total: 47550,  contact: "Jason Turner",   notes: "Skyline Amber Cove" },
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
  end
end
puts "  Created #{quote_data.length} quotes"

# ── 12. Invoices ───────────────────────────────────────────
puts "\n12. Creating invoices..."
invoice_data = [
  { number: "INV-2026-001", status: "paid",    total: 6400,   contact: "Jeretta Smuts",  notes: "Down payment - Champion Aspire" },
  { number: "INV-2026-002", status: "paid",    total: 107835, contact: "Jeretta Smuts",  notes: "Balance - Champion Aspire" },
  { number: "INV-2026-003", status: "pending", total: 12490,  contact: "William Martin", notes: "10% deposit - Emerald Sky" },
  { number: "INV-2026-004", status: "pending", total: 8250,   contact: "Kevin O'Brien",  notes: "Deposit - Redman RM2856A" },
  { number: "INV-2026-005", status: "paid",    total: 38500,  contact: "Brian Keller",   notes: "Full payment - Used Clayton" },
  { number: "INV-2026-006", status: "overdue", total: 10500,  contact: "Dennis Hopper",  notes: "Deposit - Dutch 2872A" },
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
  end
end
puts "  Created #{invoice_data.length} invoices"

# ── 13. Service Tickets ────────────────────────────────────
puts "\n13. Creating service tickets..."
ticket_data = [
  { title: "Door alignment after delivery",           status: "open",        priority: "high",   contact: "Jeretta Smuts" },
  { title: "HVAC not heating properly",               status: "in_progress", priority: "high",   contact: "Brian Keller" },
  { title: "Kitchen faucet leak",                     status: "open",        priority: "medium", contact: "Angela Brooks" },
  { title: "Carpet seam separation - master bedroom", status: "open",        priority: "medium", contact: "Raymond Price" },
  { title: "Skirting installation",                   status: "scheduled",   priority: "low",    contact: "Jeretta Smuts" },
  { title: "Pre-delivery inspection - Emerald Sky",   status: "open",        priority: "high",   contact: "William Martin" },
  { title: "Window crank replacement",                status: "completed",   priority: "low",    contact: "Sandra Mitchell" },
  { title: "Smoke detector installation",             status: "completed",   priority: "medium", contact: "Brian Keller" },
  { title: "Marriage line drywall crack",              status: "in_progress", priority: "medium", contact: "Angela Brooks" },
  { title: "Electrical outlet not working - kitchen",  status: "open",       priority: "high",   contact: "Raymond Price" },
]

ticket_data.each_with_index do |td, idx|
  contact = contacts[td[:contact]]
  company.service_tickets.find_or_create_by!(title: td[:title]) do |st|
    st.status = td[:status]
    st.priority = td[:priority]
    st.contact_id = contact&.id
    st.account_id = contact&.account_id
    st.assigned_to = users[:tech].id
    st.location_id = locations["AUB"].id
    st.ticket_number = "ST-2026-#{(idx + 1).to_s.rjust(3, '0')}"
    st.description = td[:title]
  end
end
puts "  Created #{ticket_data.length} service tickets"

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
  end
end
puts "  Created #{parts_data.length} parts"

# ── 16. RBAC Resources ────────────────────────────────────
puts "\n16. Seeding RBAC resources..."
if defined?(Resource) && Resource.respond_to?(:seed_defaults)
  Resource.seed_defaults
  puts "  Resources seeded"
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
  puts "\n18. Creating projects..."

  [
    { deal: "Smuts - Champion Aspire",  name: "Smuts - Champion Aspire Setup",   status: "in_progress", done: 8,  current: 9 },
    { deal: "Keller - Used Clayton",    name: "Keller - Used Clayton Setup",     status: "completed",   done: 17, current: nil },
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
  "Locations"       => company.respond_to?(:locations)       ? company.locations.count : 0,
  "Users"           => company.users.count,
  "Vehicles"        => company.respond_to?(:vehicles)        ? company.vehicles.count : 0,
  "Leads"           => company.respond_to?(:leads)           ? company.leads.count : 0,
  "Accounts"        => company.respond_to?(:accounts)        ? company.accounts.count : 0,
  "Contacts"        => company.respond_to?(:contacts)        ? company.contacts.count : 0,
  "Deals"           => company.respond_to?(:deals)           ? company.deals.count : 0,
  "Quotes"          => company.respond_to?(:quotes)          ? company.quotes.count : 0,
  "Invoices"        => company.respond_to?(:invoices)        ? company.invoices.count : 0,
  "Service Tickets" => company.respond_to?(:service_tickets) ? company.service_tickets.count : 0,
  "Projects"        => company.respond_to?(:projects)        ? company.projects.count : 0,
  "Parts"           => company.respond_to?(:parts)           ? company.parts.count : 0,
  "Suppliers"       => company.respond_to?(:suppliers)       ? company.suppliers.count : 0,
  "Tags"            => company.respond_to?(:tags)            ? company.tags.count : 0,
}.each do |label, count|
  printf "  %-20s %d\n", label, count
end
puts ""
puts "To reset and re-seed:"
puts "  RESET=true bin/rails runner \"load 'db/seeds/demo_company.rb'\""
puts "=" * 60
