# frozen_string_literal: true

puts "🏭 Phase 2: Creating Advanced Demo Data..."

# Get the demo company
company = Company.find_by(name: 'Summit Park Manufactured Homes')
unless company
  puts "❌ Error: Demo company not found. Run Phase 1 first (bin/rails demo:mh_dealership)"
  exit
end

users = company.users.to_a
locations = company.locations.to_a
contacts = company.contacts.to_a
vehicles = company.vehicles.to_a
deals = company.deals.to_a
service_tickets = company.service_tickets.to_a

# ============================================================
# 1. CREATE ACCOUNTS (Organizations/Companies)
# ============================================================
puts "📊 Creating accounts..."
accounts_created = 0

account_types = ['customer', 'partner', 'vendor']
industries = ['Real Estate', 'Finance', 'Insurance', 'Construction', 'Property Management']

10.times do |i|
  account = company.accounts.create!(
    name: "#{['Summit', 'Mountain', 'Valley', 'River', 'Lake'].sample} #{['Properties', 'Investments', 'Homes', 'Realty', 'Group'].sample} ##{i}",
    account_type: account_types.sample,
    industry: industries.sample,
    phone: "303-555-#{rand(2000..2999)}",
    email: "t+account#{i}@renterinsight.com",
    location_id: locations.sample.id,
    owner_id: users.sample.id,
    status: 'active',
    annual_revenue: rand(100000..5000000),
    employee_count: rand(5..50),
    billing_street: "#{rand(100..9999)} #{['Main', 'Oak', 'Maple', 'Pine'].sample} St",
    billing_city: 'Denver',
    billing_state: 'CO',
    billing_postal_code: '80246'
  )
  accounts_created += 1
end

puts "   ✅ Created #{accounts_created} accounts"

# ============================================================
# 2. CREATE QUOTES
# ============================================================
puts "📋 Creating quotes..."
quotes_created = 0

quote_statuses = ['draft', 'sent', 'viewed', 'accepted', 'rejected']

15.times do |i|
  vehicle = vehicles.sample
  contact = contacts.sample
  
  items = [
    {
      description: "#{vehicle.year} #{vehicle.make} #{vehicle.model}",
      quantity: 1,
      unit_price: vehicle.sale_price,
      discount: rand(0..5000),
      tax_rate: 0.08,
      item_type: 'vehicle'
    },
    {
      description: 'Delivery & Setup',
      quantity: 1,
      unit_price: rand(500..2000),
      discount: 0,
      tax_rate: 0.08,
      item_type: 'service'
    }
  ]
  
  if rand(1..10) > 5
    items << {
      description: 'Extended Warranty',
      quantity: 1,
      unit_price: rand(1000..3000),
      discount: 0,
      tax_rate: 0,
      item_type: 'warranty'
    }
  end
  
  subtotal = items.sum { |item| (item[:unit_price] - item[:discount]) * item[:quantity] }
  tax = items.sum { |item| (item[:unit_price] - item[:discount]) * item[:quantity] * item[:tax_rate] }
  total = subtotal + tax
  
  status = quote_statuses.sample
  
  quote = company.quotes.create!(
    quote_number: "Q-#{Time.current.year}-#{1000 + i}",
    contact_id: contact.id,
    vehicle_id: vehicle.id,
    location_id: vehicle.location_id,
    items: items,
    subtotal: subtotal,
    tax: tax,
    total: total,
    status: status,
    valid_until: 30.days.from_now,
    sent_at: status != 'draft' ? rand(1..30).days.ago : nil,
    viewed_at: ['viewed', 'accepted', 'rejected'].include?(status) ? rand(1..20).days.ago : nil,
    accepted_at: status == 'accepted' ? rand(1..10).days.ago : nil,
    public_token: SecureRandom.urlsafe_base64(32)
  )
  quotes_created += 1
end

puts "   ✅ Created #{quotes_created} quotes"

# ============================================================
# 3. CREATE PAYMENT METHODS (FIXED)
# ============================================================
puts "💳 Creating payment methods..."
payment_methods_created = 0

