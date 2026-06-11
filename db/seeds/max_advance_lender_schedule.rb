# frozen_string_literal: true

# Max Advance Phase 2 — seed the 21st Mortgage lender + its FULL calculation schedule
# (allowances, deletions, markup/VEP config) for EVERY manufactured-housing company.
#
# 21st Mortgage is the dominant MH lender, so every MH customer gets it as a working
# sample (and most will use it directly). For each MH company this seed:
#   1. Finds an existing 21st lender CASE-INSENSITIVELY ("21st mortgage" counts — never
#      renames a dealer-created lender), or CREATES a "21st Mortgage" lender.
#   2. Seeds/refreshes the full 21st schedule onto it (authoritative for 21st rates —
#      re-running updates rows back to the published schedule).
#
# Idempotent: find_or_initialize_by on natural keys, re-runnable.
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
# Notes (reconciled against the Sunshine worksheets/invoices):
#  - dealer_rebate has NO invoice_reference: the manufacturer Sales Allowance is already
#    netted into Total Invoice (= gross_invoice / A), so deleting it again would double-count.
#  - hud_fees combines hud_fees + state_assoc_fees (the worksheet's single "HUD Dues/Fees"
#    line is both, e.g. 160+110=270 single / 320+220=540 multi).
#  - trim_out pulls the manufacturer Trim Out line from the invoice (deleted + added back).
#  - ac pulls the factory-installed A/C line from the invoice (deleted from the markup
#    base; the calculator implicitly adds the lender's A/C ALLOWANCE in F).
DELETIONS_21ST = [
  ['wheels_axles',    nil, nil,                         500,  1000],
  ['factory_freight', nil, 'factory_freight',           nil,  nil],
  ['dealer_rebate',   nil, nil,                         nil,  nil],
  ['ac',              nil, 'ac_from_invoice',           nil,  nil],
  ['tax_from_invoice',nil, 'tax_from_invoice',          nil,  nil],
  ['hud_fees',        nil, 'hud_fees+state_assoc_fees', nil,  nil],
  ['packs',           nil, nil,                         nil,  nil],
  ['advertising',     nil, nil,                         nil,  nil],
  ['trim_out',        nil, 'trim_out',                  nil,  nil]
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

  puts "  [#{company.name} ##{company.id}] #{lender.name}: #{lender.allowance_items.count} allowances, " \
       "#{lender.deletion_items.count} deletions, markup base #{cfg.base_markup_pct}%"
end

# Case-insensitive find so a dealer-typed "21st mortgage" is recognized (never renamed);
# create the lender when the company doesn't have one yet.
def find_or_create_21st_lender(company)
  existing = company.lenders.not_deleted.where('LOWER(name) = ?', '21st mortgage').first
  return existing if existing

  lender = company.lenders.create!(name: '21st Mortgage', active: true)
  puts "  [#{company.name} ##{company.id}] created 21st Mortgage lender ##{lender.id}"
  lender
end

puts 'Seeding 21st Mortgage lender + Max Advance schedule for all MH companies...'
Company.where(industry: 'manufactured_housing').find_each do |company|
  lender = find_or_create_21st_lender(company)
  seed_21st_schedule(lender)
rescue => e
  puts "  [#{company.name} ##{company.id}] FAILED: #{e.message}"
end
puts 'Done.'
