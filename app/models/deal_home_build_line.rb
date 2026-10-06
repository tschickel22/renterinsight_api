# frozen_string_literal: true

# One line of a deal's home build: the base home, a factory option or finish,
# freight, a dealer add-on, or a custom line the rep typed. Labels and groups
# are snapshots so a later price book cannot rename a signed line. Cost never
# reaches a buyer.
class DealHomeBuildLine < ApplicationRecord
  KINDS = %w[base option freight addon custom].freeze
  UNITS = %w[each lf sf].freeze
  # What the state tax rules (E45) read. Indiana, for one, taxes delivery,
  # set-up and utility connections sold by the dealer.
  TAX_CATEGORIES = %w[home factory_option delivery setup utility_connection fee other].freeze

  belongs_to :build, class_name: 'DealHomeBuild', foreign_key: :deal_home_build_id, inverse_of: :lines
  belongs_to :option, class_name: 'CatalogOption', foreign_key: :catalog_option_id, optional: true
  belongs_to :truebuild_addon, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :unit, inclusion: { in: UNITS }
  validates :tax_category, inclusion: { in: TAX_CATEGORIES }
  validates :label, presence: true
  validates :quantity, numericality: { greater_than: 0 }

  before_save { self.metadata = metadata.to_h.deep_stringify_keys }

  # Books carry the unit only in the option's name: "Wood Beam On Ceiling -
  # Per LF", "Vertical Board & Batten per SF", "Shake siding (SF) max 10'".
  def self.unit_for(name)
    text = name.to_s.downcase
    return 'lf' if text.match?(/\bper\s*(lf|lin(ear)?\.?\s*(ft|foot)?|ft|foot)\b|\(lf\)/)
    return 'sf' if text.match?(/\bper\s*(sf|sq\.?\s*(ft|foot)?)\b|\(sf\)/)

    'each'
  end

  # Charged to the buyer and counted in totals.
  def priced? = !tbd
end
