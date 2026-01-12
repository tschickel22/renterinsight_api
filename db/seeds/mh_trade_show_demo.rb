# frozen_string_literal: true

puts "🏭 Creating Summit Park MH Dealership Demo Data..."

# ============================================================
# 1. CREATE DEMO COMPANY
# ============================================================
company = Company.find_or_create_by!(name: 'Summit Park Manufactured Homes') do |c|
  c.is_demo = true
  c.external_payments_id = '99999999' # Bypass Zego for demo
  c.status = 'active'
end

puts "   ✅ Company: #{company.name}"

# ============================================================
# 2. CREATE LOCATIONS
# ============================================================
denver_showroom = company.locations.find_or_create_by!(name: 'Denver Showroom') do |loc|
  loc.address_line1 = '4500 E. Kennedy Ave'
  loc.city = 'Denver'
  loc.state = 'CO'
  loc.zip_code = '80246'
  loc.phone = '303-570-9810'
  loc.email = 't+denver@renterinsight.com'
  loc.active = true
end

aurora_sales = company.locations.find_or_create_by!(name: 'Aurora Sales Center') do |loc|
  loc.address_line1 = '15200 E. Alameda Ave'
  loc.city = 'Aurora'
  loc.state = 'CO'
  loc.zip_code = '80012'
  loc.phone = '303-570-9811'
  loc.email = 't+aurora@renterinsight.com'
  loc.active = true
end

service_dept = company.locations.find_or_create_by!(name: 'Service & Parts Department') do |loc|
  loc.address_line1 = '4500 E. Kennedy Ave, Unit B'
  loc.city = 'Denver'
  loc.state = 'CO'
  loc.zip_code = '80246'
  loc.phone = '303-570-9812'
  loc.email = 't+service@renterinsight.com'
  loc.active = true
end

puts "   ✅ Created 3 locations"

# ============================================================
# 3. CREATE USERS (Dealership Staff)
# ============================================================
users = []

# Sales Manager
users << company.users.find_or_create_by!(email: 't+sarah.martinez@renterinsight.com') do |u|
  u.first_name = 'Sarah'
  u.last_name = 'Martinez'
  u.password = 'demo123'
  u.password_confirmation = 'demo123'
  u.role = 'admin'
  u.title = 'Sales Manager'
  u.department = 'Sales'
  u.phone = '303-555-0101'
  u.status = 'active'
end

# Sales Consultants
users << company.users.find_or_create_by!(email: 't+mike.chen@renterinsight.com') do |u|
  u.first_name = 'Mike'
  u.last_name = 'Chen'
  u.password = 'demo123'
  u.password_confirmation = 'demo123'
  u.role = 'staff'
  u.title = 'Senior Sales Consultant'
  u.department = 'Sales'
  u.phone = '303-555-0102'
  u.status = 'active'
end

users << company.users.find_or_create_by!(email: 't+jessica.brown@renterinsight.com') do |u|
  u.first_name = 'Jessica'
  u.last_name = 'Brown'
  u.password = 'demo123'
  u.password_confirmation = 'demo123'
  u.role = 'staff'
  u.title = 'Sales Consultant'
  u.department = 'Sales'
  u.phone = '303-555-0103'
  u.status = 'active'
end

# Service Manager
users << company.users.find_or_create_by!(email: 't+david.wilson@renterinsight.com') do |u|
  u.first_name = 'David'
  u.last_name = 'Wilson'
  u.password = 'demo123'
  u.password_confirmation = 'demo123'
  u.role = 'staff'
  u.title = 'Service Manager'
  u.department = 'Service'
  u.phone = '303-555-0104'
  u.status = 'active'
end

# Finance Manager
users << company.users.find_or_create_by!(email: 't+amanda.garcia@renterinsight.com') do |u|
  u.first_name = 'Amanda'
  u.last_name = 'Garcia'
  u.password = 'demo123'
  u.password_confirmation = 'demo123'
  u.role = 'staff'
  u.title = 'Finance Manager'
  u.department = 'Finance'
  u.phone = '303-555-0105'
  u.status = 'active'
end

puts "   ✅ Created #{users.count} users (all password: demo123)"

