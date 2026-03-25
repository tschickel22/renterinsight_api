# db/seeds/demo_company.rb
#
# Creates a realistic demo company for prospect demos.
#
# Usage:
#   bin/rails runner "load 'db/seeds/demo_company.rb'"
#
# Reset & re-seed:
#   bin/rails runner "load 'db/seeds/demo_company.rb'" RESET=true
#
# This creates:
#   - 1 Company: "Sunshine MH Homes" (or custom via DEMO_NAME env var)
#   - 3 Locations (showrooms)
#   - 5 Users (admin, manager, 2 sales reps, service tech)
#   - RBAC roles & permissions
#   - 18 Vehicles (inventory - Champion, Redman, Dutch Housing) with S3 images
#   - 15 Leads across pipeline stages
#   - 8 Accounts (builders, lenders, customers)
#   - 20 Contacts linked to accounts
#   - 10 Deals across stages
#   - 2 Projects (1 in-progress, 1 completed) with 17-phase template
#   - 5 Quotes (draft, sent, accepted, expired, declined)
#   - 8 Invoices (paid, pending, overdue)
#   - 10 Service Tickets
#   - 15 Parts + 3 Suppliers + 2 Purchase Orders
#   - Tags, Activities, Notes
#
# Login credentials (all use password: Demo2026!)
#   admin@sunshinedemo.com       - Platform Admin
#   sarah@sunshinedemo.com       - Company Admin / Sales Manager
#   mike@sunshinedemo.com        - Sales Rep (Auburn location)
#   jessica@sunshinedemo.com     - Sales Rep (Fort Wayne location)
#   dave@sunshinedemo.com        - Service Technician
#

DEMO_PASSWORD = "Demo2026!"
DEMO_PREFIX = ENV['DEMO_PREFIX'] || 'sunshine'              # Used for email domain
DEMO_COMPANY_NAME = ENV['DEMO_NAME'] || "Sunshine MH Homes"
DEMO_EMAIL_DOMAIN = "#{DEMO_PREFIX}demo.com"                 # admin@sunshinedemo.com, admin@abcdemo.com, etc.

puts "=" * 60
puts "DEMO COMPANY SEEDER"
puts "=" * 60
puts "  Company: #{DEMO_COMPANY_NAME}"
puts "  Email domain: #{DEMO_EMAIL_DOMAIN}"
puts "  Prefix: #{DEMO_PREFIX}"
puts ""
puts "  Usage for additional companies:"
puts "    DEMO_NAME='ABC Homes' DEMO_PREFIX='abc' bin/rails runner \"load 'db/seeds/demo_company.rb'\""
puts "=" * 60

# ── Reset if requested ─────────────────────────────────────
if ENV['RESET'] == 'true'
  existing = Company.find_by(name: DEMO_COMPANY_NAME)
  if existing
    puts "Resetting existing demo company (ID: #{existing.id})..."
    # Delete in reverse dependency order
    %i[
      purchase_orders parts suppliers service_tickets
      invoices quotes deals contacts accounts
      leads vehicles units properties
      projects project_templates
      nurture_sequences page_layouts custom_fields
      tags bank_accounts
    ].each do |assoc|
      if existing.respond_to?(assoc)
        count = existing.send(assoc).count
        existing.send(assoc).destroy_all
        puts "  Deleted #{count} #{assoc}"
      end
    end
    existing.users.destroy_all
    existing.roles.destroy_all if existing.respond_to?(:roles)
    existing.destroy!
    puts "  Company deleted."
  end
end

# ── Company ────────────────────────────────────────────────
puts "\n1. Creating company..."
company = Company.find_or_create_by!(name: DEMO_COMPANY_NAME) do |c|
  c.email = "info@sunshinemhhomes.com"
  c.phone = "(260) 555-0100"
  c.street = "4520 Homestead Road"
  c.city = "Auburn"
  c.state = "IN"
  c.zip = "46706"
  c.website = "https://sunshinemhhomes.com"
  c.is_active = true
  # Disable payment gateway for demo
  c.external_payments_id = nil
  c.use_same_bank_account_for_deposits = true
end
puts "  Company: #{company.name} (ID: #{company.id})"

# ── Locations ──────────────────────────────────────────────
puts "\n2. Creating locations..."
locations = {}

[
  { name: "Auburn Showroom",     code: "AUB", street: "4520 Homestead Road",  city: "Auburn",     state: "IN", zip: "46706", phone: "(260) 555-0100" },
  { name: "Fort Wayne Center",   code: "FTW", street: "8900 Lima Road",       city: "Fort Wayne", state: "IN", zip: "46818", phone: "(260) 555-0200" },
  { name: "Indianapolis South",  code: "IND", street: "3200 S Meridian St",   city: "Indianapolis", state: "IN", zip: "46217", phone: "(317) 555-0300" },
].each do |loc_data|
  loc = company.locations.find_or_create_by!(name: loc_data[:name]) do |l|
    l.code = loc_data[:code]
    l.street = loc_data[:street]
    l.city = loc_data[:city]
    l.state = loc_data[:state]
    l.zip = loc_data[:zip]
    l.phone = loc_data[:phone]
    l.is_active = true
  end
  locations[loc_data[:code]] = loc
  puts "  Location: #{loc.name} (#{loc.code})"
end

# ── Users ──────────────────────────────────────────────────
puts "\n3. Creating users..."
users = {}

user_data = [
  { key: :admin,   email: "admin@#{DEMO_EMAIL_DOMAIN}",   first: "Tom",     last: "Mitchell",  role: "platform_admin",  location: nil },
  { key: :manager, email: "sarah@#{DEMO_EMAIL_DOMAIN}",   first: "Sarah",   last: "Collins",   role: "company_admin",   location: "AUB" },
  { key: :sales1,  email: "mike@#{DEMO_EMAIL_DOMAIN}",    first: "Mike",    last: "Henderson", role: "user",            location: "AUB" },
  { key: :sales2,  email: "jessica@#{DEMO_EMAIL_DOMAIN}", first: "Jessica", last: "Park",      role: "user",            location: "FTW" },
  { key: :tech,    email: "dave@#{DEMO_EMAIL_DOMAIN}",    first: "Dave",    last: "Torres",    role: "user",            location: "AUB" },
]

