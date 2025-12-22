# frozen_string_literal: true

class QuickbooksFieldMapping < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true
  
  validates :entity_type, :renter_insight_field, :quickbooks_field, presence: true
  validates :mapping_type, inclusion: { in: %w[direct calculated custom] }
  
  scope :for_entity, ->(type) { where(entity_type: type).order(:priority) }
  scope :enabled_only, -> { where(enabled: true) }
  
  def transform_value(value)
    case mapping_type
    when 'direct'
      value
    when 'calculated', 'custom'
      eval_transformation(value)
    else
      value
    end
  end
  
  private
  
  def eval_transformation(value)
    return value if transformation_logic.blank?
    
    begin
      eval(transformation_logic)
    rescue => e
      Rails.logger.error("Field mapping transformation error: #{e.message}")
      value
    end
  end
  
  class << self
    def mappings_hash(entity_type, company_id, location_id = nil)
      for_entity(entity_type)
        .enabled_only
        .where(company_id: company_id, location_id: location_id)
        .pluck(:renter_insight_field, :quickbooks_field)
        .to_h
    end
    
    def reverse_mappings_hash(entity_type, company_id, location_id = nil)
      mappings_hash(entity_type, company_id, location_id).invert
    end
  end
end
