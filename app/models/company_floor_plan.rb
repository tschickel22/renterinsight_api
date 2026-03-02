# frozen_string_literal: true

class CompanyFloorPlan < ApplicationRecord
  belongs_to :company
  belongs_to :floor_plan

  validates :floor_plan_id, uniqueness: { scope: :company_id }
  validates :markup_type, inclusion: {
    in: %w[percentage fixed_dollar manual],
    allow_nil: true
  }

  scope :visible, -> { where(is_visible: true) }
  scope :ordered, -> { order(:display_order, :id) }
end
