# frozen_string_literal: true

class CompanyFloorPlanOptionOverride < ApplicationRecord
  belongs_to :company
  belongs_to :floor_plan_option

  validates :floor_plan_option_id, uniqueness: { scope: :company_id }
end
