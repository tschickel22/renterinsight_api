class NurtureEnrollment < ApplicationRecord
  # Polymorphic association - can belong to Lead or Account
  belongs_to :enrollable, polymorphic: true, optional: true
  
  # Backward compatibility - keep lead association
  belongs_to :lead, optional: true
  
  # Also support Account directly
  belongs_to :account, foreign_key: :enrollable_id, optional: true
  
  belongs_to :nurture_sequence

  STATUSES = %w[idle running paused completed].freeze
  validates :status, presence: true, inclusion: { in: STATUSES }
  
  # Validation: Must have either lead_id OR enrollable
  validate :must_have_entity
  
  # Scopes
  scope :for_lead, ->(lead_id) { where(lead_id: lead_id).or(where(enrollable_type: 'Lead', enrollable_id: lead_id)) }
  scope :for_account, ->(account_id) { where(enrollable_type: 'Account', enrollable_id: account_id) }
  scope :for_entity, ->(entity_type, entity_id) { where(enrollable_type: entity_type, enrollable_id: entity_id) }
  scope :active, -> { where(status: ['idle', 'running']) }
  scope :running, -> { where(status: 'running') }
  
  # Helper methods
  def entity
    enrollable || lead
  end
  
  def entity_type
    enrollable_type || (lead_id.present? ? 'Lead' : nil)
  end
  
  def entity_id
    enrollable_id || lead_id
  end
  
  private
  
  def must_have_entity
    if lead_id.blank? && enrollable_id.blank?
      errors.add(:base, 'Must belong to either a lead or an enrollable entity')
    end
  end
end