20.times do |i|
  contact = contacts.sample
  method_type = ['credit_card', 'ach'].sample
  
  if method_type == 'credit_card'
    brand = ['Visa', 'MasterCard', 'Amex'].sample
    last_4 = rand(1000..9999).to_s
    
    company.payment_methods.create!(
      owner_id: contact.id,
      owner_type: 'Contact',
      method_type: method_type,
      location_id: contact.location_id,
      billing_first_name: contact.first_name,
      billing_last_name: contact.last_name,
      billing_street: "#{rand(100..9999)} Main St",
      billing_city: 'Denver',
      billing_state: 'CO',
      billing_zip: '80246',
      is_active: true,
      is_default: i % 5 == 0,
      nickname: "#{brand.titleize} ending in #{last_4}",
      credit_card_brand: brand,
      credit_card_last_4: last_4,
      credit_card_exp_month: rand(1..12),
      credit_card_exp_year: rand(2026..2029)
    )
  else
    account_type = ['checking', 'savings'].sample
    last_4 = rand(1000..9999).to_s
    
    company.payment_methods.create!(
      owner_id: contact.id,
      owner_type: 'Contact',
      method_type: method_type,
      location_id: contact.location_id,
      billing_first_name: contact.first_name,
      billing_last_name: contact.last_name,
      billing_street: "#{rand(100..9999)} Main St",
      billing_city: 'Denver',
      billing_state: 'CO',
      billing_zip: '80246',
      is_active: true,
      is_default: i % 5 == 0,
      nickname: "#{account_type.titleize} ending in #{last_4}",
      ach_account_type: account_type,
      ach_routing_number_encrypted: "DEMO_ENCRYPTED_ROUTING",
      ach_account_number_encrypted: "DEMO_ENCRYPTED_ACCOUNT",
      ach_last_4: last_4
    )
  end
  
  payment_methods_created += 1
end

puts "   ✅ Created #{payment_methods_created} payment methods"

puts ""
puts "🎉 PHASE 2 COMPLETE (PARTIAL - Payment methods only for now)"
puts "="*60

# ============================================================
# 4. CREATE INVOICES
# ============================================================
puts "🧾 Creating invoices..."
invoices_created = 0

invoice_statuses = ['draft', 'sent', 'viewed', 'paid', 'overdue']

20.times do |i|
  contact = contacts.sample
  deal = deals.sample
  
  items_data = [
    { description: 'Down Payment', quantity: 1, rate: rand(5000..15000), item_type: 'down_payment' },
    { description: 'Processing Fee', quantity: 1, rate: rand(100..500), item_type: 'fee' }
  ]
  
  status = invoice_statuses.sample
  
  invoice = company.invoices.create!(
    invoice_number: "INV-#{Time.current.year}-#{2000 + i}",
    contact_id: contact.id,
    deal_id: deal&.id,
    location_id: contact.location_id,
    invoice_date: rand(1..60).days.ago,
    due_date: rand(1..30).days.from_now,
    status: status,
    subtotal: items_data.sum { |item| item[:rate] * item[:quantity] },
    tax_rate: 0.08,
    sent_at: status != 'draft' ? rand(1..30).days.ago : nil,
    viewed_at: ['viewed', 'paid'].include?(status) ? rand(1..20).days.ago : nil,
    paid_at: status == 'paid' ? rand(1..10).days.ago : nil,
    public_token: SecureRandom.urlsafe_base64(32),
    payment_token: SecureRandom.urlsafe_base64(32)
  )
  
  invoice.update!(
    tax_amount: invoice.subtotal * invoice.tax_rate,
    total: invoice.subtotal + (invoice.subtotal * invoice.tax_rate)
  )
  
  invoice.update!(
    amount_due: invoice.total,
    amount_paid: status == 'paid' ? invoice.total : 0
  )
  
  items_data.each_with_index do |item, idx|
    invoice.invoice_items.create!(
      description: item[:description],
      quantity: item[:quantity],
      rate: item[:rate],
      amount: item[:rate] * item[:quantity],
      item_type: item[:item_type],
      position: idx + 1
    )
  end
  
  invoices_created += 1
end

puts "   ✅ Created #{invoices_created} invoices with line items"

# ============================================================
# 5. CREATE LOANS
# ============================================================
puts "🏦 Creating loans..."
loans_created = 0

