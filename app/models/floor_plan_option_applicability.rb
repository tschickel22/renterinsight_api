# frozen_string_literal: true

class FloorPlanOptionApplicability < ApplicationRecord
  belongs_to :floor_plan
  belongs_to :floor_plan_option

  validates :floor_plan_option_id, uniqueness: { scope: :floor_plan_id }

  scope :defaults, -> { where(is_default_for_model: true) }
end