user_data.each do |ud|
  user = company.users.find_or_initialize_by(email: ud[:email])
  user.assign_attributes(
    first_name: ud[:first],
    last_name: ud[:last],
    role: ud[:role],
    password: DEMO_PASSWORD,
    password_confirmation: DEMO_PASSWORD,
    is_active: true,
    location_id: ud[:location] ? locations[ud[:location]]&.id : nil
  )
  user.confirmed_at = Time.current if user.respond_to?(:confirmed_at)
  user.save!
  users[ud[:key]] = user
  puts "  User: #{user.email} (#{ud[:role]})"
end

# ── RBAC Roles ─────────────────────────────────────────────
puts "\n4. Creating roles..."
if company.respond_to?(:roles)
  roles = {}

  [
    { name: "Sales Manager",    description: "Full CRM + inventory access, can manage team" },
    { name: "Sales Rep",        description: "CRM access, can create quotes and manage leads" },
    { name: "Service Tech",     description: "Service tickets and parts access" },
  ].each do |role_data|
    role = company.roles.find_or_create_by!(name: role_data[:name]) do |r|
      r.description = role_data[:description]
      r.is_active = true
    end
    roles[role_data[:name]] = role
    puts "  Role: #{role.name}"
  end

  # Assign roles to users
  if defined?(UserRole)
    { manager: "Sales Manager", sales1: "Sales Rep", sales2: "Sales Rep", tech: "Service Tech" }.each do |user_key, role_name|
      next unless roles[role_name] && users[user_key]
      UserRole.find_or_create_by!(user_id: users[user_key].id, role_id: roles[role_name].id)
    end
    puts "  Roles assigned to users"
  end
end

# ── Tags ───────────────────────────────────────────────────
puts "\n5. Creating tags..."
tag_names = ["Hot Lead", "VIP Customer", "First-Time Buyer", "Investor", "Referral",
             "Trade-In", "Cash Buyer", "Financing Needed", "Rural Delivery", "Priority"]
tags = {}
tag_names.each do |name|
  tag = company.tags.find_or_create_by!(name: name)
  tags[name] = tag
end
puts "  Created #{tag_names.length} tags"

# ── Accounts ───────────────────────────────────────────────
puts "\n6. Creating accounts..."
accounts = {}

account_data = [
  { name: "21st Mortgage Corporation",   type: "lender",   website: "21stmortgage.com",       phone: "(865) 555-0100", city: "Knoxville",    state: "TN" },
  { name: "Vanderbilt Mortgage",         type: "lender",   website: "vmf.com",                phone: "(865) 555-0200", city: "Maryville",    state: "TN" },
  { name: "Cascade Financial Services",  type: "lender",   website: "cascadeloans.com",       phone: "(877) 555-0300", city: "Boise",        state: "ID" },
  { name: "Martin Family Properties",    type: "customer", website: nil,                      phone: "(260) 555-0400", city: "Auburn",       state: "IN" },
  { name: "Lakeside MH Community",       type: "customer", website: "lakesidemhc.com",        phone: "(260) 555-0500", city: "Angola",       state: "IN" },
  { name: "Hoosier Land Development",    type: "prospect", website: "hoosierland.com",        phone: "(317) 555-0600", city: "Indianapolis", state: "IN" },
  { name: "Champion Home Builders",      type: "vendor",   website: "championhomes.com",      phone: "(574) 555-0700", city: "Topeka",       state: "IN" },
  { name: "Redman Homes",                type: "vendor",   website: "redmanhomes.com",        phone: "(260) 555-0800", city: "Decatur",      state: "IN" },
]

account_data.each do |ad|
  acct = company.accounts.find_or_create_by!(name: ad[:name]) do |a|
    a.account_type = ad[:type]
    a.website = ad[:website]
    a.phone = ad[:phone]
    a.city = ad[:city]
    a.state = ad[:state]
    a.owner_id = users[:manager].id
    a.location_id = locations["AUB"].id
    a.is_deleted = false
  end
  accounts[ad[:name]] = acct
end
puts "  Created #{account_data.length} accounts"

# ── Contacts ───────────────────────────────────────────────
puts "\n7. Creating contacts..."
contacts = {}

