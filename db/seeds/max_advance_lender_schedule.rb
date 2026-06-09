# frozen_string_literal: true

# Max Advance Phase 2 — seed the DEFAULT calculation schedule for the "21st Mortgage"
# lender (allowances, deletions, markup/VEP config) from the 21st sheet.
#
# Idempotent: find_or_create_by on natural keys, re-runnable. Company-scoped — applies
# to every company that has a "21st Mortgage" lender (the demo company seeds one).
#
#   bin/rails runner db/seeds/max_advance_lender_schedule.rb

# category, name, standard, maximum, pricing_basis, material, wz2_adder, wz3_adder
ALLOWANCES_21ST = [
  ['ac',          'A/C',                     4500,  7000,  'flat',               nil,        nil, nil],
  ['hookups',     'Electric Hookup',         1500,  2500,  'per_each',           nil,        nil, nil],
  ['hookups',     'Water Hookup',            500,   1000,  'per_each',           nil,        nil, nil],
  ['hookups',     'Sewer Hookup',            500,   1000,  'per_each',           nil,        nil, nil],
  ['hookups',     'Gas Hookup',              500,   1000,  'per_each',           nil,        nil, nil],
  ['steps_decks', 'Steps & Decks',           1000,  3000,  'per_each',           nil,        nil, nil],
  ['gutters',     'Gutters & Downspouts',    1300,  1800,  'flat',               nil,        nil, nil],
  ['delivery_set','Delivery & Set (Single)', 4500,  6000,  'per_section_single', nil,        500, 750],
  ['delivery_set','Delivery & Set (Multi)',  9000,  12000, 'per_section_multi',  nil,        500, 750],
  ['trim_out',    'Trim Out (Single)',       1500,  2000,  'per_section_single', nil,        nil, nil],
  ['trim_out',    'Trim Out (Multi)',        2000,  3000,  'per_section_multi',  nil,        nil, nil],
  ['skirting',    'Skirting (Vinyl)',        2000,  2000,  'per_material',       'vinyl',    nil, nil],
  ['skirting',    'Skirting (Metal)',        3000,  3000,  'per_material',       'metal',    nil, nil],
  ['skirting',    'Skirting (Hardie)',       4000,  4000,  'per_material',       'hardie',   nil, nil],
  ['skirting',    'Skirting (Masonry)',      6000,  6000,  'per_material',       'masonry',  nil, nil],
  ['footers',     'Footers (Single)',        2500,  4000,  'per_section_single', nil,        nil, nil],
  ['footers',     'Footers (Multi)',         5000,  8000,  'per_section_multi',  nil,        nil, nil],
  ['pad',         'Dirt Pad (Single)',       2500,  4000,  'per_section_single', nil,        nil, nil],
  ['pad',         'Dirt Pad (Multi)',        5000,  8000,  'per_section_multi',  nil,        nil, nil]
].freeze

# name, amount, invoice_reference, single_amount, multi_amount
DELETIONS_21ST = [
  ['wheels_axles',    nil, nil,                500,  1000],
  ['factory_freight', nil, 'factory_freight',  nil,  nil],
  ['dealer_rebate',   nil, 'sales_allowance',  nil,  nil],
  ['ac',              nil, nil,                nil,  nil],
  ['tax_from_invoice',nil, 'tax_from_invoice', nil,  nil],
  ['hud_fees',        nil, 'hud_fees',         nil,  nil],
  ['packs',           nil, nil,                nil,  nil],
  ['advertising',     nil, nil,                nil,  nil],
  ['trim_out',        nil, nil,                nil,  nil]
].freeze

MARKUP_21ST = {
  base_markup_pct: 145, max_age_years: 4,
  vep0_adj_pct: 5, vep1_adj_pct: 0, vep2_adj_pct: -5,
  used_onsite_factor_pct: 140, used_delivered_factor_pct: 130
}.freeze

def seed_21st_schedule(lender)
  company = lender.company

  ALLOWANCES_21ST.each do |category, name, std, max, basis, material, wz2, wz3|
    item = lender.allowance_items.find_or_initialize_by(category: category, name: name, material: material)
    item.company                   = company
    item.standard_allowance        = std
    item.maximum_allowance         = max
    item.pricing_basis             = basis
    item.wind_zone2_adder_per_side = wz2
    item.wind_zone3_adder_per_side = wz3
    item.active                    = true
    item.save!
  end

  DELETIONS_21ST.each do |name, amount, ref, single, multi|
    d = lender.deletion_items.find_or_initialize_by(name: name)
    d.company           = company
    d.amount            = amount
    d.invoice_reference = ref
    d.single_amount     = single
    d.multi_amount      = multi
    d.active            = true
    d.save!
  end

  cfg = lender.markup_config || lender.build_markup_config
  cfg.company = company
  cfg.assign_attributes(MARKUP_21ST)
  cfg.save!

  puts "  [#{company.name} ##{company.id}] 21st Mortgage: #{lender.allowance_items.count} allowances, " \
       "#{lender.deletion_items.count} deletions, markup base #{cfg.base_markup_pct}%"
end

puts "Seeding Max Advance 21st Mortgage schedule..."
lenders = Lender.where(name: '21st Mortgage', is_deleted: [false, nil])
if lenders.empty?
  puts "  (no '21st Mortgage' lender found — run demo_company seed first)"
else
  lenders.find_each { |l| seed_21st_schedule(l) }
end
puts "Done."