# ============================================================
# 4. CREATE MANUFACTURED HOME INVENTORY
# ============================================================
makes = ['Skyline', 'Clayton', 'Champion', 'Fleetwood', 'Palm Harbor', 'Cavco']
models_single = ['Aspire', 'Summit', 'Ridge', 'Peak', 'Vista', 'Crest']
models_double = ['Cascade', 'Brookstone', 'Pinehurst', 'Oakridge', 'Willowbrook']
models_triple = ['Grand Manor', 'Estate Series', 'Presidential']

home_features = [
  'Energy Star Certified',
  'Vaulted Ceilings',
  'Walk-in Closets',
  'Master Suite',
  'Modern Kitchen',
  'Open Floor Plan',
  'Covered Patio',
  'Garden Tub',
  'Island Kitchen',
  'Premium Flooring'
]

# Helper to get Unsplash image
def mh_image_url(seed_num)
  "https://picsum.photos/seed/#{seed_num}"
end

homes_created = 0

# Single-wide homes (10)
10.times do |i|
  make = makes.sample
  model = models_single.sample
  year = [2023, 2024].sample
  
  home = company.vehicles.find_or_create_by!(
    inventory_id: "MH-SW-#{1000 + i}"
  ) do |v|
    v.serial_number = "SN-SW-#{year}-#{rand(100000..999999)}"
    v.location_id = [denver_showroom.id, aurora_sales.id].sample
    v.listing_type = 'manufactured_home'
    v.year = year
    v.make = make
    v.model = model
    v.condition = year == 2024 ? 'new' : 'used'
    v.status = 'available'
    v.home_type = 'single_wide'
    v.bedrooms = [2, 3].sample
    v.bathrooms = [1, 1.5, 2].sample
    v.square_feet = rand(600..900)
    v.width = 16
    v.length = rand(50..70)
    v.sale_price = rand(45000..75000)
    v.dealer_cost = v.sale_price * 0.70
    v.target_gross = v.sale_price * 0.15
    v.description = "Beautiful #{year} #{make} #{model} single-wide manufactured home. Perfect starter home!"
    v.features = home_features.sample(5)
    v.images = [mh_image_url("sw#{i}")]
    v.date_in_stock = rand(30..180).days.ago
  end
  homes_created += 1
end

# Double-wide homes (15)
15.times do |i|
  make = makes.sample
  model = models_double.sample
  year = [2023, 2024].sample
  
  home = company.vehicles.find_or_create_by!(
    inventory_id: "MH-DW-#{2000 + i}"
  ) do |v|
    v.serial_number = "SN-DW-#{year}-#{rand(100000..999999)}"
    v.location_id = [denver_showroom.id, aurora_sales.id].sample
    v.listing_type = 'manufactured_home'
    v.year = year
    v.make = make
    v.model = model
    v.condition = year == 2024 ? 'new' : 'used'
    v.status = 'available'
    v.home_type = 'double_wide'
    v.bedrooms = [3, 4].sample
    v.bathrooms = [2, 2.5, 3].sample
    v.square_feet = rand(1200..1800)
    v.width = 28
    v.length = rand(48..76)
    v.sale_price = rand(85000..145000)
    v.dealer_cost = v.sale_price * 0.72
    v.target_gross = v.sale_price * 0.18
    v.description = "Spacious #{year} #{make} #{model} double-wide. Quality construction with modern amenities."
    v.features = home_features.sample(7)
    v.images = [mh_image_url("dw#{i}")]
    v.date_in_stock = rand(15..120).days.ago
    v.fireplace = [true, false].sample
    v.central_air = true
    v.deck = [true, false].sample
  end
  homes_created += 1
end

# Triple-wide homes (5)
5.times do |i|
  make = makes.sample
  model = models_triple.sample
  
  home = company.vehicles.find_or_create_by!(
    inventory_id: "MH-TW-#{3000 + i}"
  ) do |v|
    v.serial_number = "SN-TW-2024-#{rand(100000..999999)}"
    v.location_id = denver_showroom.id
    v.listing_type = 'manufactured_home'
    v.year = 2024
    v.make = make
    v.model = model
    v.condition = 'new'
    v.status = 'available'
    v.home_type = 'triple_wide'
    v.bedrooms = [4, 5].sample
    v.bathrooms = [3, 3.5].sample
    v.square_feet = rand(2000..2800)
    v.width = 42
    v.length = rand(60..76)
    v.sale_price = rand(150000..250000)
    v.dealer_cost = v.sale_price * 0.75
    v.target_gross = v.sale_price * 0.20
    v.description = "Luxury 2024 #{make} #{model} triple-wide. Premium finishes throughout!"
    v.features = home_features
    v.images = [mh_image_url("tw#{i}")]
    v.date_in_stock = rand(5..60).days.ago
    v.fireplace = true
    v.central_air = true
    v.deck = true
    v.garage = [true, false].sample
  end
  homes_created += 1
