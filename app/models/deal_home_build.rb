# frozen_string_literal: true

# The home on a deal and what was chosen for it (backlog E49). A deal can
# hold several versions (a second home, another option set); the LIVE one
# writes the deal and the others are drafts to compare. Priced through Truebuild::PricingEngine by Truebuild::DealBuild; Schedule A,
# Colors & Finishes, the deal sheet and the factory PO read it. Locked once
# the agreement is signed: from then on it changes by change order (E52).
class DealHomeBuild < ApplicationRecord
  SOURCES = %w[order lot].freeze
  STATUSES = %w[draft locked].freeze

  belongs_to :company
  belongs_to :deal
  belongs_to :location, optional: true
  belongs_to :variant, class_name: 'CatalogPlanVariant', foreign_key: :catalog_plan_variant_id
  belongs_to :vehicle, optional: true
  belongs_to :truebuild_design, optional: true
  belongs_to :price_book, class_name: 'CatalogPriceBook', foreign_key: :catalog_price_book_id, optional: true
  belongs_to :cost_book, class_name: 'CatalogPriceBook', optional: true
  belongs_to :options_book, class_name: 'CatalogPriceBook', optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :lines, -> { order(:position, :id) }, class_name: 'DealHomeBuildLine', inverse_of: :build, dependent: :delete_all

  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :version_number, uniqueness: { scope: :deal_id }
  validates :deal_id, uniqueness: { conditions: -> { where(live: true) } }, if: :live?
  validate :same_company

  before_save { self.totals = totals.to_h.deep_stringify_keys }

  def locked? = status == 'locked'

  # "Version 2" or "Version 2: Double carport".
  def version_name
    ["Version #{version_number}", label.presence].compact.join(': ')
  end

  private

  # Company is set once, from the deal; the deal, home and design must be this company's.
  def same_company
    errors.add(:deal, 'belongs to another company') if deal && deal.company_id != company_id
    errors.add(:vehicle, 'belongs to another company') if vehicle && vehicle.company_id != company_id
    errors.add(:truebuild_design, 'belongs to another company') if truebuild_design && truebuild_design.company_id != company_id
  end
end
