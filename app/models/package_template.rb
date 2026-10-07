# frozen_string_literal: true

class PackageTemplate < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :name, uniqueness: { scope: :company_id, case_sensitive: false, conditions: -> { where(is_active: true) } }, on: :create
  validates :default_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(:position, :name) }

  # A home is inventory, never a template. Quotes, invoices and Edit Deal
  # used to save every typed line as a template, the home line included
  # ("2023 Cavco Crest", "2026 Dutch Housing Verona"). Recognized by a
  # model-year name at a home's price, or a VIN or home/land tag in its notes.
  HOME_LIKE_SQL = <<~SQL.squish.freeze
    (package_templates.name ~ '^(19|20)[0-9]{2} ' AND COALESCE(package_templates.default_price, 0) >= 10000)
    OR COALESCE(package_templates.description, '') ILIKE '%VIN:%'
    OR COALESCE(package_templates.description, '') ~* 'category:\s*(home|land)'
  SQL
  scope :not_homes, -> { where.not(HOME_LIKE_SQL) }

  validate :not_a_home, on: :create

  def home_like?
    (name.to_s.match?(/\A(19|20)\d{2} /) && default_price.to_d >= 10_000) ||
      description.to_s.match?(/VIN:|category:\s*(home|land)/i)
  end

  def to_inventory_package_attrs
    {
      package_template_id: id,
      name: name,
      description: description,
      price: default_price,
      cost: cost,
      include_in_total: include_in_total,
      show_price_in_marketing: show_price_in_marketing.nil? ? true : show_price_in_marketing,
      taxable: taxable || false,
      tax_rate: tax_rate,
      position: position
    }
  end

  private

  def not_a_home
    errors.add(:base, 'A home is inventory, not a template') if home_like?
  end
end
