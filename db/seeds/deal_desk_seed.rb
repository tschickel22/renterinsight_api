# frozen_string_literal: true

# Deal Desk sample data — lender programs (with full tier matrices), fee templates,
# and F&I products. NO REAL RATE SHEETS EXIST YET: everything here is plausible sample
# data flagged is_seeded: true so it is obvious and swappable when real sheets arrive.
#
# Idempotent: safe to run repeatedly.
#
# Two ways to use:
#   1. Standalone — seeds the test/demo company (Summit Park, id 47) when present, else
#      the first company:
#        bin/rails runner "load 'db/seeds/deal_desk_seed.rb'"
#   2. From another seed (e.g. demo_company.rb) — set $seeding_demo_company = true before
#      loading so this file only DEFINES the methods, then call seed_deal_desk_for(company)
#      and seed_deal_desk_rbac! yourself against the resolved company.

# Seed lender programs (with tier matrices), fee templates, and F&I products for a single
# company. Idempotent: re-runnable; tier matrices are rebuilt each run so edits take effect.
def seed_deal_desk_for(company)
  unless company
    puts '⚠️  Deal Desk seed skipped — no company found.'
    return
  end

  puts "🧮 Seeding Deal Desk sample data for company ##{company.id} (#{company.name})..."

  # Enable the gated module for this demo company (tier assignment stays Tom's call;
  # this per-company override just makes the endpoints reachable in dev/demo).
  if company.respond_to?(:tenant_module_overrides)
    ov = company.tenant_module_overrides.find_or_initialize_by(module_key: 'sales.deal_desk')
    ov.update!(is_enabled: true)
  end

  # ---- Lender programs + tier matrices ---------------------------------------
  # tier: [label, fico_min, fico_max, age_min, age_max, rate%, max_term, max_ltv(ratio)]
  programs = [
    {
      lender_name: 'Aqua Finance', program_name: 'Recreational Standard', collateral_type: 'all',
      tiers: [
        ['Tier 1 (760+) · 0-5yr',  760, nil, 0, 5,   6.49, 240, 1.25],
        ['Tier 1 (760+) · 6-15yr', 760, nil, 6, 15,  7.49, 180, 1.15],
        ['Tier 2 (700-759) · 0-5yr',  700, 759, 0, 5,  7.29, 240, 1.20],
        ['Tier 2 (700-759) · 6-15yr', 700, 759, 6, 15, 8.29, 180, 1.10],
        ['Tier 3 (660-699) · 0-5yr',  660, 699, 0, 5,  8.99, 180, 1.15],
        ['Tier 3 (660-699) · 6-15yr', 660, 699, 6, 15, 10.49, 144, 1.05],
        ['Tier 4 (620-659) · 0-5yr',  620, 659, 0, 5,  11.49, 144, 1.10],
        ['Tier 4 (620-659) · 6-15yr', 620, 659, 6, 15, 13.99, 120, 1.00]
      ]
    },
    {
      lender_name: '21st Mortgage', program_name: 'MH Chattel', collateral_type: 'manufactured_home',
      tiers: [
        ['Prime (720+) · 0-10yr',     720, nil, 0, 10,  7.75, 240, 1.05],
        ['Prime (720+) · 11-30yr',    720, nil, 11, 30, 9.25, 180, 0.95],
        ['Near-prime (660-719) · 0-10yr', 660, 719, 0, 10, 9.50, 240, 1.00],
        ['Near-prime (660-719) · 11-30yr', 660, 719, 11, 30, 11.00, 180, 0.90],
        ['Sub-prime (600-659) · 0-10yr', 600, 659, 0, 10, 12.25, 180, 0.95],
        ['Sub-prime (600-659) · 11-30yr', 600, 659, 11, 30, 14.50, 144, 0.85],
        ['Deep (560-599) · 0-10yr',   560, 599, 0, 10, 15.99, 144, 0.85]
      ]
    },
    {
      lender_name: 'Medallion Bank', program_name: 'RV & Marine', collateral_type: 'rv',
      tiers: [
        ['Platinum (740+) · 0-5yr',  740, nil, 0, 5,  6.99, 240, 1.25],
        ['Platinum (740+) · 6-12yr', 740, nil, 6, 12, 8.49, 180, 1.15],
        ['Gold (680-739) · 0-5yr',   680, 739, 0, 5,  8.49, 240, 1.20],
        ['Gold (680-739) · 6-12yr',  680, 739, 6, 12, 9.99, 180, 1.10],
        ['Silver (640-679) · 0-5yr', 640, 679, 0, 5,  10.99, 180, 1.10],
        ['Silver (640-679) · 6-12yr', 640, 679, 6, 12, 12.99, 144, 1.00]
      ]
    }
  ]

  programs.each_with_index do |p, pi|
    program = LenderProgram.find_or_initialize_by(
      company: company, lender_name: p[:lender_name], program_name: p[:program_name]
    )
    program.update!(collateral_type: p[:collateral_type], active: true, is_seeded: true, position: pi,
                    notes: 'Sample program — seeded, swap when real rate sheets arrive.')

    # Rebuild the tier matrix each run so edits to this seed take effect.
    program.tiers.destroy_all
    p[:tiers].each_with_index do |row, ti|
      label, fmin, fmax, amin, amax, rate, term, ltv = row
      program.tiers.create!(
        tier_label: label, fico_min: fmin, fico_max: fmax,
        collateral_age_min_years: amin, collateral_age_max_years: amax,
        rate: rate, max_term_months: term, max_ltv: ltv, position: ti
      )
    end
  end

  # ---- Fee templates ---------------------------------------------------------
  fees = [
    ['Documentation Fee',     'doc',      599.00, false, 'all'],
    ['Title Fee',             'title',     85.00, false, 'all'],
    ['License & Registration', 'license',  150.00, false, 'all'],
    ['Prep / PDI',            'prep',     1200.00, true,  'rv'],
    ['Delivery',              'delivery', 2500.00, true,  'manufactured_home'],
    ['Setup & Install',       'setup',    4500.00, true,  'manufactured_home']
  ]
  fees.each_with_index do |(name, type, amount, taxable, applies), i|
    fee = FeeTemplate.find_or_initialize_by(company: company, name: name)
    fee.update!(fee_type: type, default_amount: amount, taxable: taxable,
                applies_to: applies, active: true, is_seeded: true, position: i)
  end

  # ---- F&I products ----------------------------------------------------------
  fni = [
    ['Vehicle Service Contract', 'service_contract', 2495.00, 1400.00],
    ['GAP Coverage',             'gap',               895.00,  450.00],
    ['Tire & Wheel Protection',  'tire_wheel',        695.00,  300.00],
    ['Paint & Fabric Protection', 'paint_fabric',     595.00,  200.00]
  ]
  fni.each_with_index do |(name, type, price, cost), i|
    product = FniProduct.find_or_initialize_by(company: company, name: name)
    product.update!(product_type: type, default_price: price, default_cost: cost,
                    active: true, is_seeded: true, position: i)
  end

  puts "   ✅ Lender programs: #{company.lender_programs.seeded.count} " \
       "(#{LenderProgramTier.joins(:lender_program).where(lender_programs: { company_id: company.id }).count} tiers)"
  puts "   ✅ Fee templates:   #{company.fee_templates.seeded.count}"
  puts "   ✅ F&I products:    #{company.fni_products.seeded.count}"
