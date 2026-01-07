class CommissionPlanComponent < ApplicationRecord
  belongs_to :commission_plan
  belongs_to :commission_component
  
  validates :commission_plan_id, presence: true
  validates :commission_component_id, presence: true
  
  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(sequence_order: :asc) }
  
  # Ensure unique component per plan
  validates :commission_component_id, uniqueness: { scope: :commission_plan_id }
end
