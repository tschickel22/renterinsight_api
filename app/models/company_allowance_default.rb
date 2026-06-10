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
      { category: 'ac',          name: 'A/C',                      standard_allowance: 4500, maximum_allowance: 7000,  pricing_basis: 'flat',                position: 10 },
      { category: 'hookups',     name: 'Electric Hookup',          standard_allowance: 1500, maximum_allowance: 2500,  pricing_basis: 'per_each',            position: 20 },
      { category: 'hookups',     name: 'Water Hookup',             standard_allowance: 500,  maximum_allowance: 1000,  pricing_basis: 'per_each',            position: 30 },
      { category: 'hookups',     name: 'Sewer Hookup',             standard_allowance: 500,  maximum_allowance: 1000,  pricing_basis: 'per_each',            position: 31 },
      { category: 'hookups',     name: 'Gas Hookup',               standard_allowance: 500,  maximum_allowance: 1000,  pricing_basis: 'per_each',            position: 32 },
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
      { category: 'skirting', name: 'Skirting (Vinyl)',   standard_allowance: 2000, maximum_allowance: 2000, pricing_basis: 'per_material', material: 'vinyl',   position: 100 },
      { category: 'skirting', name: 'Skirting (Metal)',   standard_allowance: 3000, maximum_allowance: 3000, pricing_basis: 'per_material', material: 'metal',   position: 110 },
      { category: 'skirting', name: 'Skirting (Hardie)',  standard_allowance: 4000, maximum_allowance: 4000, pricing_basis: 'per_material', material: 'hardie',  position: 120 },
      { category: 'skirting', name: 'Skirting (Masonry)', standard_allowance: 6000, maximum_allowance: 6000, pricing_basis: 'per_material', material: 'masonry', position: 130 },

      # Footers
      { category: 'footers', name: 'Footers (Single)', standard_allowance: 2500, maximum_allowance: 4000, pricing_basis: 'per_section_single', position: 140 },
      { category: 'footers', name: 'Footers (Multi)',  standard_allowance: 5000, maximum_allowance: 8000, pricing_basis: 'per_section_multi',  position: 150 },

      # Pad (Dirt Pad)
      { category: 'pad', name: 'Dirt Pad (Single)', standard_allowance: 2500, maximum_allowance: 4000, pricing_basis: 'per_section_single', position: 160 },
      { category: 'pad', name: 'Dirt Pad (Multi)',  standard_allowance: 5000, maximum_allowance: 8000, pricing_basis: 'per_section_multi',  position: 170 },
    ]

    items.each do |attrs|
      find_or_create_by!(company: company, category: attrs[:category], name: attrs[:name]) do |item|
        item.assign_attributes(attrs.merge(is_seeded: true, active: true))
      end
    end
  end

  # Canonical seeded names (must match the names produced by seed_defaults above and the
  # 21st Mortgage lender-schedule seed). Used by resync_defaults! to retire renamed rows.
  CANONICAL_SEEDED_NAMES = [
    'A/C', 'Electric Hookup', 'Water Hookup', 'Sewer Hookup', 'Gas Hookup',
    'Steps & Decks', 'Gutters & Downspouts',
    'Delivery & Set (Single)', 'Delivery & Set (Multi)',
    'Trim Out (Single)', 'Trim Out (Multi)',
    'Skirting (Vinyl)', 'Skirting (Metal)', 'Skirting (Hardie)', 'Skirting (Masonry)',
    'Footers (Single)', 'Footers (Multi)',
    'Dirt Pad (Single)', 'Dirt Pad (Multi)'
  ].freeze

  # One-time migration helper: bring a company's defaults onto the canonical name set.
  # Deletes ONLY seeded rows (is_seeded: true) whose names are no longer canonical — i.e.
  # the pre-alignment names ('Air Conditioner', 'Pad / Dirt Pad (Single)', …). Hand-added
  # rows (is_seeded: false) and rep-entered dealer_price/cost on surviving rows are left
  # untouched. Then re-seeds the canonical set. Idempotent.
  #
  # Safe because: inventory packages snapshot the name (no FK to defaults), and a renamed
  # default is only referenced by LenderAllowanceItem via company_allowance_default_id —
  # which resync handles by leaving lender items alone (re-run the lender schedule seed
  # after this to realign them).
  #
  #   bin/rails runner "CompanyAllowanceDefault.resync_defaults!(Company.find(97))"
  def self.resync_defaults!(company)
    stale = company.company_allowance_defaults
                   .where(is_seeded: true)
                   .where.not(name: CANONICAL_SEEDED_NAMES)
    stale_names = stale.pluck(:name)
    # Null out any lender-item links to rows we're about to delete so the FK doesn't block.
    LenderAllowanceItem.where(company_allowance_default_id: stale.select(:id))
                       .update_all(company_allowance_default_id: nil)
    deleted = stale.delete_all
    seed_defaults(company)
    Rails.logger.info(
      "[CompanyAllowanceDefault.resync_defaults!] company #{company.id}: removed #{deleted} " \
      "stale (#{stale_names.join(', ')}); canonical set re-seeded."
    )
    { removed: deleted, removed_names: stale_names }
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
