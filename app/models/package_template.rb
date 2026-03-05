# frozen_string_literal: true

class PackageTemplate < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :default_price, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(:position, :name) }

  def to_inventory_package_attrs
    {
      package_template_id: id,
      name: name,
      description: description,
      price: default_price,
      cost: cost,
      include_in_total: include_in_total,
      show_price_in_marketing: false,
      taxable: taxable || false,
      tax_rate: tax_rate,
      position: position
    }
  end
end
