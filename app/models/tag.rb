# frozen_string_literal: true
class Tag < ApplicationRecord
  belongs_to :company, optional: true
  has_many :tag_assignments, dependent: :destroy
  
  # Controllers use: name, description, color, category, tag_type (array/json), is_system, is_active
  scope :active, -> { where(is_active: [true, nil]) }
  scope :for_company, ->(company_id) { where(company_id: [company_id, nil]) }
  scope :system_tags, -> { where(is_system: true) }
  scope :custom_tags, -> { where(is_system: [false, nil]) }
  
  # Calculate actual usage count from tag assignments
  def usage_count
    tag_assignments.count
  end
end