10.times do |i|
  contact = contacts.sample
  vehicle = vehicles.sample
  
  principal = vehicle.sale_price - rand(5000..15000)
  interest_rate = rand(4.5..12.9).round(2)
  term_months = [60, 72, 84, 120, 180, 240].sample
  
  monthly_rate = interest_rate / 100 / 12
  payment_amount = (principal * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
  
  loan = company.loans.create!(
    loan_number: "LOAN-#{Time.current.year}-#{3000 + i}",
    borrower_id: contact.id,
    borrower_type: 'Contact',
    financed_entity_id: vehicle.id,
    financed_entity_type: 'Vehicle',
    location_id: contact.location_id,
    loan_type: 'retail',
    principal_amount: principal,
    interest_rate: interest_rate,
    term_months: term_months,
    regular_payment_amount: payment_amount.round(2),
    current_balance: principal,
    origination_date: rand(1..180).days.ago,
    first_payment_date: rand(30..60).days.ago,
    maturity_date: term_months.months.from_now,
    payment_frequency: 'monthly',
    day_of_month_due: [1, 15].sample,
    status: 'active',
    payments_made: rand(0..12),
    payments_remaining: term_months - rand(0..12),
    auto_pay_enabled: [true, false].sample
  )
  
  loans_created += 1
end

puts "   ✅ Created #{loans_created} loans"

# ============================================================
# 6. CREATE PAYMENTS
# ============================================================
puts "💰 Creating payments..."
payments_created = 0

company.invoices.where(status: 'paid').limit(10).each do |invoice|
  payment_method = company.payment_methods.where(owner_id: invoice.contact_id, owner_type: 'Contact').first
  next unless payment_method
  next if invoice.amount_due.nil? || invoice.amount_due <= 0  # Skip zero/nil amounts
  
  company.payments.create!(
    payable_id: invoice.id,
    payable_type: 'Invoice',
    payer_id: invoice.contact_id,
    payer_type: 'Contact',
    payment_method_id: payment_method.id,
    location_id: invoice.location_id,
    payment_number: "PAY-#{Time.current.year}-#{4000 + payments_created}",
    payment_type: 'one_time',
    payment_date: invoice.paid_at,
    amount: invoice.amount_due,
    status: 'completed',
    processed_at: invoice.paid_at
  )
  
  payments_created += 1
end

company.loans.where(status: 'active').limit(5).each do |loan|
  payment_method = company.payment_methods.where(owner_id: loan.borrower_id, owner_type: 'Contact').first
  next unless payment_method
  
  rand(1..3).times do |i|
    company.payments.create!(
      payable_id: loan.id,
      payable_type: 'Loan',
      payer_id: loan.borrower_id,
      payer_type: 'Contact',
      payment_method_id: payment_method.id,
      loan_id: loan.id,
      location_id: loan.location_id,
      payment_number: "PAY-#{Time.current.year}-#{4000 + payments_created}",
      payment_type: 'loan_payment',
      payment_date: (i + 1).months.ago,
      amount: loan.regular_payment_amount,
      principal_amount: loan.regular_payment_amount * 0.7,
      interest_amount: loan.regular_payment_amount * 0.3,
      status: 'completed',
      processed_at: (i + 1).months.ago
    )
    
    payments_created += 1
  end
end

puts "   ✅ Created #{payments_created} payments"

# ============================================================
# 7. CREATE WARRANTY CLAIMS
# ============================================================
puts "🛡️ Creating warranty claims..."
claims_created = 0

manufacturers = Manufacturer.limit(5).to_a

5.times do |i|
  ticket = service_tickets.sample
  
  claim = company.warranty_claims.create!(
    claim_number: "WC-#{Time.current.year}-#{5000 + i}",
    service_ticket_id: ticket.id,
    location_id: ticket.location_id,
    manufacturer_id: manufacturers.sample.id,
    status: ['draft', 'submitted', 'under_review', 'approved', 'denied'].sample,
    parts: [{ part_name: 'HVAC Unit', cost: rand(100..500) }],
    labor: [{ description: 'Diagnostic & Repair', hours: rand(2..8), rate: 75 }],
    estimated_amount: rand(150..800),
    approved_amount: rand(100..700),
    submitted_at: rand(1..30).days.ago,
    notes_to_manufacturer: "Requesting warranty coverage for #{['HVAC failure', 'Plumbing leak', 'Electrical issue'].sample}",
    public_token: SecureRandom.urlsafe_base64(32)
  )
  
  claims_created += 1
end

puts "   ✅ Created #{claims_created} warranty claims"

# ============================================================
# 8. CREATE COMMISSIONS
# ============================================================
puts "💵 Creating commissions..."
commissions_created = 0

deals.each do |deal|
  next unless deal.user_id
  
  commission_amount = deal.value * rand(0.03..0.08)
  
  company.commissions.create!(
    deal_id: deal.id,
    user_id: deal.user_id,
    location_id: deal.location_id,
    commission_type: 'percentage',
    amount: commission_amount,
    rate: rand(3.0..8.0).round(2),
    status: ['pending', 'approved', 'paid'].sample,
    paid_date: rand(1..60).days.ago
  )
  
  commissions_created += 1
end

puts "   ✅ Created #{commissions_created} commissions"

# ============================================================
# 9. CREATE TAGS
# ============================================================
puts "🏷️ Creating tags..."
tags_created = 0

tag_data = [
  { name: 'Hot Lead', category: 'lead', color: '#ef4444', tag_type: ['lead'] },
  { name: 'Cash Buyer', category: 'deal', color: '#10b981', tag_type: ['deal'] },
  { name: 'Trade-In', category: 'deal', color: '#3b82f6', tag_type: ['deal'] },
  { name: 'Financing Approved', category: 'deal', color: '#8b5cf6', tag_type: ['deal'] },
  { name: 'VIP Customer', category: 'contact', color: '#f59e0b', tag_type: ['contact'] },
  { name: 'Warranty Issue', category: 'service', color: '#ef4444', tag_type: ['service_ticket'] },
  { name: 'Urgent', category: 'general', color: '#dc2626', tag_type: ['general'] },
  { name: 'Follow Up', category: 'general', color: '#6366f1', tag_type: ['general'] }
]

tag_data.each do |tag_info|
  company.tags.create!(
    name: tag_info[:name],
    category: tag_info[:category],
    color: tag_info[:color],
    tag_type: tag_info[:tag_type],
    is_active: true,
    is_system: false,
    usage_count: rand(1..25)
  )
  tags_created += 1
end

puts "   ✅ Created #{tags_created} tags"

# ============================================================
# 10. CREATE TASKS
# ============================================================
puts "✅ Creating tasks..."
tasks_created = 0

task_priorities = ['low', 'medium', 'high', 'urgent']
task_statuses = ['pending', 'in_progress', 'completed', 'cancelled']

deals.sample(10).each do |deal|
  company.tasks.create!(
    title: "#{['Follow up with', 'Send contract to', 'Schedule appointment with', 'Call'].sample} #{deal.name}",
    description: "#{['Discuss financing options', 'Review final terms', 'Answer questions', 'Close deal'].sample}",
    taskable_id: deal.id,
    taskable_type: 'Deal',
    task_module: 'deals',
    location_id: deal.location_id,
    assigned_to_id: deal.user_id,
    priority: task_priorities.sample,
    status: task_statuses.sample,
    due_date: rand(1..30).days.from_now,
    completed_at: task_statuses.sample == 'completed' ? rand(1..10).days.ago : nil
  )
  tasks_created += 1
end

service_tickets.sample(8).each do |ticket|
  company.tasks.create!(
    title: "#{['Complete', 'Order parts for', 'Schedule', 'Follow up on'].sample} #{ticket.title}",
    description: ticket.description,
    taskable_id: ticket.id,
    taskable_type: 'ServiceTicket',
    task_module: 'service',
    location_id: ticket.location_id,
    assigned_to_id: users.sample.id,
    priority: task_priorities.sample,
    status: task_statuses.sample,
    due_date: rand(1..14).days.from_now
  )
  tasks_created += 1
end

puts "   ✅ Created #{tasks_created} tasks"

# ============================================================
# 11. CREATE NOTES
# ============================================================
puts "📝 Creating notes..."
notes_created = 0

contacts.sample(15).each do |contact|
  Note.create!(
    entity_id: contact.id,
    entity_type: 'Contact',
    user_id: users.sample.id,
    created_by_name: users.sample.name,
    content: "#{['Very interested in', 'Asked about', 'Wants to see', 'Prefers'].sample} #{['single-wide models', 'double-wide options', 'financing', 'trade-in value', 'delivery timeline'].sample}"
  )
  notes_created += 1
end

deals.sample(10).each do |deal|
  Note.create!(
    entity_id: deal.id,
    entity_type: 'Deal',
    user_id: deal.user_id || users.sample.id,
    created_by_name: users.sample.name,
    content: "#{['Customer', 'Buyer', 'Client'].sample} #{['approved for financing', 'requesting better terms', 'ready to close', 'needs more time', 'comparing other options'].sample}"
  )
  notes_created += 1
end

puts "   ✅ Created #{notes_created} notes"

# ============================================================
# 12. CREATE LISTINGS (Public Inventory)
# ============================================================
puts "🏠 Creating public listings..."
listings_created = 0

vehicles.sample(20).each do |vehicle|
  next unless vehicle.listing_type == 'manufactured_home'
  
  listing = company.listings.create!(
    vehicle_id: vehicle.id,
    location_id: vehicle.location_id,
    status: 'active',
    offer_type: 'sale',
    sale_price: vehicle.sale_price,
    rent_price: vehicle.rent_price || rand(800..1500),
    rent_period: 'monthly',
    description: vehicle.description,
    features: vehicle.features,
    immediately_available: [true, false].sample,
    available_date: rand(1..30).days.from_now,
    has_ac: vehicle.central_air,
    has_fireplace: vehicle.fireplace,
    has_deck: vehicle.deck,
    has_garage: vehicle.garage,
    pets_allowed: [true, false].sample,
    pet_policy: "Small pets allowed with deposit",
    pet_deposit: 300,
    security_deposit: rand(500..1500),
    application_fee: 50,
    contact_phone: vehicle.location.phone,
    contact_email: vehicle.location.email,
    published_at: rand(1..90).days.ago
  )
  
  listings_created += 1
end

puts "   ✅ Created #{listings_created} public listings"

# ============================================================
# 13. CREATE BROCHURES
# ============================================================
puts "📄 Creating brochures..."
brochures_created = 0

brochure_templates = ['modern', 'classic', 'luxury', 'family']

5.times do |i|
  vehicle_ids = vehicles.sample(rand(1..5)).map(&:id)
  
  brochure = company.brochures.create!(
    title: "#{['New', 'Featured', 'Premium', 'Luxury'].sample} Homes - #{['Winter', 'Spring', 'Summer', 'Fall'].sample} #{Time.current.year}",
    description: "Browse our selection of quality manufactured homes",
    template_name: brochure_templates.sample,
    vehicle_ids: vehicle_ids,
    location_id: locations.sample.id,
    status: ['active', 'inactive', 'archived'].sample,
    is_public: [true, false].sample,
    public_id: SecureRandom.urlsafe_base64(16),
    view_count: rand(0..100),
    download_count: rand(0..25),
    share_count: rand(0..10),
    template_data: {
      logo_url: 'https://via.placeholder.com/200x80',
      primary_color: '#1e40af',
      tagline: 'Quality Homes, Exceptional Service'
    }
  )
  
  brochures_created += 1
end

puts "   ✅ Created #{brochures_created} brochures"

# ============================================================
# FINAL SUMMARY
# ============================================================
puts ""
puts "🎉 PHASE 2 COMPLETE!"
puts "="*60
puts "📊 Advanced Demo Data Summary:"
puts "   • #{company.accounts.count} Accounts"
puts "   • #{company.quotes.count} Quotes"
puts "   • #{company.payment_methods.count} Payment Methods"
puts "   • #{company.invoices.count} Invoices (#{InvoiceItem.where(invoice_id: company.invoices.pluck(:id)).count} line items)"
puts "   • #{company.loans.count} Loans"
puts "   • #{company.payments.count} Payments"
puts "   • #{company.warranty_claims.count} Warranty Claims"
puts "   • #{company.commissions.count} Commissions"
puts "   • #{company.tags.count} Tags"
puts "   • #{company.tasks.count} Tasks"
puts "   • #{Note.where(entity_type: ['Contact', 'Deal']).count} Notes"
puts "   • #{company.listings.count} Public Listings"
puts "   • #{company.brochures.count} Brochures"
puts ""
puts "🏆 COMPLETE TRADE SHOW DEMO READY!"
puts "="*60