end

# Deal Desk RBAC backfill. Resource/Action seed_defaults are idempotent and add the new
# deal_desk resource + write/quote/configure/transfer_unit actions. Existing system roles
# are NOT re-seeded by Role.seed_defaults (it returns early once roles exist), so this
# grants the deal_desk permissions to existing roles by key — covering both global system
# roles (company_id nil) and any company-specific roles sharing those keys.
#
# Default config (Section 25): reps build/quote/compare freely; configure + transfer_unit
# are manager-only. All grants use scope 'all' (the controller authorizes with default
# scope 'all'; location filtering is applied operationally).
def seed_deal_desk_rbac!
  puts '🔐 Backfilling Deal Desk RBAC...'

  Resource.seed_defaults
  Action.seed_defaults

  deal_desk = Resource.find_by!(key: 'deal_desk')
  all_scope = Scope.find_by!(key: 'all')

  grant = lambda do |role, action_keys|
    Action.where(key: action_keys).each do |action|
      RolePermission.find_or_create_by!(role: role, resource: deal_desk, action: action, scope: all_scope, granted: true)
    end
  end

  rep_actions     = %w[read write quote].freeze
  manager_actions = %w[read write quote configure transfer_unit].freeze

  rep_roles     = %w[sales_rep crm_specialist]
  manager_roles = %w[company_manager location_manager location_admin company_admin]
  staff_roles   = %w[company_staff location_staff]

  Role.where(key: rep_roles).find_each     { |r| grant.call(r, rep_actions) }
  Role.where(key: manager_roles).find_each { |r| grant.call(r, manager_actions) }
  Role.where(key: staff_roles).find_each   { |r| grant.call(r, %w[read]) }

  puts "   ✅ deal_desk resource position: #{deal_desk.position}"
  puts "   ✅ reps (#{rep_roles.join(', ')}): #{rep_actions.join('/')}"
  puts "   ✅ managers (#{manager_roles.join(', ')}): #{manager_actions.join('/')}"
  puts "   ✅ staff (#{staff_roles.join(', ')}): read"
end

# ---- Standalone execution --------------------------------------------------
# When loaded directly (not from demo_company.rb), resolve the company and run.
# demo_company.rb sets $seeding_demo_company = true so this block is skipped there.
unless $seeding_demo_company
  target = Company.find_by(id: 47) || Company.first
  seed_deal_desk_for(target)
  seed_deal_desk_rbac!
end