end

puts "   ✅ Created #{homes_created} manufactured homes"

# ============================================================
# 5. CREATE RV INVENTORY (5 units)
# ============================================================
rv_makes = ['Thor', 'Forest River', 'Jayco', 'Winnebago', 'Grand Design']
rv_models = ['Chateau', 'Hemisphere', 'Jay Flight', 'Vista', 'Reflection']

# Helper for RV images
def rv_image_url(seed_num)
  "https://source.unsplash.com/800x600/?rv,motorhome&sig=#{seed_num}"
end

rvs_created = 0

5.times do |i|
  make = rv_makes.sample
  model = rv_models.sample
  year = [2022, 2023, 2024].sample
  
  rv = company.vehicles.find_or_create_by!(
    inventory_id: "RV-#{4000 + i}"
  ) do |v|
    v.vin = "1RV#{year}#{i}ABC#{rand(100000..999999)}"
    v.location_id = denver_showroom.id
    v.listing_type = 'rv'
    v.year = year
    v.make = make
    v.model = model
    v.condition = year == 2024 ? 'new' : 'used'
    v.status = 'available'
    v.rv_class = ['Class A', 'Class C', 'Travel Trailer'].sample
    v.mileage = year < 2024 ? rand(5000..25000) : 0
    v.sleeping_capacity = rand(4..8)
    v.slideouts = rand(1..3)
    v.length = rand(25..35)
    v.sale_price = rand(75000..185000)
    v.dealer_cost = v.sale_price * 0.70
    v.target_gross = v.sale_price * 0.15
    v.description = "#{year} #{make} #{model}. Great for family adventures!"
    v.features = ['Full Kitchen', 'Queen Bed', 'Bathroom', 'A/C', 'Awning'].sample(4)
    v.images = [rv_image_url("rv#{i}")]
    v.date_in_stock = rand(10..90).days.ago
  end
  rvs_created += 1
end

puts "   ✅ Created #{rvs_created} RVs"

# ============================================================
# 6. CREATE LEADS (Potential Buyers)
# ============================================================
first_names = ['John', 'Mary', 'Robert', 'Jennifer', 'Michael', 'Linda', 'David', 'Patricia', 
               'James', 'Barbara', 'William', 'Elizabeth', 'Richard', 'Susan', 'Joseph', 'Jessica']
last_names = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis',
              'Rodriguez', 'Martinez', 'Hernandez', 'Lopez', 'Wilson', 'Anderson', 'Thomas']

lead_statuses = ['new', 'contacted', 'qualified', 'toured', 'proposal', 'negotiation']
sources = Source.all.to_a

leads_created = 0

60.times do |i|
  first_name = first_names.sample
  last_name = last_names.sample
  
  lead = company.leads.find_or_create_by!(
    email: "t+#{first_name.downcase}.#{last_name.downcase}#{i}@renterinsight.com"
  ) do |l|
    l.first_name = first_name
    l.last_name = last_name
    l.phone = "303-555-#{rand(1000..9999)}"
    l.status = lead_statuses.sample
    l.source_id = sources.sample&.id
    l.location_id = [denver_showroom.id, aurora_sales.id].sample
    l.notes = "Interested in #{['single-wide', 'double-wide', 'triple-wide'].sample} manufactured home. Budget: $#{rand(40..200)}k"
    l.created_at = rand(1..90).days.ago
  end
  leads_created += 1
end

puts "   ✅ Created #{leads_created} leads"

# ============================================================
# 7. CREATE CONTACTS (Past/Current Customers)
# ============================================================
contacts_created = 0

