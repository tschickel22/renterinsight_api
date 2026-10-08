# frozen_string_literal: true

# One of a dealer's packages or fees in TrueBuild. See CreateTruebuildAddons.
class TruebuildAddon < ApplicationRecord
  MODES = %w[included optional quote_only].freeze
  SOURCES = %w[PackageTemplate FeeTemplate].freeze

  belongs_to :company
  belongs_to :source, polymorphic: true
  belongs_to :manufacturer, optional: true
  # A deal build keeps the line (its label and price are snapshots) when the add-on goes.
  has_many :deal_home_build_lines, dependent: :nullify

  validates :mode, inclusion: { in: MODES }
  validates :source_type, inclusion: { in: SOURCES }
  validates :source_id, uniqueness: { scope: %i[company_id source_type] }
  validate :source_is_the_companys

  scope :active, -> { where(active: true) }
  scope :for_manufacturer, ->(id) { where(manufacturer_id: [nil, id]) }

  def name = source.name
  def description = source.try(:description)
  def price = (price_override || (fee? ? source.default_amount : source.default_price)).to_d
  def cost = (fee? ? 0 : source.cost).to_d
  def taxable = source.taxable
  def fee? = source_type == 'FeeTemplate'

  private

  def source_is_the_companys
    errors.add(:source, 'must be one of your packages or fees') if source && source.company_id != company_id
  end
end
