# frozen_string_literal: true

# "Requires", "not available with", "includes". Rules come from sheet text,
# where extraction is weakest, so a rule is live only once an admin approves it.
class CatalogOptionRule < ApplicationRecord
  RULE_TYPES = %w[requires excludes includes].freeze

  belongs_to :manufacturer
  belongs_to :option, class_name: 'CatalogOption', foreign_key: :catalog_option_id, inverse_of: :rules
  belongs_to :target_option, class_name: 'CatalogOption', inverse_of: :inbound_rules
  belongs_to :approved_by, class_name: 'User', optional: true

  validates :rule_type, inclusion: { in: RULE_TYPES }
  validates :target_option_id, uniqueness: { scope: %i[catalog_option_id rule_type] }
  validate :not_self_referencing

  scope :approved, -> { where.not(approved_at: nil) }

  private

  def not_self_referencing
    errors.add(:target_option_id, 'cannot be the same option') if catalog_option_id.present? && catalog_option_id == target_option_id
  end
end