# Create contacts from some leads (converted customers)
25.times do |i|
  first_name = first_names.sample
  last_name = last_names.sample
  
  contact = company.contacts.find_or_create_by!(
    email: "t+customer.#{first_name.downcase}.#{last_name.downcase}#{i}@renterinsight.com"
  ) do |c|
    c.first_name = first_name
    c.last_name = last_name
    c.phone = "303-555-#{rand(1000..9999)}"
    c.location_id = [denver_showroom.id, aurora_sales.id].sample
    c.notes = "#{['Purchased', 'Previously purchased', 'Owns'].sample} #{['single-wide', 'double-wide'].sample} in #{[2020, 2021, 2022, 2023].sample}"
  end
  contacts_created += 1
end

puts "   ✅ Created #{contacts_created} contacts"

# ============================================================
# 8. CREATE DEALS (Active Sales)
# ============================================================
deal_stages = ['prospecting', 'qualification', 'needs_analysis', 'proposal', 'negotiation', 'closing']

deals_created = 0

15.times do |i|
  # Pick a contact for this deal
  contact = company.contacts.offset(rand(company.contacts.count)).first
  next unless contact
  
  # Pick a vehicle
  vehicle = company.vehicles.where(listing_type: 'manufactured_home').offset(rand(company.vehicles.where(listing_type: 'manufactured_home').count)).first
  next unless vehicle
  
  deal = company.deals.find_or_create_by!(
    name: "#{vehicle.year} #{vehicle.make} #{vehicle.model} - #{contact.first_name} #{contact.last_name}"
  ) do |d|
    d.stage = deal_stages.sample
    d.value = vehicle.sale_price - rand(0..10000)
    d.probability = { 'prospecting' => 10, 'qualification' => 25, 'needs_analysis' => 40, 'proposal' => 50, 'negotiation' => 75, 'closing' => 90 }[d.stage]
    d.expected_close_date = rand(7..60).days.from_now
    d.location_id = vehicle.location_id
    d.user_id = users.sample.id
    d.vehicle_id = vehicle.id
    d.contact_id = contact.id
    d.notes = "Customer very interested. #{['Cash buyer', 'Needs financing', 'Trade-in involved'].sample}"
  end
  deals_created += 1
end

puts "   ✅ Created #{deals_created} deals"

# ============================================================
# 9. CREATE SERVICE TICKETS
# ============================================================
priorities = ['low', 'medium', 'high', 'urgent']
ticket_statuses = ['open', 'in_progress', 'completed']
ticket_titles = ['Warranty Repair', 'Maintenance Service', 'Installation', 'Inspection', 'Customer Request']

tickets_created = 0

25.times do |i|
  vehicle = company.vehicles.offset(rand(company.vehicles.count)).first
  next unless vehicle
  
  ticket = company.service_tickets.create!(
    title: ticket_titles.sample,
    vehicle_id: vehicle.id,
    location_id: service_dept.id,
    priority: priorities.sample,
    status: ticket_statuses.sample,
    description: "#{['Plumbing issue', 'Electrical problem', 'HVAC not working', 'Door adjustment', 'Window repair'].sample}",
    notes: "Customer reported #{rand(1..7)} days ago",
    created_at: rand(1..30).days.ago
  )
  tickets_created += 1
end

puts "   ✅ Created #{tickets_created} service tickets"

# ============================================================
# SUMMARY
# ============================================================
puts ""
puts "🎉 TRADE SHOW DEMO DATA COMPLETE!"
puts "="*60
puts "Company: Summit Park Manufactured Homes"
puts "Contact: t+summitpark@renterinsight.com / 303-570-9810"
puts ""
puts "📊 Demo Data Summary:"
puts "   • #{company.locations.count} Locations"
puts "   • #{company.users.count} Users (password: demo123)"
puts "   • #{company.vehicles.where(listing_type: 'manufactured_home').count} Manufactured Homes"
puts "   • #{company.vehicles.where(listing_type: 'rv').count} RVs"
puts "   • #{company.leads.count} Leads"
puts "   • #{company.contacts.count} Customer Contacts"
puts "   • #{company.deals.count} Active Deals"
puts "   • #{company.service_tickets.count} Service Tickets"
puts ""
puts "👥 Users (all password: demo123):"
company.users.each do |user|
  puts "   • #{user.email} (#{user.title})"
end
puts ""
puts "🏬 Locations:"
company.locations.each do |loc|
  puts "   • #{loc.name} - #{loc.city}, CO"
end
puts "="*60
