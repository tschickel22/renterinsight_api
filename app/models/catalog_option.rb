# frozen_string_literal: true

# A choice a buyer can make. `key` is our stable id because Champion order
# forms carry no option codes; `factory_code` is kept when a sheet has one.
class CatalogOption < ApplicationRecord
  KINDS = %w[upgrade swap package color standard].freeze
  STATUSES = %w[active discontinued].freeze

  belongs_to :group, class_name: 'CatalogOptionGroup', foreign_key: :catalog_option_group_id, inverse_of: :options
  belongs_to :manufacturer
  belongs_to :replaced_by, class_name: 'CatalogOption', optional: true
  has_many :prices, class_name: 'CatalogOptionPrice', dependent: :restrict_with_error
  has_many :rules, class_name: 'CatalogOptionRule', dependent: :destroy
  has_many :inbound_rules, class_name: 'CatalogOptionRule', foreign_key: :target_option_id, dependent: :destroy,
                           inverse_of: :target_option

  validates :key, :name, presence: true
  validates :key, uniqueness: { scope: :manufacturer_id }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validate :group_manufacturer_matches

  scope :active, -> { where(status: 'active') }

  private

  def group_manufacturer_matches
    return if group.nil? || group.manufacturer_id == manufacturer_id

    errors.add(:manufacturer_id, 'must match the option group manufacturer')
  end
end