contact_data = [
  # Lender contacts
  { first: "Robert",   last: "Chen",      email: "rchen@21stmortgage.com",    phone: "(865) 555-1001", account: "21st Mortgage Corporation",  title: "Loan Officer" },
  { first: "Amanda",   last: "White",     email: "awhite@21stmortgage.com",   phone: "(865) 555-1002", account: "21st Mortgage Corporation",  title: "Sr. Underwriter" },
  { first: "James",    last: "Patterson", email: "jpatterson@vmf.com",        phone: "(865) 555-1003", account: "Vanderbilt Mortgage",        title: "Account Manager" },
  { first: "Lisa",     last: "Nguyen",    email: "lnguyen@cascadeloans.com",  phone: "(877) 555-1004", account: "Cascade Financial Services", title: "Loan Processor" },
  # Customer contacts
  { first: "William",  last: "Martin",    email: "wmartin@gmail.com",         phone: "(260) 555-2001", account: "Martin Family Properties",   title: "Owner" },
  { first: "Carol",    last: "Martin",    email: "cmartin@gmail.com",         phone: "(260) 555-2002", account: "Martin Family Properties",   title: "Co-Owner" },
  { first: "Dennis",   last: "Hopper",    email: "dhopper@lakesidemhc.com",   phone: "(260) 555-2003", account: "Lakeside MH Community",      title: "Park Manager" },
  { first: "Rebecca",  last: "Stone",     email: "rstone@lakesidemhc.com",    phone: "(260) 555-2004", account: "Lakeside MH Community",      title: "Maintenance Dir." },
  # Prospect contacts
  { first: "Marcus",   last: "Johnson",   email: "mjohnson@hoosierland.com",  phone: "(317) 555-3001", account: "Hoosier Land Development",   title: "VP Development" },
  { first: "Patricia", last: "Adams",     email: "padams@hoosierland.com",    phone: "(317) 555-3002", account: "Hoosier Land Development",   title: "Project Manager" },
  # Unlinked contacts (individuals)
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

# ── Leads ──────────────────────────────────────────────────
puts "\n8. Creating leads..."
leads = {}

lead_data = [
  { first: "Steven",   last: "Baker",    email: "sbaker@gmail.com",      phone: "(260) 555-5001", status: "new",       source: "website",  location: "AUB" },
  { first: "Michelle", last: "Rivera",   email: "mrivera@yahoo.com",     phone: "(260) 555-5002", status: "new",       source: "walk-in",  location: "AUB" },
  { first: "Gregory",  last: "Ward",     email: "gward@outlook.com",     phone: "(317) 555-5003", status: "new",       source: "referral", location: "FTW" },
  { first: "Dorothy",  last: "Hughes",   email: "dhughes@gmail.com",     phone: "(574) 555-5004", status: "contacted", source: "facebook",  location: "AUB" },
  { first: "Larry",    last: "Coleman",  email: "lcoleman@hotmail.com",  phone: "(260) 555-5005", status: "contacted", source: "website",  location: "FTW" },
  { first: "Nancy",    last: "Reed",     email: "nreed@gmail.com",       phone: "(812) 555-5006", status: "contacted", source: "zillow",   location: "IND" },
  { first: "Kenneth",  last: "Stewart",  email: "kstewart@icloud.com",   phone: "(260) 555-5007", status: "qualified", source: "walk-in",  location: "AUB" },
  { first: "Betty",    last: "Sanchez",  email: "bsanchez@gmail.com",    phone: "(317) 555-5008", status: "qualified", source: "referral", location: "FTW" },
  { first: "Ronald",   last: "Morris",   email: "rmorris@yahoo.com",     phone: "(260) 555-5009", status: "qualified", source: "website",  location: "AUB" },
  { first: "Sharon",   last: "Bell",     email: "sbell22@gmail.com",     phone: "(574) 555-5010", status: "proposal",  source: "walk-in",  location: "FTW" },
  { first: "Frank",    last: "Wood",     email: "fwood@outlook.com",     phone: "(260) 555-5011", status: "proposal",  source: "facebook", location: "AUB" },
  { first: "Helen",    last: "Rogers",   email: "hrogers@gmail.com",     phone: "(317) 555-5012", status: "proposal",  source: "zillow",   location: "IND" },
  { first: "Arthur",   last: "Gray",     email: "agray@hotmail.com",     phone: "(260) 555-5013", status: "won",       source: "referral", location: "AUB" },
  { first: "Diane",    last: "Watson",   email: "dwatson@gmail.com",     phone: "(260) 555-5014", status: "won",       source: "walk-in",  location: "FTW" },
  { first: "Carl",     last: "Brooks",   email: "cbrooks@yahoo.com",     phone: "(812) 555-5015", status: "lost",      source: "website",  location: "AUB" },
]

lead_data.each do |ld|
  lead = company.leads.find_or_create_by!(email: ld[:email]) do |l|
    l.first_name = ld[:first]
    l.last_name = ld[:last]
    l.phone = ld[:phone]
    l.status = ld[:status]
    l.source = ld[:source]
    l.assigned_to_id = [users[:sales1], users[:sales2]].sample.id
    l.owner_id = users[:manager].id
    l.location_id = locations[ld[:location]].id
    l.is_deleted = false
  end
  leads["#{ld[:first]} #{ld[:last]}"] = lead
end
puts "  Created #{lead_data.length} leads"

# ── Vehicles (Inventory) ──────────────────────────────────
puts "\n9. Creating vehicles (inventory)..."
vehicles = {}

# S3 image URLs - shared from production S3 buckets
S3_STAGING = "https://renterinsight-website-assets-staging.s3.us-west-2.amazonaws.com"
S3_FDHC    = "https://factory-direct-homescenter.s3.us-east-1.amazonaws.com"

vehicle_data = [
  # Champion Homes - Topeka IN (with S3 images from Emerald Sky upload + floor plans)
  { year: 2026, make: "Champion",     model: "Aspire DAP1676H32222",        serial: "112-000-H-D-C412913A", beds: 3, baths: 2, sqft: 1155, price: 87489, status: "available",  location: "AUB",
    images: [
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-exterior.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-kitchen.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-living-room.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-master-bedroom.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/aspire-2025/aspire-1676h32222/jpgs/112-aspire-1676h32222-bathroom.jpg",
    ],
    floor_plan: "#{S3_FDHC}/floorplans/Dutch%20Aspire%201676H32222.png"
  },
  { year: 2026, make: "Champion",     model: "Emerald Sky 4483A",           serial: "112-000-H-A-C412920B", beds: 4, baths: 2, sqft: 1680, price: 124900, status: "available", location: "AUB",
    images: [
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-exterior.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-kitchen.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-living-room.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-master-bedroom.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-master-bath.jpg",
      "#{S3_STAGING}/floor-plans/champion/topeka-in/champion-homes/genesis/emerald-sky/jpgs/112-emerald-sky-bedroom-2.jpg",
    ],
    floor_plan: nil
  },
  { year: 2026, make: "Champion",     model: "Genesis 3276A",              serial: "112-000-H-A-C412925C", beds: 3, baths: 2, sqft: 1493, price: 98500, status: "available",  location: "FTW",
    images: [], floor_plan: nil },
  { year: 2025, make: "Champion",     model: "Momentum MMT2856A",          serial: "112-000-H-A-C412800D", beds: 3, baths: 2, sqft: 1344, price: 79900, status: "sold",       location: "AUB",
    images: [], floor_plan: "#{S3_FDHC}/floorplans/Silverton%202856H32174.png" },
  { year: 2026, make: "Champion",     model: "Heritage 1676H",             serial: "112-000-H-H-C412930E", beds: 2, baths: 1, sqft: 960,  price: 54900, status: "available",  location: "IND",
    images: [], floor_plan: "#{S3_FDHC}/floorplans/Dutch%20Aspire%201676H32221.png" },
  { year: 2026, make: "Champion",     model: "Aspire DAP2064H42222",       serial: "112-000-H-D-C412935F", beds: 4, baths: 2, sqft: 1984, price: 145000, status: "in_transit", location: "AUB",
    images: [], floor_plan: nil },
  # Redman Homes - Decatur IN
  { year: 2026, make: "Redman",       model: "RM2856A",                    serial: "RMN-2026-A-001234",    beds: 3, baths: 2, sqft: 1344, price: 82500, status: "available",  location: "AUB",
    images: [], floor_plan: nil },
  { year: 2026, make: "Redman",       model: "RM3264A",                    serial: "RMN-2026-A-001235",    beds: 3, baths: 2, sqft: 1536, price: 96700, status: "available",  location: "FTW",
    images: [], floor_plan: nil },
  { year: 2025, make: "Redman",       model: "RM1660A",                    serial: "RMN-2025-A-001100",    beds: 2, baths: 1, sqft: 960,  price: 49900, status: "available",  location: "AUB",
    images: [], floor_plan: nil },
  { year: 2026, make: "Redman",       model: "RM4068A",                    serial: "RMN-2026-A-001240",    beds: 4, baths: 2, sqft: 2040, price: 138000, status: "on_order",  location: "FTW",
    images: [], floor_plan: nil },
  { year: 2025, make: "Redman",       model: "RM2448A",                    serial: "RMN-2025-A-001150",    beds: 3, baths: 2, sqft: 1152, price: 68500, status: "sold",       location: "AUB",
    images: [], floor_plan: nil },
  # Dutch Housing
  { year: 2026, make: "Dutch Housing", model: "Dutch 2872A",               serial: "DH-2026-A-005001",     beds: 3, baths: 2, sqft: 1536, price: 105000, status: "available", location: "AUB",
    images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 3268A",               serial: "DH-2026-A-005002",     beds: 3, baths: 2, sqft: 1632, price: 118500, status: "available", location: "FTW",
    images: [], floor_plan: nil },
  { year: 2026, make: "Dutch Housing", model: "Dutch 1676S",               serial: "DH-2026-S-005003",     beds: 2, baths: 1, sqft: 1056, price: 62000, status: "available",  location: "IND",
    images: [], floor_plan: nil },
  { year: 2025, make: "Dutch Housing", model: "Dutch 2460A",               serial: "DH-2025-A-004990",     beds: 3, baths: 2, sqft: 1200, price: 74900, status: "sold",       location: "AUB",
    images: [], floor_plan: nil },
  # Used / Trade-ins (no S3 images)
  { year: 2019, make: "Clayton",      model: "TRU The Satisfaction",        serial: "CLT-2019-T-889900",    beds: 3, baths: 2, sqft: 1120, price: 35000, status: "available",  location: "AUB",
    images: [], floor_plan: nil },
  { year: 2021, make: "Skyline",      model: "Amber Cove 266CT",           serial: "SKY-2021-A-776600",    beds: 3, baths: 2, sqft: 1216, price: 42500, status: "available",  location: "FTW",
    images: [], floor_plan: nil },
  { year: 2017, make: "Fleetwood",    model: "Berkshire 3252B",            serial: "FLT-2017-B-554400",    beds: 4, baths: 2, sqft: 1664, price: 38000, status: "available",  location: "AUB",
    images: [], floor_plan: nil },
]

vehicle_data.each do |vd|
  vehicle = company.vehicles.find_or_create_by!(vin: vd[:serial]) do |v|
    v.year = vd[:year]
    v.make = vd[:make]
    v.model = vd[:model]
    v.stock_number = "STK-#{rand(10000..99999)}"
    v.status = vd[:status]
    v.location_id = locations[vd[:location]].id
    v.is_deleted = false
    # Set price fields if they exist on your model
    v.retail_price = vd[:price] if v.respond_to?(:retail_price=)
    v.list_price = vd[:price] if v.respond_to?(:list_price=)
    v.price = vd[:price] if v.respond_to?(:price=)
    # MH-specific fields if they exist
    v.bedrooms = vd[:beds] if v.respond_to?(:bedrooms=)
    v.bathrooms = vd[:baths] if v.respond_to?(:bathrooms=)
    v.square_feet = vd[:sqft] if v.respond_to?(:square_feet=)
    v.new_used = vd[:year] >= 2025 ? "New" : "Used" if v.respond_to?(:new_used=)
    # S3 images (shared from production bucket)
    if vd[:images].present?
      v.images = vd[:images].map { |url| { 'url' => url } } if v.respond_to?(:images=)
      v.photo_url = vd[:images].first if v.respond_to?(:photo_url=)
    end
    if vd[:floor_plan].present?
      v.floor_plan_images = [{ 'url' => vd[:floor_plan] }] if v.respond_to?(:floor_plan_images=)
      # Use floor plan as primary photo if no room photos
      if vd[:images].blank?
        v.photo_url = vd[:floor_plan] if v.respond_to?(:photo_url=)
        v.images = [{ 'url' => vd[:floor_plan] }] if v.respond_to?(:images=)
      end
    end
  end
  vehicles[vd[:serial]] = vehicle
end
images_count = vehicle_data.count { |v| v[:images].present? }
fp_count = vehicle_data.count { |v| v[:floor_plan].present? }
puts "  Created #{vehicle_data.length} vehicles (#{images_count} with photos, #{fp_count} with floor plans)"

# ── Deals ──────────────────────────────────────────────────
puts "\n10. Creating deals..."
deals = {}

deal_data = [
  { title: "Smuts - Champion Aspire",      stage: "won",           amount: 114235, contact: "Jeretta Smuts",     account: nil,                       vehicle_serial: "112-000-H-D-C412913A" },
  { title: "Martin - Emerald Sky 4483",    stage: "negotiation",   amount: 124900, contact: "William Martin",    account: "Martin Family Properties", vehicle_serial: "112-000-H-A-C412920B" },
  { title: "O'Brien - Redman RM2856A",     stage: "proposal",      amount: 89500,  contact: "Kevin O'Brien",     account: nil,                       vehicle_serial: "RMN-2026-A-001234" },
  { title: "Lakeside - Dutch 2872A",       stage: "proposal",      amount: 105000, contact: "Dennis Hopper",     account: "Lakeside MH Community",   vehicle_serial: "DH-2026-A-005001" },
  { title: "Gonzalez - Heritage 1676H",    stage: "qualification", amount: 62900,  contact: "Maria Gonzalez",    account: nil,                       vehicle_serial: "112-000-H-H-C412930E" },
  { title: "Crawford - Redman RM3264A",    stage: "qualification", amount: 96700,  contact: "Daniel Crawford",   account: nil,                       vehicle_serial: "RMN-2026-A-001235" },
  { title: "Fisher - Dutch 1676S",         stage: "discovery",     amount: 62000,  contact: "Tammy Fisher",      account: nil,                       vehicle_serial: "DH-2026-S-005003" },
  { title: "Hoosier Dev - Bulk Order",     stage: "discovery",     amount: 450000, contact: "Marcus Johnson",    account: "Hoosier Land Development", vehicle_serial: nil },
  { title: "Keller - Used Clayton",        stage: "won",           amount: 38500,  contact: "Brian Keller",      account: nil,                       vehicle_serial: "CLT-2019-T-889900" },
  { title: "Turner - Skyline Amber Cove",  stage: "lost",          amount: 42500,  contact: "Jason Turner",      account: nil,                       vehicle_serial: "SKY-2021-A-776600" },
]

deal_data.each do |dd|
  contact = contacts[dd[:contact]]
  account = dd[:account] ? accounts[dd[:account]] : nil

  deal = company.deals.find_or_create_by!(title: dd[:title]) do |d|
    d.stage = dd[:stage]
    d.contact_id = contact&.id
    d.account_id = account&.id
    d.assigned_to_id = [users[:sales1], users[:sales2]].sample.id
    d.location_id = [locations["AUB"], locations["FTW"]].sample.id
    d.is_deleted = false
    d.amount = dd[:amount] if d.respond_to?(:amount=)
    d.amount_cents = dd[:amount] * 100 if d.respond_to?(:amount_cents=)
    d.value = dd[:amount] if d.respond_to?(:value=)
  end
  deals[dd[:title]] = deal
end
puts "  Created #{deal_data.length} deals"

# ── Quotes ─────────────────────────────────────────────────
puts "\n11. Creating quotes..."
quote_data = [
  { number: "Q-2026-001", status: "accepted", subtotal: 88350,  tax: 4971, total: 114235, contact: "Jeretta Smuts",   notes: "Champion Aspire DAP1676H32222 with upgrades" },
  { number: "Q-2026-002", status: "sent",     subtotal: 124900, tax: 7494, total: 137394, contact: "William Martin",  notes: "Emerald Sky 4483A - negotiating freight" },
  { number: "Q-2026-003", status: "draft",    subtotal: 82500,  tax: 4950, total: 91950,  contact: "Kevin O'Brien",   notes: "Redman RM2856A, standard freight" },
  { number: "Q-2026-004", status: "sent",     subtotal: 105000, tax: 6300, total: 116300, contact: "Dennis Hopper",   notes: "Dutch 2872A for Lakeside community" },
  { number: "Q-2026-005", status: "expired",  subtotal: 42500,  tax: 2550, total: 47550,  contact: "Jason Turner",    notes: "Skyline Amber Cove - expired 2/28" },
]

quote_data.each do |qd|
  contact = contacts[qd[:contact]]
  company.quotes.find_or_create_by!(quote_number: qd[:number]) do |q|
    q.status = qd[:status]
    q.contact_id = contact&.id
    q.account_id = contact&.account_id
    q.subtotal = qd[:subtotal] if q.respond_to?(:subtotal=)
    q.tax = qd[:tax] if q.respond_to?(:tax=)
    q.total = qd[:total] if q.respond_to?(:total=)
    q.notes = qd[:notes]
    q.created_by_id = users[:sales1].id
    q.location_id = locations["AUB"].id
    q.is_deleted = false
  end
end
puts "  Created #{quote_data.length} quotes"

# ── Invoices ───────────────────────────────────────────────
puts "\n12. Creating invoices..."
invoice_data = [
  { number: "INV-2026-001", status: "paid",    amount: 6400,   contact: "Jeretta Smuts",   desc: "Down payment - Champion Aspire" },
  { number: "INV-2026-002", status: "paid",    amount: 107835, contact: "Jeretta Smuts",   desc: "Balance due - Champion Aspire (via 21st Mortgage)" },
  { number: "INV-2026-003", status: "pending", amount: 12490,  contact: "William Martin",  desc: "10% deposit - Emerald Sky 4483A" },
  { number: "INV-2026-004", status: "pending", amount: 8250,   contact: "Kevin O'Brien",   desc: "Deposit - Redman RM2856A" },
  { number: "INV-2026-005", status: "paid",    amount: 38500,  contact: "Brian Keller",    desc: "Full payment - Used Clayton (cash)" },
  { number: "INV-2026-006", status: "overdue", amount: 10500,  contact: "Dennis Hopper",   desc: "Deposit - Dutch 2872A for Lakeside" },
  { number: "INV-2025-047", status: "paid",    amount: 68500,  contact: "Raymond Price",   desc: "Redman RM2448A - financed via Vanderbilt" },
  { number: "INV-2025-048", status: "paid",    amount: 74900,  contact: "Angela Brooks",   desc: "Dutch 2460A - financed via Cascade" },
]

invoice_data.each do |id_data|
  contact = contacts[id_data[:contact]]
  company.invoices.find_or_create_by!(invoice_number: id_data[:number]) do |inv|
    inv.status = id_data[:status]
    inv.contact_id = contact&.id
    inv.account_id = contact&.account_id
    inv.total = id_data[:amount] if inv.respond_to?(:total=)
    inv.amount = id_data[:amount] if inv.respond_to?(:amount=)
    inv.notes = id_data[:desc]
    inv.description = id_data[:desc] if inv.respond_to?(:description=)
    inv.created_by_id = users[:manager].id
    inv.location_id = locations["AUB"].id
    inv.is_deleted = false
    inv.due_date = id_data[:status] == 'overdue' ? 15.days.ago : 30.days.from_now if inv.respond_to?(:due_date=)
  end
end
puts "  Created #{invoice_data.length} invoices"

# ── Service Tickets ────────────────────────────────────────
puts "\n13. Creating service tickets..."
ticket_data = [
  { title: "Door alignment after delivery",        status: "open",        priority: "high",   contact: "Jeretta Smuts",  type: "warranty" },
  { title: "HVAC not heating properly",             status: "in_progress", priority: "high",   contact: "Brian Keller",   type: "warranty" },
  { title: "Kitchen faucet leak",                   status: "open",        priority: "medium", contact: "Angela Brooks",  type: "warranty" },
  { title: "Carpet seam separation - master bedroom",status: "open",       priority: "medium", contact: "Raymond Price",  type: "warranty" },
  { title: "Skirting installation",                 status: "scheduled",   priority: "low",    contact: "Jeretta Smuts",  type: "service" },
  { title: "Pre-delivery inspection - Emerald Sky", status: "open",        priority: "high",   contact: "William Martin", type: "inspection" },
  { title: "Window crank replacement",              status: "completed",   priority: "low",    contact: "Sandra Mitchell",type: "repair" },
  { title: "Smoke detector installation",           status: "completed",   priority: "medium", contact: "Brian Keller",   type: "service" },
  { title: "Marriage line drywall crack",            status: "in_progress", priority: "medium", contact: "Angela Brooks",  type: "warranty" },
  { title: "Electrical outlet not working - kitchen",status: "open",       priority: "high",   contact: "Raymond Price",  type: "warranty" },
]

ticket_data.each_with_index do |td, idx|
  contact = contacts[td[:contact]]
  company.service_tickets.find_or_create_by!(title: td[:title]) do |st|
    st.status = td[:status]
    st.priority = td[:priority]
    st.contact_id = contact&.id
    st.account_id = contact&.account_id
    st.assigned_to_id = users[:tech].id
    st.created_by_id = users[:manager].id
    st.location_id = locations["AUB"].id
    st.ticket_number = "ST-2026-#{(idx + 1).to_s.rjust(3, '0')}" if st.respond_to?(:ticket_number=)
    st.ticket_type = td[:type] if st.respond_to?(:ticket_type=)
    st.service_type = td[:type] if st.respond_to?(:service_type=)
    st.is_deleted = false
    st.description = td[:title] if st.respond_to?(:description=)
  end
end
puts "  Created #{ticket_data.length} service tickets"

# ── Suppliers ──────────────────────────────────────────────
puts "\n14. Creating suppliers..."
suppliers = {}

supplier_data = [
  { name: "Midwest MH Parts Supply",  contact: "Tom Brennan",  email: "tbrennan@midwestmhparts.com",  phone: "(260) 555-6001" },
  { name: "Indiana Skirting & Supply", contact: "Paula Davis",  email: "pdavis@inskirting.com",         phone: "(574) 555-6002" },
  { name: "Hoosier HVAC Distribution", contact: "Mark Wilson", email: "mwilson@hoosierhvac.com",       phone: "(317) 555-6003" },
]

supplier_data.each do |sd|
  supplier = company.suppliers.find_or_create_by!(name: sd[:name]) do |s|
    s.contact_name = sd[:contact] if s.respond_to?(:contact_name=)
    s.email = sd[:email]
    s.phone = sd[:phone]
    s.is_active = true if s.respond_to?(:is_active=)
    s.is_deleted = false if s.respond_to?(:is_deleted=)
    s.location_id = locations["AUB"].id
  end
  suppliers[sd[:name]] = supplier
end
puts "  Created #{supplier_data.length} suppliers"

# ── Parts ──────────────────────────────────────────────────
puts "\n15. Creating parts..."
parts_data = [
  { name: "Door Hinge - Exterior",           sku: "PT-DH-001",  manufacturer: "Champion", qty: 24, cost: 8.50,   price: 15.00 },
  { name: "Window Crank Assembly",           sku: "PT-WC-002",  manufacturer: "Kinro",    qty: 12, cost: 22.00,  price: 45.00 },
  { name: "Vinyl Skirting Panel (4x8)",      sku: "PT-VS-003",  manufacturer: "Duraskirt", qty: 50, cost: 18.00, price: 35.00 },
  { name: "HVAC Filter 16x20x1",            sku: "PT-HF-004",  manufacturer: "Honeywell", qty: 30, cost: 4.50,  price: 12.00 },
  { name: "Faucet Assembly - Kitchen",       sku: "PT-FA-005",  manufacturer: "Moen",     qty: 8,  cost: 45.00,  price: 89.00 },
  { name: "Smoke Detector Battery",         sku: "PT-SD-006",  manufacturer: "Kidde",    qty: 40, cost: 3.00,   price: 8.00 },
  { name: "Carpet Seam Tape (25ft roll)",    sku: "PT-CT-007",  manufacturer: "Roberts",  qty: 15, cost: 12.00,  price: 24.00 },
  { name: "Drywall Compound (5 gal)",       sku: "PT-DC-008",  manufacturer: "USG",      qty: 6,  cost: 18.00,  price: 32.00 },
  { name: "Marriage Line Trim Kit",          sku: "PT-ML-009",  manufacturer: "Champion", qty: 10, cost: 35.00,  price: 65.00 },
  { name: "Anchor Strap Kit",               sku: "PT-AS-010",  manufacturer: "Tie Down",  qty: 20, cost: 28.00, price: 55.00 },
  { name: "Electrical Outlet - Standard",   sku: "PT-EO-011",  manufacturer: "Leviton",  qty: 25, cost: 2.50,   price: 8.00 },
  { name: "Lever Door Handle Set",          sku: "PT-LH-012",  manufacturer: "Kwikset",  qty: 15, cost: 18.00,  price: 35.00 },
  { name: "Ceiling Fan w/ Light Kit",       sku: "PT-CF-013",  manufacturer: "Hampton Bay",qty: 8, cost: 55.00, price: 110.00 },
  { name: "Vinyl Plank Flooring (case)",    sku: "PT-VF-014",  manufacturer: "Shaw",     qty: 20, cost: 32.00,  price: 65.00 },
  { name: "Cabinet Handle - Black",         sku: "PT-CH-015",  manufacturer: "Amerock",  qty: 50, cost: 3.50,   price: 8.00 },
]

parts_data.each do |pd|
  company.parts.find_or_create_by!(sku: pd[:sku]) do |p|
    p.name = pd[:name]
    p.manufacturer_name = pd[:manufacturer] if p.respond_to?(:manufacturer_name=)
    p.quantity = pd[:qty] if p.respond_to?(:quantity=)
    p.quantity_on_hand = pd[:qty] if p.respond_to?(:quantity_on_hand=)
    p.default_cost = pd[:cost] if p.respond_to?(:default_cost=)
    p.cost = pd[:cost] if p.respond_to?(:cost=)
    p.retail_price = pd[:price] if p.respond_to?(:retail_price=)
    p.price = pd[:price] if p.respond_to?(:price=)
    p.location_id = locations["AUB"].id
    p.is_deleted = false
  end
end
puts "  Created #{parts_data.length} parts"

# ── Seed Resources (RBAC) ─────────────────────────────────
puts "\n16. Seeding RBAC resources..."
if defined?(Resource) && Resource.respond_to?(:seed_defaults)
  Resource.seed_defaults
  puts "  Resources seeded"
else
  puts "  Skipped (Resource model not found)"
end

# ── Project Template ───────────────────────────────────────
puts "\n17. Creating project template..."
if company.respond_to?(:project_templates)
  template = company.project_templates.find_or_create_by!(name: "Standard Home Setup") do |t|
    t.description = "Standard manufactured home purchase, delivery, and setup process"
    t.is_active = true
  end

  # Define template phases (the 17-step standard process)
  template_phases = [
    { name: "Contract Signed",           position: 1,  estimated_days: 0,  color: "#3B82F6", icon: "file-signature" },
    { name: "Financing Approved",        position: 2,  estimated_days: 7,  color: "#3B82F6", icon: "bank" },
    { name: "Down Payment Received",     position: 3,  estimated_days: 3,  color: "#10B981", icon: "dollar-sign" },
    { name: "Order Placed w/ Factory",   position: 4,  estimated_days: 2,  color: "#F59E0B", icon: "factory" },
    { name: "In Production",            position: 5,  estimated_days: 30, color: "#F59E0B", icon: "hard-hat" },
    { name: "Quality Inspection",        position: 6,  estimated_days: 3,  color: "#F59E0B", icon: "clipboard-check" },
    { name: "Ready for Transport",       position: 7,  estimated_days: 2,  color: "#8B5CF6", icon: "truck" },
    { name: "Site Preparation",          position: 8,  estimated_days: 14, color: "#8B5CF6", icon: "shovel" },
    { name: "Permits Obtained",          position: 9,  estimated_days: 10, color: "#8B5CF6", icon: "file-check" },
    { name: "Home Delivered",            position: 10, estimated_days: 1,  color: "#EC4899", icon: "truck-delivery" },
    { name: "Foundation & Set",          position: 11, estimated_days: 5,  color: "#EC4899", icon: "building" },
    { name: "Utility Connections",       position: 12, estimated_days: 7,  color: "#EC4899", icon: "plug" },
    { name: "Skirting & Exterior",       position: 13, estimated_days: 5,  color: "#6366F1", icon: "home" },
    { name: "Interior Finish & Trim",    position: 14, estimated_days: 5,  color: "#6366F1", icon: "paint-roller" },
    { name: "Final Inspection",          position: 15, estimated_days: 2,  color: "#14B8A6", icon: "search" },
    { name: "Walkthrough w/ Buyer",      position: 16, estimated_days: 1,  color: "#14B8A6", icon: "users" },
    { name: "Closing & Handoff",         position: 17, estimated_days: 1,  color: "#10B981", icon: "key" },
  ]

  template_phases.each do |tp|
    if template.respond_to?(:project_template_phases)
      template.project_template_phases.find_or_create_by!(name: tp[:name]) do |p|
        p.position = tp[:position]
        p.estimated_days = tp[:estimated_days]
        p.color = tp[:color] if p.respond_to?(:color=)
        p.icon = tp[:icon] if p.respond_to?(:icon=)
      end
    end
  end
  puts "  Template: #{template.name} (#{template_phases.length} phases)"

  # ── Projects for Won Deals ────────────────────────────────
  puts "\n18. Creating projects for won deals..."

  project_data = [
    {
      deal_title: "Smuts - Champion Aspire",
      name: "Smuts - Champion Aspire DAP1676H32222",
      status: "in_progress",
      # Smuts is mid-process: contract through site prep done, permits in progress
      phases_complete: 8,   # Phases 1-8 completed
      current_phase: 9,     # "Permits Obtained" - in_progress
    },
    {
      deal_title: "Keller - Used Clayton",
      name: "Keller - Used Clayton Satisfaction",
      status: "completed",
      # Keller bought used, everything done
      phases_complete: 17,  # All completed
      current_phase: nil,
    },
    {
      deal_title: "Martin - Emerald Sky 4483",
      # Martin is in negotiation stage (not won), but let's show a project being prepared
      # Actually this deal is still in negotiation, skip it
      skip: true,
    },
  ]

  project_data.each do |pd|
    next if pd[:skip]

    deal = deals[pd[:deal_title]]
    next unless deal

    project_number = "PRJ-#{deal.id.to_s.rjust(4, '0')}"
    project = company.projects.find_or_create_by!(name: pd[:name]) do |p|
      p.deal_id = deal.id if p.respond_to?(:deal_id=)
      p.project_template_id = template.id if p.respond_to?(:project_template_id=)
      p.location_id = deal.location_id
      p.status = pd[:status]
      p.project_number = project_number if p.respond_to?(:project_number=)
      p.customer_name = deal.respond_to?(:contact) && deal.contact ? "#{deal.contact.first_name} #{deal.contact.last_name}" : deal.title
      p.home_description = deal.title if p.respond_to?(:home_description=)
      p.phase_count = template_phases.length if p.respond_to?(:phase_count=)
      p.completed_phase_count = pd[:phases_complete] if p.respond_to?(:completed_phase_count=)
      p.progress_percent = ((pd[:phases_complete].to_f / template_phases.length) * 100).round if p.respond_to?(:progress_percent=)
      p.started_at = 45.days.ago if p.respond_to?(:started_at=)
      p.completed_at = 5.days.ago if pd[:status] == 'completed' && p.respond_to?(:completed_at=)
      p.client_access_token = SecureRandom.hex(16) if p.respond_to?(:client_access_token=)
      p.is_deleted = false
    end

    # Create project phases
    if project.respond_to?(:project_phases)
      template_phases.each do |tp|
        phase_status = if tp[:position] <= pd[:phases_complete]
                         'completed'
                       elsif pd[:current_phase] && tp[:position] == pd[:current_phase]
                         'in_progress'
                       else
                         'not_started'
                       end

        # Calculate realistic dates based on position
        days_offset = template_phases[0...(tp[:position] - 1)].sum { |p| p[:estimated_days] }
        started_date = project.started_at + days_offset.days if phase_status != 'not_started'
        completed_date = started_date + tp[:estimated_days].days if phase_status == 'completed' && started_date

        project.project_phases.find_or_create_by!(name: tp[:name]) do |ph|
          ph.company_id = company.id if ph.respond_to?(:company_id=)
          ph.position = tp[:position]
          ph.status = phase_status
          ph.color = tp[:color] if ph.respond_to?(:color=)
          ph.icon = tp[:icon] if ph.respond_to?(:icon=)
          ph.estimated_days = tp[:estimated_days] if ph.respond_to?(:estimated_days=)
          ph.started_at = started_date if ph.respond_to?(:started_at=) && started_date
          ph.completed_at = completed_date if ph.respond_to?(:completed_at=) && completed_date
        end
      end

      # Set current_phase_id
      current = project.project_phases.find_by(status: 'in_progress')
      project.update_column(:current_phase_id, current&.id) if project.respond_to?(:current_phase_id) && current
      current_name = current&.name || (pd[:status] == 'completed' ? 'Completed' : 'Not Started')
      project.update_column(:current_phase_name, current_name) if project.respond_to?(:current_phase_name)
    end

    puts "  Project: #{project.name} (#{pd[:status]}, #{pd[:phases_complete]}/#{template_phases.length} phases)"
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
puts ""
puts "Login Credentials (Password: #{DEMO_PASSWORD})"
puts "-" * 50
users.each do |key, user|
  printf "  %-12s %-35s %s\n", key.to_s, user.email, user.role
end
puts ""
puts "Data Summary:"
puts "-" * 50
{
  "Locations" => company.respond_to?(:locations) ? company.locations.count : 0,
  "Users" => company.users.count,
  "Vehicles" => company.respond_to?(:vehicles) ? company.vehicles.count : 0,
  "Leads" => company.respond_to?(:leads) ? company.leads.count : 0,
  "Accounts" => company.respond_to?(:accounts) ? company.accounts.count : 0,
  "Contacts" => company.respond_to?(:contacts) ? company.contacts.count : 0,
  "Deals" => company.respond_to?(:deals) ? company.deals.count : 0,
  "Quotes" => company.respond_to?(:quotes) ? company.quotes.count : 0,
  "Invoices" => company.respond_to?(:invoices) ? company.invoices.count : 0,
  "Service Tickets" => company.respond_to?(:service_tickets) ? company.service_tickets.count : 0,
  "Projects" => company.respond_to?(:projects) ? company.projects.count : 0,
  "Parts" => company.respond_to?(:parts) ? company.parts.count : 0,
  "Suppliers" => company.respond_to?(:suppliers) ? company.suppliers.count : 0,
  "Tags" => company.respond_to?(:tags) ? company.tags.count : 0,
}.each do |label, count|
  printf "  %-20s %d\n", label, count
end
puts ""
puts "To reset and re-seed:"
puts "  RESET=true bin/rails runner \"load 'db/seeds/demo_company.rb'\""
puts "=" * 60
