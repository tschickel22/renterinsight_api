# frozen_string_literal: true

# Company-level dealer-installed item defaults. Seeded from 21st Mortgage allowances.
# When a new lender is created, these defaults are copied as that lender's starting
# allowance schedule. Each lender can then override standard/max at the item level.
#
# dealer_cost / dealer_price are the dealer's own numbers — they don't change per lender.
class CompanyAllowanceDefault < ApplicationRecord
  belongs_to :company

  CATEGORIES = LenderAllowanceItem::CATEGORIES
  PRICING_BASES = LenderAllowanceItem::PRICING_BASES

  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :name, presence: true
  validates :pricing_basis, inclusion: { in: PRICING_BASES }, allow_nil: true
  validates :standard_allowance, :maximum_allowance, :dealer_cost, :dealer_price,
            :wind_zone2_adder_per_side, :wind_zone3_adder_per_side,
            numericality: true, allow_nil: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :name) }

  # Seed the 21st Mortgage defaults for a given company. Idempotent — skips items
  # that already exist (matched on company + category + name).
  def self.seed_defaults(company)
    items = [
      # Options
      { category: 'ac',          name: 'Air Conditioner',          standard_allowance: 4500, maximum_allowance: 7000,  pricing_basis: 'flat',                position: 10 },
      { category: 'hookups',     name: 'Electric Hookups',         standard_allowance: 1500, maximum_allowance: 2500,  pricing_basis: 'flat',                position: 20 },
      { category: 'hookups',     name: 'Water/Sewer/Gas Hookups',  standard_allowance: 500,  maximum_allowance: 1000,  pricing_basis: 'per_each',            position: 30 },
      { category: 'steps_decks', name: 'Steps & Decks',            standard_allowance: 1000, maximum_allowance: 3000,  pricing_basis: 'per_each',            position: 40 },
      { category: 'gutters',     name: 'Gutters & Downspouts',     standard_allowance: 1300, maximum_allowance: 1800,  pricing_basis: 'flat',                position: 50 },

      # Delivery & Set
      { category: 'delivery_set', name: 'Delivery & Set (Single)',  standard_allowance: 4500, maximum_allowance: 6000,  pricing_basis: 'per_section_single',
        wind_zone2_adder_per_side: 500, wind_zone3_adder_per_side: 750, position: 60 },
      { category: 'delivery_set', name: 'Delivery & Set (Multi)',   standard_allowance: 9000, maximum_allowance: 12000, pricing_basis: 'per_section_multi',
        wind_zone2_adder_per_side: 500, wind_zone3_adder_per_side: 750, position: 70 },

      # Trim Out
      { category: 'trim_out', name: 'Trim Out (Single)', standard_allowance: 1500, maximum_allowance: 2000, pricing_basis: 'per_section_single', position: 80 },
      { category: 'trim_out', name: 'Trim Out (Multi)',  standard_allowance: 2000, maximum_allowance: 3000, pricing_basis: 'per_section_multi',  position: 90 },

      # Skirting (Underpinning) — one row per material type
      { category: 'skirting', name: 'Skirting – Vinyl',            standard_allowance: 2000, maximum_allowance: 2000, pricing_basis: 'per_material', material: 'vinyl',   position: 100 },
      { category: 'skirting', name: 'Skirting – Metal',            standard_allowance: 3000, maximum_allowance: 3000, pricing_basis: 'per_material', material: 'metal',   position: 110 },
      { category: 'skirting', name: 'Skirting – Hardie/Insulated', standard_allowance: 4000, maximum_allowance: 4000, pricing_basis: 'per_material', material: 'hardie',  position: 120 },
      { category: 'skirting', name: 'Skirting – Masonry',          standard_allowance: 6000, maximum_allowance: 6000, pricing_basis: 'per_material', material: 'masonry', position: 130 },

      # Footers
      { category: 'footers', name: 'Footers (Single)', standard_allowance: 2500, maximum_allowance: 4000, pricing_basis: 'per_section_single', position: 140 },
      { category: 'footers', name: 'Footers (Multi)',  standard_allowance: 5000, maximum_allowance: 8000, pricing_basis: 'per_section_multi',  position: 150 },

      # Pad (Dirt Pad)
      { category: 'pad', name: 'Pad / Dirt Pad (Single)', standard_allowance: 2500, maximum_allowance: 4000, pricing_basis: 'per_section_single', position: 160 },
      { category: 'pad', name: 'Pad / Dirt Pad (Multi)',  standard_allowance: 5000, maximum_allowance: 8000, pricing_basis: 'per_section_multi',  position: 170 },
    ]

    items.each do |attrs|
      find_or_create_by!(company: company, category: attrs[:category], name: attrs[:name]) do |item|
        item.assign_attributes(attrs.merge(is_seeded: true, active: true))
      end
    end
  end

  # Copy all active defaults into LenderAllowanceItems for a given lender.
  # Called from Lender after_create callback.
  def self.populate_lender(lender)
    company = lender.company
    defaults = company.company_allowance_defaults.active.ordered

    defaults.each do |d|
      LenderAllowanceItem.find_or_create_by!(
        lender: lender,
        company: company,
        category: d.category,
        name: d.name
      ) do |item|
        item.standard_allowance         = d.standard_allowance
        item.maximum_allowance          = d.maximum_allowance
        item.dealer_cost                = d.dealer_cost
        item.dealer_price               = d.dealer_price
        item.pricing_basis              = d.pricing_basis
        item.material                   = d.material
        item.wind_zone2_adder_per_side  = d.wind_zone2_adder_per_side
        item.wind_zone3_adder_per_side  = d.wind_zone3_adder_per_side
        item.company_allowance_default  = d
        item.position                   = d.position
        item.active                     = true
      end
    end
  end
end
