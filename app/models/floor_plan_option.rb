# frozen_string_literal: true

class FloorPlanOption < ApplicationRecord
  belongs_to :option_category
  has_many :company_floor_plan_option_overrides, dependent: :destroy

  validates :name, presence: true

  scope :ordered, -> { order(:display_order) }
  scope :defaults, -> { where(is_default: true) }

  def conflicts_with?(option_id)
    return false if compatibility_rules.blank?
    conflicts = compatibility_rules['conflicts_with'] || []
    conflicts.include?(option_id)
  end

  def requires?(option_id)
    return false if compatibility_rules.blank?
    requires = compatibility_rules['requires'] || []
    requires.include?(option_id)
  end
end
